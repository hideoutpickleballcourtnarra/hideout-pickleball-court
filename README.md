# Hideout Pickleball Court

Official booking website for Hideout Pickleball Court.

## Booking database setup

The website uses Supabase RPC functions for live availability and automatic booking confirmation.

1. Open the Supabase project: https://supabase.com/dashboard/project/dxbkzxvyqgsupdhlzmwv
2. Open **SQL Editor** and choose **New query**.
3. Open [supabase/booking-schema.sql](./supabase/booking-schema.sql), copy the entire file, and paste it into the SQL Editor.
4. Click **Run**.
5. Open the deployed website and test a booking using a future date.

The schema creates `court_bookings` and `court_booking_slots`, plus the `get_booked_slots` and `create_booking` RPC functions. A successful booking is confirmed immediately. A unique database constraint prevents two customers from reserving the same court and hour.

## Current scope

- Two courts, selectable in hourly blocks (24/7)
- ₱100 per court-hour
- ₱20 per extra player per hour beyond four players
- ₱50 per paddle-and-ball set
- Live booked-slot display
- Immediate booking confirmation

GCash receipt upload, the owner/admin dashboard, and backup automation still need to be completed before launch. Do not treat those features as live yet.
