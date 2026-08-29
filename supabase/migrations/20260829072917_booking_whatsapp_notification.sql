create extension if not exists pg_net with schema extensions;

-- `private` is not exposed through PostgREST, so config never reaches the browser.
create schema if not exists private;
revoke all on schema private from anon, authenticated;

create table if not exists private.notify_config (
  key   text primary key,
  value text not null
);
revoke all on private.notify_config from anon, authenticated;

insert into private.notify_config (key, value) values
  ('function_url', 'https://dvbutyrjrsxvnnibnclc.supabase.co/functions/v1/notify-booking'),
  ('webhook_secret', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;

-- Records every dispatch so a silent failure is still visible after the fact.
create table if not exists private.notification_log (
  id             bigserial primary key,
  booking_id     uuid,
  created_at     timestamptz not null default now(),
  net_request_id bigint,
  note           text
);
revoke all on private.notification_log from anon, authenticated;

create or replace function public.notify_booking_created()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  v_url    text;
  v_secret text;
  v_lead   record;
  v_req_id bigint;
begin
  select value into v_url    from private.notify_config where key = 'function_url';
  select value into v_secret from private.notify_config where key = 'webhook_secret';
  if v_url is null or v_secret is null then
    return new;
  end if;

  select l.full_name, l.phone, l.email, l.address,
         l.kitchen_type::text as kitchen_type, l.size::text as size,
         l.budget::text as budget, l.timeline::text as timeline
    into v_lead
  from public.leads l
  where l.id = new.lead_id;

  select net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-webhook-secret', v_secret
               ),
    body    := jsonb_build_object(
                 'booking_id',   new.id,
                 'full_name',    v_lead.full_name,
                 'phone',        v_lead.phone,
                 'email',        v_lead.email,
                 'address',      v_lead.address,
                 'kitchen_type', v_lead.kitchen_type,
                 'size',         v_lead.size,
                 'budget',       v_lead.budget,
                 'timeline',     v_lead.timeline,
                 'survey_date',  to_char(new.survey_date, 'YYYY-MM-DD'),
                 'survey_slot',  new.survey_slot
               ),
    timeout_milliseconds := 5000
  ) into v_req_id;

  insert into private.notification_log (booking_id, net_request_id, note)
  values (new.id, v_req_id, 'dispatched');

  return new;
exception when others then
  -- A notification problem must never block a customer's booking.
  insert into private.notification_log (booking_id, note)
  values (new.id, 'dispatch failed: ' || sqlerrm);
  return new;
end;
$$;

drop trigger if exists trg_notify_booking_created on public.bookings;

create trigger trg_notify_booking_created
after insert on public.bookings
for each row
execute function public.notify_booking_created();

revoke all on function public.notify_booking_created() from public, anon, authenticated;
