-- O Asaas não envia o evento de aprovação das subcontas ao nosso webhook; o ciclo por minuto aciona
-- a conciliação (process-appointment-fees) também quando há cadastro financeiro em análise.
create or replace function public.run_product_notification_cycle() returns void
language plpgsql security definer set search_path = public as $$
declare project_url text; cron_secret text;
begin
  perform public.enqueue_product_reminders();
  select decrypted_secret into project_url from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into cron_secret from vault.decrypted_secrets where name = 'cron_secret';
  if project_url is null or cron_secret is null then return; end if;
  perform net.http_post(
    url := project_url || '/functions/v1/process-product-notifications',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', cron_secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 20000);
  if exists (select 1 from public.service_payment_charges c where c.appointment_id is not null and (
        (c.refund_requested_at is not null and c.status = 'paid')
        or (c.status in ('awaiting_payment', 'paid') and c.settled_at is null and c.asaas_payment_id is not null and c.updated_at < now() - interval '2 minutes')))
    or exists (select 1 from public.service_provider_transfers t where t.appointment_id is not null and t.status in ('pending', 'processing'))
    or exists (select 1 from public.provider_asaas_accounts a where a.status::text = 'verification_requested' and a.updated_at < now() - interval '3 minutes') then
    perform net.http_post(
      url := project_url || '/functions/v1/process-appointment-fees',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', cron_secret),
      body := '{}'::jsonb,
      timeout_milliseconds := 20000);
  end if;
end $$;
revoke all on function public.run_product_notification_cycle() from public, anon, authenticated;
