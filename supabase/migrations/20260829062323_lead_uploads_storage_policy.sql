drop policy if exists "anon can upload into own lead folder" on storage.objects;

-- Visitors may only WRITE, only into lead-uploads, and only into a folder
-- named after a lead that actually exists. No read/update/delete for anon.
create policy "anon can upload into own lead folder"
on storage.objects
for insert
to anon, authenticated
with check (
  bucket_id = 'lead-uploads'
  and (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and exists (
    select 1 from public.leads l
    where l.id = ((storage.foldername(name))[1])::uuid
      and l.created_at > now() - interval '1 hour'
  )
);
