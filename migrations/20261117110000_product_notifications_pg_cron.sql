-- Agendador dentro do Supabase: uma vez por minuto o banco gera os lembretes,
-- expira pedidos parados, encerra não comparecimentos e aciona o envio dos
-- pushes. Substitui a dependência do agendador externo (Render).
-- Onde pg_cron/pg_net não existem (testes locais) a migration só cria a função.
do $$ begin
  if exists(select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
  end if;
  if exists(select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  end if;
end $$;

-- A parte em SQL roda sempre; o envio dos pushes depende de dois segredos no
-- Vault ('project_url' e 'cron_secret', criados fora do repositório).
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
end $$;
revoke all on function public.run_product_notification_cycle() from public, anon, authenticated;

do $$ begin
  if exists(select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'product-notifications';
    perform cron.schedule('product-notifications', '* * * * *', 'select public.run_product_notification_cycle()');
  end if;
end $$;
