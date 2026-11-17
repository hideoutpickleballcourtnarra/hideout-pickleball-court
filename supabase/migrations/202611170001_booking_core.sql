-- Hideout Pickleball Court: booking foundation
-- Run this file once in Supabase SQL Editor before enabling live bookings.

create extension if not exists pgcrypto;

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null,
  phone text not null,
  booking_date date not null,
  players integer not null check (players between 1 and 30),
  paddle_sets integer not null default 0 check (paddle_sets between 0 and 20),
  total_amount numeric(10,2) not null check (total_amount >= 0),
  status text not null default 'confirmed' check (status in ('confirmed','cancelled')),
  created_at timestamptz not null default now()
);

create table if not exists public.booking_slots (
  id bigint generated always as identity primary key,
  booking_id uuid not null references public.bookings(id) on delete cascade,
  booking_date date not null,
  court_number integer not null check (court_number in (1,2)),
  start_hour integer not null check (start_hour between 0 and 23),
  created_at timestamptz not null default now(),
  constraint booking_slots_unique unique (booking_date, court_number, start_hour)
);

create index if not exists booking_slots_date_idx
  on public.booking_slots (booking_date, court_number, start_hour);

alter table public.bookings enable row level security;
alter table public.booking_slots enable row level security;

revoke all on public.bookings from anon, authenticated;
revoke all on public.booking_slots from anon, authenticated;
grant select on public.booking_slots to anon, authenticated;

create or replace function public.get_booked_slots(p_date date)
returns table (court_number integer, start_hour integer)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select s.court_number, s.start_hour
  from public.booking_slots s
  join public.bookings b on b.id = s.booking_id
  where s.booking_date = p_date and b.status = 'confirmed'
  order by s.court_number, s.start_hour;
$$;

create or replace function public.create_booking(
  p_customer_name text,
  p_phone text,
  p_date date,
  p_players integer,
  p_paddle_sets integer,
  p_slots jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking_id uuid;
  v_slot_count integer;
  v_total numeric(10,2);
  v_extra integer;
  v_slot jsonb;
begin
  if length(trim(coalesce(p_customer_name,''))) < 2 then
    raise exception 'Please enter your full name.';
  end if;
  if length(trim(coalesce(p_phone,''))) < 7 then
    raise exception 'Please enter a valid phone number.';
  end if;
  if p_date < current_date then
    raise exception 'Please choose today or a future date.';
  end if;
  if p_players not between 1 and 30 or p_paddle_sets not between 0 and 20 then
    raise exception 'Please check the player and equipment counts.';
  end if;
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then
    raise exception 'Please select at least one time slot.';
  end if;
  if jsonb_array_length(p_slots) > 48 then
    raise exception 'Please select no more than 48 slots per booking.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_slots) x
    where (x->>'court') !~ '^[12]$'
       or (x->>'hour') !~ '^(0|[1-9]|1[0-9]|2[0-3])$'
  ) then
    raise exception 'One or more selected time slots are invalid.';
  end if;

  if (select count(*) from (
    select distinct (x->>'court')::integer, (x->>'hour')::integer
    from jsonb_array_elements(p_slots) x
  ) d) <> jsonb_array_length(p_slots) then
    raise exception 'The selected slots contain duplicates.';
  end if;

  v_slot_count := jsonb_array_length(p_slots);
  v_extra := greatest(p_players - 4, 0);
  v_total := (v_slot_count * 100) + (v_slot_count * v_extra * 20) + (p_paddle_sets * 50);

  insert into public.bookings
    (customer_name, phone, booking_date, players, paddle_sets, total_amount, status)
  values
    (trim(p_customer_name), trim(p_phone), p_date, p_players, p_paddle_sets, v_total, 'confirmed')
  returning id into v_booking_id;

  begin
    for v_slot in select value from jsonb_array_elements(p_slots)
    loop
      insert into public.booking_slots
        (booking_id, booking_date, court_number, start_hour)
      values
        (v_booking_id, p_date, (v_slot->>'court')::integer, (v_slot->>'hour')::integer);
    end loop;
  exception when unique_violation then
    raise exception 'One or more selected slots have just been booked. Please refresh availability and choose again.';
  end;

  return jsonb_build_object(
    'booking_id', v_booking_id,
    'status', 'confirmed',
    'total_amount', v_total,
    'slot_count', v_slot_count
  );
end;
$$;

revoke all on function public.get_booked_slots(date) from public;
revoke all on function public.create_booking(text,text,date,integer,integer,jsonb) from public;
grant execute on function public.get_booked_slots(date) to anon, authenticated;
grant execute on function public.create_booking(text,text,date,integer,integer,jsonb) to anon, authenticated;
