-- Hideout Pickleball Court: safe monthly receipt cleanup
-- Run once in Supabase SQL Editor. Existing receipts are retained.
alter table public.court_booking_receipts
  add column if not exists drive_file_id text;

alter table public.court_booking_receipts
  alter column data_base64 drop not null;

drop function if exists public.admin_list_booking_receipts(text,text);

create function public.admin_list_booking_receipts(p_username text,p_password text)
returns table(
  receipt_id uuid, booking_id uuid, customer_name text, phone text,
  booking_date date, total_amount integer, payment_option integer,
  payment_amount integer, file_name text, mime_type text,
  data_base64 text, drive_file_id text, uploaded_at timestamptz, reviewed_at timestamptz
)
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.court_admin_credentials a
    where a.id = 1 and a.username = p_username
      and a.password_hash = extensions.crypt(p_password,a.password_hash)
  ) then
    raise exception 'Incorrect admin username or password.';
  end if;
  return query
  select r.id,b.id,b.customer_name,b.phone,b.booking_date,b.total_amount,
         b.payment_option,b.payment_amount,r.file_name,r.mime_type,
         r.data_base64,r.drive_file_id,r.uploaded_at,r.reviewed_at
  from public.court_booking_receipts r
  join public.court_bookings b on b.id = r.booking_id
  order by r.uploaded_at desc;
end;
$$;

grant execute on function public.admin_list_booking_receipts(text,text) to anon, authenticated;

create or replace function public.cleanup_reviewed_receipt_files()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer;
begin
  update public.court_booking_receipts
     set data_base64 = null
   where reviewed_at is not null
     and reviewed_at < date_trunc('month', now())
     and drive_file_id is not null
     and data_base64 is not null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.cleanup_reviewed_receipt_files() from public, anon, authenticated;

create extension if not exists pg_cron with schema pg_catalog;
do $$
begin
  if exists (select 1 from cron.job where jobname = 'hideout-monthly-receipt-cleanup') then
    perform cron.unschedule(jobid) from cron.job
     where jobname = 'hideout-monthly-receipt-cleanup';
  end if;
  perform cron.schedule(
    'hideout-monthly-receipt-cleanup',
    '15 0 1 * *',
    'select public.cleanup_reviewed_receipt_files();'
  );
end;
$$;
