-- Require and store customer email for new Hideout bookings.
alter table public.court_bookings
  add column if not exists customer_email text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'court_bookings_customer_email_format'
      and conrelid = 'public.court_bookings'::regclass
  ) then
    alter table public.court_bookings
      add constraint court_bookings_customer_email_format
      check (customer_email is null or customer_email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$');
  end if;
end;
$$;

drop function if exists public.create_booking(text,text,date,integer,integer,integer,jsonb);

create or replace function public.create_booking(
  p_customer_name text,
  p_customer_email text,
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
  if p_customer_email is null or trim(p_customer_email) !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then
    raise exception 'Please enter a valid email address.';
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
      (customer_name, customer_email, phone, booking_date, players, paddle_sets, total_amount, payment_option, payment_amount, status)
    values
      (trim(p_customer_name), lower(trim(p_customer_email)), trim(p_phone), p_date, p_players, p_paddle_sets, v_total, p_payment_option, v_payment, 'confirmed')
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

grant execute on function public.create_booking(text,text,text,date,integer,integer,integer,jsonb) to anon, authenticated;

drop function if exists public.admin_list_bookings(text,text);

create or replace function public.admin_list_bookings(p_username text,p_password text)
returns table(
  booking_id uuid, customer_name text, customer_email text, phone text, booking_date date,
  players integer, paddle_sets integer, total_amount integer,
  payment_option integer, payment_amount integer, status text,
  created_at timestamptz, receipt_count bigint
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
  select b.id,b.customer_name,b.customer_email,b.phone,b.booking_date,b.players,b.paddle_sets,
         b.total_amount,b.payment_option,b.payment_amount,b.status,b.created_at,
         count(r.id)
  from public.court_bookings b
  left join public.court_booking_receipts r on r.booking_id = b.id
  group by b.id
  order by b.created_at desc;
end;
$$;
grant execute on function public.admin_list_bookings(text,text) to anon, authenticated;
