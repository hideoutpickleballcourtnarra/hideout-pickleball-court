# Hideout Pickleball Court

Official booking website for Hideout Pickleball Court.

## Booking setup

1. Open the Supabase project connected to this site.
2. Open **SQL Editor**.
3. In this repository, open `supabase/migrations/202611170001_booking_core.sql`.
4. Copy the entire SQL file into a new Supabase SQL query and run it once.
5. After it succeeds, open the website and test a booking using a future date.

The migration creates the booking and hourly-slot tables plus two RPC functions:
- `get_booked_slots` loads unavailable court-hours.
- `create_booking` confirms a booking and reserves all selected slots in one database transaction. If a slot was taken by someone else, the booking fails rather than double-booking.

## Current implementation status

- Existing website design and embedded logo are preserved.
- Live court availability and booking submission are connected in the frontend.
- Booking price: PHP 100 per court-hour; PHP 20 per extra player per hour beyond four; PHP 50 per paddle-and-ball set.
- Customer booking is automatically confirmed after the database successfully reserves the selected slots.

## Still required before public launch

- Run the SQL migration above in Supabase.
- Configure GCash receipt upload and owner-only receipt review.
- Build and secure the owner admin dashboard (username/password flow).
- Configure and test daily database backups, weekly external copies, and separate receipt-file backups.
- Add the exact court location and directions.
- Test on mobile and verify the full booking, cancellation, and restore workflows.

Do not publish the site as fully operational until the remaining launch items have been completed and tested.
