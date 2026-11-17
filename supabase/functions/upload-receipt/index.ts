import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const respond = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  let stage = "request-start";
  try {
    if (req.method !== "POST") return respond({ error: "Method not allowed" }, 405);

    stage = "read-settings";
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const scriptUrl = Deno.env.get("GOOGLE_APPS_SCRIPT_URL");
    const uploadSecret = Deno.env.get("GOOGLE_UPLOAD_SECRET");

    if (!supabaseUrl || !serviceKey || !scriptUrl || !uploadSecret) {
      return respond({ error: "Server upload settings are incomplete." }, 500);
    }

    stage = "read-request-body";
    const body = await req.json();
    const { booking_id, receipt_id, phone, fileName, mimeType, base64 } = body ?? {};

    if (!booking_id || !receipt_id || !phone || !fileName || !mimeType || !base64) {
      return respond({ error: "Missing receipt information." }, 400);
    }

    const allowed = ["image/jpeg", "image/png", "image/webp", "application/pdf"];
    if (!allowed.includes(mimeType)) return respond({ error: "Unsupported receipt file type." }, 400);
    if (typeof base64 !== "string" || base64.length > 2_800_000) {
      return respond({ error: "Receipt exceeds the 2 MB limit." }, 413);
    }

    stage = "verify-booking";
    const bookingResponse = await fetch(
      `${supabaseUrl}/rest/v1/court_bookings?id=eq.${encodeURIComponent(booking_id)}&select=id,phone,status`,
      { headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` } },
    );
    if (!bookingResponse.ok) return respond({ error: "Could not verify booking." }, 502);
    const bookings = await bookingResponse.json();
    const booking = bookings?.[0];
    if (!booking || String(booking.phone).trim() !== String(phone).trim() || booking.status !== "confirmed") {
      return respond({ error: "Booking reference or mobile number does not match." }, 403);
    }

    stage = "send-to-google-drive";
    const driveResponse = await fetch(scriptUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        secret: uploadSecret,
        fileName: String(fileName).slice(0, 180),
        mimeType,
        base64,
      }),
    });

    const driveResponseText = await driveResponse.text();
    let driveResult: any;
    try {
      driveResult = JSON.parse(driveResponseText);
    } catch (_parseError) {
      console.error("Google Drive returned a non-JSON response", { status: driveResponse.status, responsePreview: driveResponseText.slice(0, 300) });
      return respond({ error: `Google Drive returned an unreadable response (HTTP ${driveResponse.status}).` }, 502);
    }
    if (!driveResponse.ok || !driveResult?.success) {
      return respond({ error: driveResult?.error || "Google Drive upload failed." }, 502);
    }

    stage = "save-drive-backup-reference";
    const receiptUpdate = await fetch(
      `${supabaseUrl}/rest/v1/court_booking_receipts?id=eq.${encodeURIComponent(receipt_id)}&booking_id=eq.${encodeURIComponent(booking_id)}`,
      {
        method: "PATCH",
        headers: {
          apikey: serviceKey,
          Authorization: `Bearer ${serviceKey}`,
          "Content-Type": "application/json",
          Prefer: "return=minimal",
        },
        body: JSON.stringify({ drive_file_id: String(driveResult.fileId) }),
      },
    );
    if (!receiptUpdate.ok) {
      return respond({ error: "Receipt reached Google Drive, but its backup confirmation could not be saved. It will not be auto-deleted from Supabase." }, 502);
    }

    return respond({ success: true, fileId: driveResult.fileId, receiptId: receipt_id });
  } catch (error) {
    console.error("Receipt backup function failed", { stage, error: error instanceof Error ? error.message : String(error), stack: error instanceof Error ? error.stack : undefined });
    return respond({ error: `Receipt backup failed during ${stage}: ${error instanceof Error ? error.message : "Unexpected upload error."}` }, 500);
  }
});
