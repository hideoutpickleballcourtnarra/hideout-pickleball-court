-- Add the reserved court and hourly slots to the private admin booking list.
-- Existing booking data is preserved; this only expands the admin RPC response.

drop function if exists public.admin_list_bookings(text,text);

create or replace function public.admin_list_bookings(
  p_username text,
  p_password text
)
returns table(
  booking_id uuid,
  customer_name text,
  customer_email text,
  phone text,
  booking_date date,
  reserved_slots jsonb,
  players integer,
  paddle_sets integer,
  total_amount integer,
  payment_option integer,
  payment_amount integer,
  status text,
  created_at timestamptz,
  receipt_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.court_admin_credentials a
    where a.id = 1
      and a.username = p_username
      and a.password_hash = extensions.crypt(p_password, a.password_hash)
  ) then
    raise exception 'Incorrect admin username or password.';
  end if;

  return query
  select
    b.id,
    b.customer_name,
    b.customer_email,
    b.phone,
    b.booking_date,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'court', s.court_number,
          'hour', s.start_hour
        )
        order by s.court_number, s.start_hour
      )
      from public.court_booking_slots s
      where s.booking_id = b.id
    ), '[]'::jsonb),
    b.players,
    b.paddle_sets,
    b.total_amount,
    b.payment_option,
    b.payment_amount,
    b.status,
    b.created_at,
    count(r.id)
  from public.court_bookings b
  left join public.court_booking_receipts r on r.booking_id = b.id
  group by b.id
  order by b.created_at desc;
end;
$$;

grant execute on function public.admin_list_bookings(text,text) to anon, authenticated;
