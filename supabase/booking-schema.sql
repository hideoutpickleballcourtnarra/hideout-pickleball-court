-- Hideout Pickleball Court booking database
-- Run this entire file once in Supabase SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.court_bookings (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null check (length(trim(customer_name)) between 2 and 120),
  phone text not null check (length(trim(phone)) between 7 and 30),
  booking_date date not null,
  players integer not null check (players between 1 and 30),
  paddle_sets integer not null default 0 check (paddle_sets between 0 and 20),
  total_amount integer not null check (total_amount >= 0),
  payment_option integer not null default 100 check (payment_option in (50,100)),
  payment_amount integer not null default 0 check (payment_amount >= 0),
  status text not null default 'confirmed' check (status in ('confirmed','cancelled')),
  created_at timestamptz not null default now()
);

alter table public.court_bookings add column if not exists payment_option integer not null default 100 check (payment_option in (50,100));
alter table public.court_bookings add column if not exists payment_amount integer not null default 0 check (payment_amount >= 0);

create table if not exists public.court_booking_slots (
  id bigint generated always as identity primary key,
  booking_id uuid not null references public.court_bookings(id) on delete cascade,
  booking_date date not null,
  court_number integer not null check (court_number in (1,2)),
  start_hour integer not null check (start_hour between 0 and 23),
  created_at timestamptz not null default now(),
  constraint court_booking_slots_no_double_booking unique (booking_date, court_number, start_hour)
);

create index if not exists court_bookings_date_idx on public.court_bookings (booking_date);
create index if not exists court_booking_slots_booking_idx on public.court_booking_slots (booking_id);

alter table public.court_bookings enable row level security;
alter table public.court_booking_slots enable row level security;

drop policy if exists "Public can read booked court slots" on public.court_booking_slots;
create policy "Public can read booked court slots"
  on public.court_booking_slots for select to anon, authenticated using (true);

drop function if exists public.get_booked_slots(date);

create function public.get_booked_slots(p_date date)
returns table(court_number integer, start_hour integer)
language sql stable security definer
set search_path = public
as $$
  select s.court_number, s.start_hour
  from public.court_booking_slots s
  join public.court_bookings b on b.id = s.booking_id
  where s.booking_date = p_date and b.status = 'confirmed'
  order by s.court_number, s.start_hour;
$$;

drop function if exists public.create_booking(text,text,date,integer,integer,jsonb);

create or replace function public.create_booking(
  p_customer_name text,
  p_phone text,
  p_date date,
  p_players integer,
  p_paddle_sets integer,
  p_payment_option integer,
  p_slots jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
  v_slot_count integer;
  v_total integer;
  v_payment integer;
begin
  if p_customer_name is null or length(trim(p_customer_name)) not between 2 and 120 then
    raise exception 'Please enter your full name.';
  end if;
  if p_phone is null or length(trim(p_phone)) not between 7 and 30 then
    raise exception 'Please enter a valid mobile number.';
  end if;
  if p_date is null or p_date < current_date then
    raise exception 'Please choose today or a future date.';
  end if;
  if p_players is null or p_players not between 1 and 30 then
    raise exception 'Player count must be between 1 and 30.';
  end if;
  if p_paddle_sets is null or p_paddle_sets not between 0 and 20 then
    raise exception 'Paddle and ball sets must be between 0 and 20.';
  end if;
  if p_payment_option is null or p_payment_option not in (50,100) then
    raise exception 'Choose either half payment or full payment.';
  end if;
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 or jsonb_array_length(p_slots) > 48 then
    raise exception 'Select at least one hourly slot.';
  end if;

  select count(*) into v_slot_count
  from jsonb_to_recordset(p_slots) as x(court integer, hour integer)
  where x.court in (1,2) and x.hour between 0 and 23;

  if v_slot_count <> jsonb_array_length(p_slots) then
    raise exception 'One or more selected time slots are invalid.';
  end if;
  if (select count(*) from (
    select distinct x.court, x.hour
    from jsonb_to_recordset(p_slots) as x(court integer, hour integer)
  ) d) <> v_slot_count then
    raise exception 'The selected time slots contain duplicates.';
  end if;

  v_total := (v_slot_count * 100)
           + (v_slot_count * greatest(p_players - 4, 0) * 20)
           + (p_paddle_sets * 50);

  v_payment := ceil(v_total * p_payment_option / 100.0)::integer;

  begin
    insert into public.court_bookings
      (customer_name, phone, booking_date, players, paddle_sets, total_amount, payment_option, payment_amount, status)
    values
      (trim(p_customer_name), trim(p_phone), p_date, p_players, p_paddle_sets, v_total, p_payment_option, v_payment, 'confirmed')
    returning id into v_booking_id;

    insert into public.court_booking_slots (booking_id, booking_date, court_number, start_hour)
    select v_booking_id, p_date, x.court, x.hour
    from jsonb_to_recordset(p_slots) as x(court integer, hour integer);
  exception when unique_violation then
    raise exception 'A selected slot was just booked. Please choose another time.';
  end;

  return jsonb_build_object('booking_id', v_booking_id, 'total_amount', v_total, 'payment_option', p_payment_option, 'payment_amount', v_payment);
end;
$$;

grant select on public.court_booking_slots to anon, authenticated;
grant execute on function public.get_booked_slots(date) to anon, authenticated;
grant execute on function public.create_booking(text,text,date,integer,integer,integer,jsonb) to anon, authenticated;


-- Private receipt records and password-protected admin access.
create table if not exists public.court_booking_receipts (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.court_bookings(id) on delete cascade,
  file_name text not null,
  mime_type text not null check (mime_type in ('image/jpeg','image/png','image/webp','application/pdf')),
  data_base64 text not null,
  uploaded_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index if not exists court_booking_receipts_booking_idx on public.court_booking_receipts (booking_id);
alter table public.court_booking_receipts enable row level security;

create table if not exists public.court_admin_credentials (
  id integer primary key check (id = 1),
  username text not null unique,
  password_hash text not null,
  updated_at timestamptz not null default now()
);
alter table public.court_admin_credentials enable row level security;

create or replace function public.submit_booking_receipt(
  p_booking_id uuid,
  p_phone text,
  p_file_name text,
  p_mime_type text,
  p_data_base64 text
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_receipt_id uuid;
begin
  if not exists (
    select 1 from public.court_bookings
    where id = p_booking_id and trim(phone) = trim(p_phone) and status = 'confirmed'
  ) then
    raise exception 'Booking reference or mobile number does not match.';
  end if;
  if p_mime_type not in ('image/jpeg','image/png','image/webp','application/pdf') then
    raise exception 'Upload a JPG, PNG, WEBP, or PDF receipt.';
  end if;
  if p_data_base64 is null or length(p_data_base64) < 20 or length(p_data_base64) > 2800000 then
    raise exception 'Receipt file is too large. Maximum file size is 2 MB.';
  end if;
  insert into public.court_booking_receipts(booking_id,file_name,mime_type,data_base64)
  values (p_booking_id,left(coalesce(p_file_name,'receipt'),180),p_mime_type,p_data_base64)
  returning id into v_receipt_id;
  return jsonb_build_object('receipt_id',v_receipt_id);
end;
$$;

create or replace function public.admin_list_booking_receipts(p_username text,p_password text)
returns table(
  receipt_id uuid, booking_id uuid, customer_name text, phone text,
  booking_date date, total_amount integer, payment_option integer,
  payment_amount integer, file_name text, mime_type text,
  data_base64 text, uploaded_at timestamptz, reviewed_at timestamptz
)
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.court_admin_credentials a
    where a.id = 1 and a.username = p_username
      and a.password_hash = crypt(p_password,a.password_hash)
  ) then
    raise exception 'Incorrect admin username or password.';
  end if;
  return query
  select r.id,b.id,b.customer_name,b.phone,b.booking_date,b.total_amount,
         b.payment_option,b.payment_amount,r.file_name,r.mime_type,
         r.data_base64,r.uploaded_at,r.reviewed_at
  from public.court_booking_receipts r
  join public.court_bookings b on b.id = r.booking_id
  order by r.uploaded_at desc;
end;
$$;

create or replace function public.admin_mark_receipt_reviewed(
  p_username text,p_password text,p_receipt_id uuid
) returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.court_admin_credentials a
    where a.id = 1 and a.username = p_username
      and a.password_hash = crypt(p_password,a.password_hash)
  ) then
    raise exception 'Incorrect admin username or password.';
  end if;
  update public.court_booking_receipts set reviewed_at = now() where id = p_receipt_id;
  return found;
end;
$$;

grant execute on function public.submit_booking_receipt(uuid,text,text,text,text) to anon, authenticated;
grant execute on function public.admin_list_booking_receipts(text,text) to anon, authenticated;
grant execute on function public.admin_mark_receipt_reviewed(text,text,uuid) to anon, authenticated;
