-- The storage policy's subquery ran as `anon`, and leads is RLS-protected with no
-- policies, so the lookup always found nothing. Check through a definer function.
create or replace function public.lead_accepts_uploads(p_lead_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.leads l
    where l.id = p_lead_id
      and l.created_at > now() - interval '1 hour'
  );
$$;

revoke all on function public.lead_accepts_uploads(uuid) from public, anon, authenticated;
grant execute on function public.lead_accepts_uploads(uuid) to anon, authenticated;

drop policy if exists "anon can upload into own lead folder" on storage.objects;

create policy "anon can upload into own lead folder"
on storage.objects
for insert
to anon, authenticated
with check (
  bucket_id = 'lead-uploads'
  and (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and public.lead_accepts_uploads(((storage.foldername(name))[1])::uuid)
);
