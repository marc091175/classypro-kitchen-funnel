-- Verifies a candidate secret without ever returning it. Only the service_role
-- (which Supabase injects into Edge Functions) may call this.
create or replace function public.verify_notify_secret(p_secret text)
returns boolean
language sql
security definer
set search_path = public, private
stable
as $$
  select exists (
    select 1 from private.notify_config
    where key = 'webhook_secret' and value = p_secret
  );
$$;

revoke all on function public.verify_notify_secret(text) from public, anon, authenticated;
grant execute on function public.verify_notify_secret(text) to service_role;
