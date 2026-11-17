-- Aviso ao prestador quando o Asaas aprova ou recusa o cadastro financeiro.
alter table public.product_notifications drop constraint product_notifications_category_check;
alter table public.product_notifications add constraint product_notifications_category_check
  check (category = any (array['maintenance','appointments','sharing','finance']));

create or replace function public.notify_financial_account_decision() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status::text = 'verified' then
    insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    values (new.provider_id, 'finance', 'Conta financeira aprovada',
      'Seu cadastro foi aprovado pelo Asaas. Você já pode receber taxas de deslocamento e repasses na sua carteira.',
      new.provider_id, 'asaas-approved:' || new.provider_id::text || ':' || extract(epoch from coalesce(new.verified_at, now()))::bigint::text)
    on conflict (dedupe_key) do nothing;
  elsif new.status::text = 'rejected' then
    insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    values (new.provider_id, 'finance', 'Cadastro financeiro recusado',
      coalesce(nullif(trim(new.rejection_reason), ''), 'O Asaas recusou o cadastro.') || ' Revise os documentos na sua carteira e envie novamente.',
      new.provider_id, 'asaas-rejected:' || new.provider_id::text || ':' || extract(epoch from now())::bigint::text)
    on conflict (dedupe_key) do nothing;
  end if;
  return new;
end $$;
revoke all on function public.notify_financial_account_decision() from public, anon, authenticated;
create trigger provider_asaas_accounts_notify_decision after update of status on public.provider_asaas_accounts
  for each row when (new.status::text in ('verified','rejected') and old.status is distinct from new.status)
  execute function public.notify_financial_account_decision();

CREATE OR REPLACE FUNCTION public.product_notification_is_current(p_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
 select coalesce((select case when n.category='maintenance' then exists(
 select 1 from public.vehicle_maintenance_plans p join public.vehicles v on v.id=p.vehicle_id left join public.vehicle_odometer_readings o on o.id=v.odometer_reading_id
 where p.id=n.resource_id and p.created_by=n.user_id and (v.owner_profile_id=p.created_by or exists(select 1 from public.organizations where id=v.organization_id and owner_id=p.created_by))
 and n.dedupe_key='maintenance:'||p.id::text||':'||p.occurrence_id::text||':'||p.revision::text||':'||case when p.due_date<=current_date or o.odometer>=p.due_odometer then 'due' else 'soon' end
 and (p.due_date<=current_date+p.remind_days or o.odometer>=p.due_odometer-p.remind_km))
 when n.category='appointments' then exists(select 1 from public.service_appointments a where a.id=n.resource_id and n.user_id in(a.requester_id,a.provider_id)
 and (n.dedupe_key not like 'appointment-reminder:%' or (a.status='confirmed' and a.starts_at>now()))
 and (n.dedupe_key not like 'appointment-expiry-reminder:%' or a.status='requested')
 and (n.dedupe_key not like 'appointment-late:%' or (a.status='confirmed' and a.started_at is null and a.service_request_id is null)))
 when n.category='finance' then exists(select 1 from public.provider_asaas_accounts a where a.provider_id=n.resource_id and a.provider_id=n.user_id
 and a.status::text=case when n.dedupe_key like 'asaas-approved:%' then 'verified' else 'rejected' end)
 else exists(select 1 from public.vehicle_share_invites i join public.vehicles v on v.id=i.vehicle_id join auth.users u on u.id=n.user_id
 where i.id=n.resource_id and i.status='pending' and i.expires_at>now() and (i.access_expires_at is null or i.access_expires_at>now()) and lower(u.email)=i.recipient_email
 and (v.owner_profile_id=i.invited_by or exists(select 1 from public.organizations where id=v.organization_id and owner_id=i.invited_by))) end from public.product_notifications n where n.id=p_id),false);
$function$;
