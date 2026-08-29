-- Two create_booking overloads existed; the enum-typed original has no
-- slot-conflict handling, no date bounds, and rejects the funnel's display
-- labels. Drop it so PostgREST can never resolve to it.
drop function if exists public.create_booking(
  public.project_kind, public.kitchen_size, public.budget_band,
  public.install_timeline, text, text, text, text, date, text, text, text
);

-- booked_slots(from_date, to_date) already existed and is range-bounded;
-- prefer it over the parameterless duplicate this project added.
drop function if exists public.get_booked_slots();
grant execute on function public.booked_slots(date, date) to anon, authenticated;

-- Pin search_path (flagged by the database linter)
create or replace function public.norm_enum(v text)
returns text
language sql
immutable
set search_path = public
as $$
  select btrim(replace(replace($1, '–', '-'), '₱', 'PHP '));
$$;
revoke all on function public.norm_enum(text) from public, anon, authenticated;

-- Event-trigger helper: never meant to be callable through the public API
revoke all on function public.rls_auto_enable() from public, anon, authenticated;
