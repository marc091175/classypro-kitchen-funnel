# ClassyPro Phils. — Kitchen Consultation Funnel

Static lead-generation funnel that qualifies a kitchen project, collects contact
details and photos, and books a survey appointment.

**Stack:** static HTML on Vercel + Supabase (Postgres + Storage).

## How the backend works

The page talks to Supabase directly, but **no table is reachable from the
browser**. Row-level security is enabled with no table policies, so the
publishable key in `index.html` can only execute three `SECURITY DEFINER`
functions:

| Function | Purpose | Exposes |
|---|---|---|
| `get_booked_slots()` | Greys out taken times | Date + slot only, never lead data |
| `create_booking(...)` | Creates the lead + booking in one transaction | New `lead_id` / `booking_id` |
| `record_attachment(...)` | Registers an uploaded file | Nothing |

Consequences:

- Lead PII is **not** readable by visitors — `select` on `leads` returns 0 rows.
- Double-booking is impossible: a partial unique index on
  `(survey_date, survey_slot) where status = 'booked'` makes the check atomic.
  A losing race returns `{ok:false, reason:'slot_taken'}` and rolls the lead back,
  so no orphan records accumulate.
- The funnel's display labels (`₱`, en-dashes) are normalised to the database
  enum labels inside `create_booking`, so the two can drift independently.

## Photo uploads

Images are downscaled and re-encoded to JPEG in the browser, then uploaded
**straight to Supabase Storage** rather than through an API route, so they are
not subject to a serverless request-body limit. The `lead-uploads` bucket is
private, capped at 8 MB per file, and restricted to images and PDFs. A storage
policy allows writes only into a folder named after a lead created in the last
hour — and grants no read, update, or delete to visitors.

If an upload fails the booking still stands; the error is logged and the
customer keeps their slot.

## Reading the leads

Visitors cannot read the data, and neither can the publishable key. Use the
Supabase dashboard (Table Editor → `leads` / `bookings`) or a server-side
`service_role` key.

## Deploying

Vercel serves the repository root as static files. Every push to `main`
redeploys. Database changes live in `supabase/migrations/`.
