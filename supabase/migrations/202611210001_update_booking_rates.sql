-- Update Hideout booking rates: Php 200 per court-hour for up to 4 players,
-- plus Php 40 per additional player per court-hour.
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

  v_total := (v_slot_count * 200)
           + (v_slot_count * greatest(p_players - 4, 0) * 40)
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
