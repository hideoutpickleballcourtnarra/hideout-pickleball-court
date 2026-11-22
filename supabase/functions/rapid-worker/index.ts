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
    const action = body?.action;

    // Send a confirmation email for an already-confirmed booking.
    if (action === "send_confirmation") {
      stage = "verify-booking-for-email";
      const bookingId = body?.booking_id;
      if (!bookingId) return respond({ error: "Missing booking reference." }, 400);

      const bookingResponse = await fetch(
        `${supabaseUrl}/rest/v1/court_bookings?id=eq.${encodeURIComponent(bookingId)}&select=id,customer_name,customer_email,phone,booking_date,players,paddle_sets,total_amount,payment_option,payment_amount,status`,
        { headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` } },
      );
      if (!bookingResponse.ok) {
        console.error("Booking lookup for confirmation email failed", { status: bookingResponse.status });
        return respond({ error: "Could not verify the booking for email delivery." }, 502);
      }

      const bookings = await bookingResponse.json();
      const booking = bookings?.[0];
      if (!booking || booking.status !== "confirmed" || !booking.customer_email) {
        return respond({ error: "Confirmed booking or customer email was not found." }, 404);
      }

      stage = "send-confirmation-email";
      const emailResponse = await fetch(scriptUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          secret: uploadSecret,
          action: "send_email",
          to: booking.customer_email,
          subject: String(body?.subject || "Booking confirmed — Hideout Pickleball Court"),
          body: String(body?.message || "Your booking at Hideout Pickleball Court is confirmed."),
          htmlBody: String(body?.htmlBody || ""),
        }),
      });

      const emailResponseText = await emailResponse.text();
      let emailResult: any;
      try {
        emailResult = JSON.parse(emailResponseText);
      } catch (_parseError) {
        console.error("Email service returned a non-JSON response", { status: emailResponse.status, responsePreview: emailResponseText.slice(0, 300) });
        return respond({ error: `Email service returned an unreadable response (HTTP ${emailResponse.status}).` }, 502);
      }
      if (!emailResponse.ok || !emailResult?.success) {
        console.error("Confirmation email delivery failed", { status: emailResponse.status, error: emailResult?.error || "Unknown email error" });
        return respond({ error: emailResult?.error || "Confirmation email could not be sent." }, 502);
      }

      // Send a separate notification request to each administrator. This avoids
      // recipient parsing issues and lets one address succeed independently.
      const adminNotificationResults: { email: string; sent: boolean }[] = [];
      try {
        stage = "load-booking-slots-for-admin";
        const slotsResponse = await fetch(
          `${supabaseUrl}/rest/v1/court_booking_slots?booking_id=eq.${encodeURIComponent(bookingId)}&select=court_number,start_hour&order=court_number.asc,start_hour.asc`,
          { headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` } },
        );
        if (!slotsResponse.ok) throw new Error("Could not load reserved court times.");
        const slots = await slotsResponse.json();
        const dateLabel = new Date(`${booking.booking_date}T00:00:00+08:00`).toLocaleDateString("en-PH", {
          weekday: "long", year: "numeric", month: "long", day: "numeric", timeZone: "Asia/Manila",
        });
        const timeLabel = (hour: number) => {
          const h = Number(hour);
          const start = new Date(2000, 0, 1, h);
          const end = new Date(2000, 0, 1, h + 1);
          return `${start.toLocaleTimeString("en-PH", { hour: "numeric", minute: "2-digit", hour12: true })}–${end.toLocaleTimeString("en-PH", { hour: "numeric", minute: "2-digit", hour12: true })}`;
        };
        const money = (value: unknown) => `Php ${Number(value || 0).toLocaleString("en-PH", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
        const paymentLabel = Number(booking.payment_option) === 50 ? "50% deposit" : "Full payment";
        const balance = Math.max(0, Number(booking.total_amount) - Number(booking.payment_amount));
        const slotLines = (slots || []).map((slot: any) => `Court ${slot.court_number} — ${timeLabel(slot.start_hour)}`).join("\\n");
        const adminText = [
          "A new booking has been confirmed at Hideout Pickleball Court.",
          "",
          `Booking reference: ${booking.id}`,
          `Customer: ${booking.customer_name}`,
          `Email: ${booking.customer_email}`,
          `Mobile: ${booking.phone}`,
          `Booking date: ${dateLabel}`,
          "Reserved court times:",
          slotLines || "No slot details returned.",
          `Players: ${booking.players}`,
          `Paddle rental sets: ${booking.paddle_sets}`,
          `Total amount: ${money(booking.total_amount)}`,
          `Payment option: ${paymentLabel}`,
          `Amount to pay now: ${money(booking.payment_amount)}`,
          ...(Number(booking.payment_option) === 50 ? [`Remaining balance: ${money(balance)}`] : []),
          "",
          "This is an automatic booking notification.",
        ].join("\\n");
        const esc = (value: unknown) => String(value ?? "").replace(/[&<>"]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[ch] || ch));
        const adminHtml = `<div style="font-family:Arial,sans-serif;color:#263b2e;max-width:620px;margin:auto"><h2 style="background:#176b45;color:white;padding:20px">NEW BOOKING CONFIRMED</h2><p>A new booking has been confirmed at <b>Hideout Pickleball Court</b>.</p><table style="border-collapse:collapse;width:100%">${[
          ["Booking reference", booking.id],
          ["Customer", booking.customer_name],
          ["Email", booking.customer_email],
          ["Mobile", booking.phone],
          ["Booking date", dateLabel],
          ["Reserved court times", (slots || []).map((slot: any) => `Court ${slot.court_number} — ${timeLabel(slot.start_hour)}`).join("<br>") || "No slot details returned."],
          ["Players", booking.players],
          ["Paddle rental sets", booking.paddle_sets],
          ["Total amount", money(booking.total_amount)],
          ["Payment option", paymentLabel],
          ["Amount to pay now", money(booking.payment_amount)],
          ...(Number(booking.payment_option) === 50 ? [["Remaining balance", money(balance)]] : []),
        ].map(([label, value]) => `<tr><td style="padding:9px;border-bottom:1px solid #ddd;color:#587363">${esc(label)}</td><td style="padding:9px;border-bottom:1px solid #ddd;font-weight:bold">${label === "Reserved court times" ? value : esc(value)}</td></tr>`).join("")}</table><p style="color:#668071;font-size:12px;margin-top:20px">Automatic notification from Hideout Pickleball Court.</p></div>`;
        for (const adminEmail of ["hideoutpickleballcourt.narra@gmail.com", "xopiatolentino@gmail.com"]) {
          try {
            stage = `send-admin-booking-notification-${adminEmail}`;
            const adminResponse = await fetch(scriptUrl, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({
                secret: uploadSecret,
                action: "send_email",
                to: adminEmail,
                subject: `NEW BOOKING — Hideout Pickleball Court — ${dateLabel}`,
                body: adminText,
                htmlBody: adminHtml,
              }),
            });
            const adminResponseText = await adminResponse.text();
            let adminResult: any;
            try { adminResult = JSON.parse(adminResponseText); }
            catch (_parseError) { throw new Error(`Email service returned unreadable response (HTTP ${adminResponse.status}).`); }
            if (!adminResponse.ok || !adminResult?.success) throw new Error(adminResult?.error || "Notification could not be sent.");
            adminNotificationResults.push({ email: adminEmail, sent: true });
          } catch (adminError) {
            console.error("Admin booking notification failed", {
              bookingId,
              recipient: adminEmail,
              error: adminError instanceof Error ? adminError.message : String(adminError),
            });
            adminNotificationResults.push({ email: adminEmail, sent: false });
          }
        }
      } catch (adminError) {
        console.error("Admin booking notification preparation failed", {
          bookingId,
          error: adminError instanceof Error ? adminError.message : String(adminError),
        });
      }
      const adminNotificationSent = adminNotificationResults.length === 2 && adminNotificationResults.every((result) => result.sent);

      return respond({ success: true, emailSent: true, adminNotificationSent });
    }

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
