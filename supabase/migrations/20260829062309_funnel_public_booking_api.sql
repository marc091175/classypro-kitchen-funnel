-- Prevent double-booking atomically (only active bookings block a slot)
create unique index if not exists bookings_active_slot_uniq
  on public.bookings (survey_date, survey_slot)
  where status = 'booked';

-- Normalise funnel display text (peso sign, en-dashes) to the enum labels
create or replace function public.norm_enum(v text)
returns text language sql immutable as $$
  select btrim(replace(replace($1, '–', '-'), '₱', 'PHP '));
$$;

-- Public availability: exposes ONLY date+slot, never lead data
create or replace function public.get_booked_slots()
returns table (survey_date date, survey_slot text)
language sql
security definer
set search_path = public
stable
as $$
  select b.survey_date, b.survey_slot
  from public.bookings b
  where b.status = 'booked'
    and b.survey_date >= current_date;
$$;

-- Single atomic entry point: creates the lead + booking, returns ids
create or replace function public.create_booking(
  p_kitchen_type text,
  p_size         text,
  p_budget       text,
  p_timeline     text,
  p_full_name    text,
  p_phone        text,
  p_email        text default null,
  p_address      text default null,
  p_date         date default null,
  p_slot         text default null,
  p_referrer     text default null,
  p_user_agent   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead_id    uuid;
  v_booking_id uuid;
begin
  if p_date is null or p_date < current_date then
    return jsonb_build_object('ok', false, 'reason', 'bad_date');
  end if;
  if p_date > current_date + interval '90 days' then
    return jsonb_build_object('ok', false, 'reason', 'bad_date');
  end if;

  insert into public.leads (
    kitchen_type, size, budget, timeline,
    full_name, phone, email, address, referrer, user_agent
  ) values (
    public.norm_enum(p_kitchen_type)::project_kind,
    public.norm_enum(p_size)::kitchen_size,
    public.norm_enum(p_budget)::budget_band,
    public.norm_enum(p_timeline)::install_timeline,
    btrim(p_full_name),
    btrim(p_phone),
    nullif(btrim(coalesce(p_email, '')), ''),
    nullif(btrim(coalesce(p_address, '')), ''),
    left(coalesce(p_referrer, ''), 500),
    left(coalesce(p_user_agent, ''), 500)
  )
  returning id into v_lead_id;

  begin
    insert into public.bookings (lead_id, survey_date, survey_slot)
    values (v_lead_id, p_date, p_slot)
    returning id into v_booking_id;
  exception when unique_violation then
    -- roll the lead back with the slot so we do not orphan a record
    raise sqlstate 'P0001' using message = 'slot_taken';
  end;

  return jsonb_build_object(
    'ok', true,
    'lead_id', v_lead_id,
    'booking_id', v_booking_id
  );
exception
  when sqlstate 'P0001' then
    return jsonb_build_object('ok', false, 'reason', 'slot_taken');
  when invalid_text_representation then
    return jsonb_build_object('ok', false, 'reason', 'bad_option');
  when check_violation then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
end;
$$;

-- Records an uploaded file against a lead (path must live in that lead's folder)
create or replace function public.record_attachment(
  p_lead_id      uuid,
  p_storage_path text,
  p_file_name    text,
  p_content_type text,
  p_byte_size    bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if split_part(p_storage_path, '/', 1) <> p_lead_id::text then
    return jsonb_build_object('ok', false, 'reason', 'bad_path');
  end if;

  insert into public.lead_attachments (
    lead_id, storage_path, file_name, content_type, byte_size
  ) values (
    p_lead_id, p_storage_path, left(btrim(p_file_name), 200), p_content_type, p_byte_size
  )
  on conflict (storage_path) do nothing;

  return jsonb_build_object('ok', true);
exception when others then
  return jsonb_build_object('ok', false, 'reason', 'insert_failed');
end;
$$;

-- Lock down: anon may ONLY call these functions, never touch tables directly
revoke all on function public.get_booked_slots() from public, anon, authenticated;
revoke all on function public.create_booking(text,text,text,text,text,text,text,text,date,text,text,text) from public, anon, authenticated;
revoke all on function public.record_attachment(uuid,text,text,text,bigint) from public, anon, authenticated;
revoke all on function public.norm_enum(text) from public, anon, authenticated;

grant execute on function public.get_booked_slots() to anon, authenticated;
grant execute on function public.create_booking(text,text,text,text,text,text,text,text,date,text,text,text) to anon, authenticated;
grant execute on function public.record_attachment(uuid,text,text,text,bigint) to anon, authenticated;
