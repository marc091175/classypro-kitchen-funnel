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

<!-- deploy pipeline verified 2026-08-29 -->

## Booking notifications

Every insert into `bookings` fires the `trg_notify_booking_created` trigger,
which calls the `notify-booking` Edge Function over `pg_net`. The function sends
an alert on whichever channels are configured — email and WhatsApp are
independent, so one failing never suppresses the other.

The trigger authenticates to the function with a shared secret that is generated
inside Postgres and **never leaves it**: the function verifies a candidate secret
via `verify_notify_secret()`, which returns only a boolean and is executable
solely by `service_role`. The function runs with `verify_jwt = false` because its
caller is a database trigger, not a signed-in user.

A notification failure can never block a booking — the trigger swallows its own
errors and records them in `private.notification_log`.

### Configuring channels

Set these as Edge Function secrets (`supabase secrets set KEY=value`):

| Channel | Required secrets |
|---|---|
| Email | `RESEND_API_KEY`, `NOTIFY_EMAIL_TO` |
| WhatsApp (Twilio) | `WHATSAPP_PROVIDER=twilio`, `WHATSAPP_TO`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_WHATSAPP_FROM` |
| WhatsApp (Meta) | `WHATSAPP_PROVIDER=meta`, `WHATSAPP_TO`, `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_TEMPLATE` |

Meta only delivers business-initiated messages via an approved template outside
the 24-hour customer-service window; set `WHATSAPP_TEMPLATE` once approved.

### Checking delivery

```sql
select l.created_at, l.note, r.status_code, r.content
from private.notification_log l
left join net._http_response r on r.id = l.net_request_id
order by l.id desc limit 20;
```
