-- Enable Supabase Realtime for request_attachments and service_payment_charges
-- so the mobile app can receive real-time notifications when:
-- 1. A payment receipt is uploaded (request_attachments INSERT)
-- 2. A payment charge status changes (service_payment_charges UPDATE)

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'request_attachments'
  ) then
    alter publication supabase_realtime add table public.request_attachments;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'service_payment_charges'
  ) then
    alter publication supabase_realtime add table public.service_payment_charges;
  end if;
end
$$;
