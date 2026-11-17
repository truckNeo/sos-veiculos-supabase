-- Fase 2c: o que acontece com a taxa quando o agendamento não se completa.
--  * Taxa não paga no prazo: o agendamento é cancelado.
--  * Cancelamento antes de o mecânico sair, cancelamento do prestador, atraso recusado ou mecânico
--    além de 30 min do horário: reembolso integral.
--  * Motorista cancela com o mecânico a caminho: a taxa fica retida; o prestador pode abrir disputa
--    em até 48 h. Sem disputa, a taxa é devolvida ao motorista.

alter table public.service_payment_charges
  add column refund_requested_at timestamptz,
  add column refund_reason text;
alter table public.service_appointments
  add column fee_refund_requested_at timestamptz,
  add column fee_retained_at timestamptz,
  add column fee_dispute_opened_at timestamptz;

-- Pede o reembolso integral da taxa paga e ainda não liberada. Idempotente.
create or replace function public.request_appointment_fee_refund(p_appointment uuid, p_reason text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare a public.service_appointments;
begin
  select * into a from public.service_appointments where id = p_appointment for update;
  if not found or a.fee_charge_id is null or a.fee_paid_at is null
    or a.fee_released_at is not null or a.fee_refund_requested_at is not null or a.fee_refunded_at is not null then return; end if;
  update public.service_payment_charges set refund_requested_at = now(), refund_reason = p_reason
    where id = a.fee_charge_id and status = 'paid';
  update public.service_appointments set fee_refund_requested_at = now(), updated_at = now() where id = a.id;
  perform public.notify_appointment(a.requester_id, a.id, 'fee-refund', 'Reembolso da taxa solicitado',
    'A taxa de deslocamento será devolvida pelo mesmo meio de pagamento.');
end $$;
revoke all on function public.request_appointment_fee_refund(uuid, text) from public, anon, authenticated;

-- Encerrar um agendamento decide o destino da taxa.
create or replace function public.settle_appointment_fee_on_close()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare provider_late boolean;
begin
  if new.fee_released_at is not null then return new; end if;
  if new.fee_paid_at is null then
    update public.service_payment_charges set status = 'expired' where id = new.fee_charge_id and status = 'pending';
    return new;
  end if;
  provider_late := now() > coalesce(case when old.delay_status = 'accepted' then old.delay_arrival_at end, old.starts_at) + interval '30 minutes';
  if old.status = 'confirmed' and old.stage = 'heading' and auth.uid() = new.requester_id
    and new.cancel_reason is distinct from 'delay_refused' and not provider_late then
    update public.service_appointments set fee_retained_at = now() where id = new.id;
    perform public.notify_appointment(new.provider_id, new.id, 'fee-retained', 'Taxa retida',
      'O motorista cancelou com você a caminho. A taxa fica retida: abra uma disputa em até 48 horas ou ela será devolvida a ele.');
    perform public.notify_appointment(new.requester_id, new.id, 'fee-retained-driver', 'Taxa retida',
      'O mecânico já estava a caminho. A taxa fica retida enquanto o prestador pode abrir uma disputa (até 48 horas); sem disputa, ela é devolvida.');
  else
    perform public.request_appointment_fee_refund(new.id, case when provider_late then 'provider_late' else 'cancelled' end);
  end if;
  return new;
end $$;
revoke all on function public.settle_appointment_fee_on_close() from public, anon, authenticated;
create trigger service_appointments_settle_fee after update of status on public.service_appointments
  for each row when (new.fee_charge_id is not null and new.status in ('cancelled','rejected','no_show','expired') and old.status is distinct from new.status)
  execute function public.settle_appointment_fee_on_close();

-- Prestador contesta a retenção.
create or replace function public.open_appointment_fee_dispute(p_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare a public.service_appointments;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is distinct from a.provider_id then raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if a.fee_dispute_opened_at is not null then return; end if;
  if a.fee_retained_at is null or a.fee_released_at is not null or a.fee_refund_requested_at is not null then
    raise exception 'Não há taxa retida para contestar.' using errcode = 'P0001'; end if;
  if now() > a.fee_retained_at + interval '48 hours' then raise exception 'O prazo para abrir disputa terminou.' using errcode = 'P0001'; end if;
  update public.service_appointments set fee_dispute_opened_at = now(), updated_at = now() where id = a.id;
  perform public.notify_appointment(a.requester_id, a.id, 'fee-dispute', 'Disputa aberta',
    'O prestador contestou a retenção da taxa. A equipe vai analisar e decidir.');
end $$;
revoke all on function public.open_appointment_fee_dispute(uuid) from public, anon;
grant execute on function public.open_appointment_fee_dispute(uuid) to authenticated;

-- Decisão da equipe sobre a disputa (somente service_role).
create or replace function public.decide_appointment_fee_dispute(p_id uuid, p_decision text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare a public.service_appointments;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or a.fee_dispute_opened_at is null or a.fee_released_at is not null or a.fee_refund_requested_at is not null then
    raise exception 'Não há disputa pendente.' using errcode = 'P0001'; end if;
  if p_decision = 'provider' then
    perform public.release_appointment_fee(a.id);
    perform public.notify_appointment(a.requester_id, a.id, 'fee-decided', 'Disputa decidida', 'A taxa foi liberada ao prestador.');
  elsif p_decision = 'driver' then
    perform public.request_appointment_fee_refund(a.id, 'dispute_driver');
    perform public.notify_appointment(a.provider_id, a.id, 'fee-decided', 'Disputa decidida', 'A taxa foi devolvida ao motorista.');
  else
    raise exception 'Decisão inválida.' using errcode = 'P0001';
  end if;
end $$;
revoke all on function public.decide_appointment_fee_dispute(uuid, text) from public, anon, authenticated;
grant execute on function public.decide_appointment_fee_dispute(uuid, text) to service_role;

-- Rotina por minuto (chamada por process_late_appointments).
create or replace function public.process_appointment_fees()
returns void language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  for r in select id, requester_id, provider_id from public.service_appointments
    where status = 'confirmed' and fee_charge_id is not null and fee_paid_at is null and payment_due_at < now() for update skip locked loop
    update public.service_appointments set status = 'cancelled', cancel_reason = 'fee_unpaid', stage = null, updated_at = now() where id = r.id;
    perform public.notify_appointment(r.requester_id, r.id, 'fee-unpaid', 'Agendamento cancelado', 'A taxa de deslocamento não foi paga no prazo.');
    perform public.notify_appointment(r.provider_id, r.id, 'fee-unpaid', 'Agendamento cancelado', 'O motorista não pagou a taxa de deslocamento no prazo.');
  end loop;
  for r in select id from public.service_appointments
    where fee_retained_at is not null and fee_dispute_opened_at is null and fee_released_at is null
      and fee_refund_requested_at is null and fee_retained_at < now() - interval '48 hours' loop
    perform public.request_appointment_fee_refund(r.id, 'retention_expired');
  end loop;
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
  select a.requester_id, 'appointments', 'Mecânico atrasado',
    'O mecânico passou de 30 minutos do horário. Você pode cancelar o agendamento e receber a taxa de volta.', a.id,
    'appointment-provider-late:' || a.id::text
  from public.service_appointments a
  where a.status = 'confirmed' and a.fee_paid_at is not null and a.fee_released_at is null and a.stage is distinct from 'arrived'
    and now() > coalesce(case when a.delay_status = 'accepted' then a.delay_arrival_at end, a.starts_at) + interval '30 minutes'
  on conflict (dedupe_key) do nothing;
end $$;
revoke all on function public.process_appointment_fees() from public, anon, authenticated;

do $$
declare d text; anchor text := E'begin\n  with closed as (';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'process_late_appointments';
  if position(anchor in d) = 0 then raise exception 'process_late_appointments mudou; ajuste a migration.'; end if;
  execute replace(d, anchor, E'begin\n  perform public.process_appointment_fees();\n  with closed as (');
end $$;

-- Pagamento que chega depois de o agendamento ser encerrado volta ao motorista.
do $$
declare d text; anchor text := E'    perform public.notify_appointment(appointment_row.provider_id, appointment_row.id, ''fee-paid''';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'confirm_asaas_charge_payment';
  if position(anchor in d) = 0 then raise exception 'confirm_asaas_charge_payment mudou; ajuste a migration.'; end if;
  execute replace(d, anchor, E'    if appointment_row.status <> ''confirmed'' then\n      perform public.request_appointment_fee_refund(appointment_row.id, ''late_payment'');\n      return;\n    end if;\n' || anchor);
end $$;

-- Estorno confirmado: carteira revertida e agendamento atualizado. Reembolso de agendamento não
-- bloqueia a conta do prestador (só contestação de cartão).
create or replace function public.record_payment_reversal(p_charge_id uuid, p_state text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c public.service_payment_charges;
begin
 select * into c from service_payment_charges where id=p_charge_id for update;
 if c.id is null then raise exception 'Cobrança inexistente.'; end if;
 if p_state not in ('REFUNDED','REFUND_REQUESTED','REFUND_IN_PROGRESS','CHARGEBACK_REQUESTED','CHARGEBACK_DISPUTE','AWAITING_CHARGEBACK_REVERSAL','DUNNING_REQUESTED') then raise exception 'Estado inválido.'; end if;
 update service_payment_charges set financial_status=p_state,settled_at=null where id=c.id;
 if not (c.appointment_id is not null and p_state in ('REFUNDED','REFUND_REQUESTED','REFUND_IN_PROGRESS')) then
  update provider_asaas_accounts set financial_block_reason='Pagamento em estorno ou contestação: '||c.id where provider_id=c.provider_id;
 end if;
 if p_state='REFUNDED' then
  update service_payment_charges set status='cancelled' where id=c.id;
  update provider_wallet_entries set status='reversed' where charge_id=c.id and status='held';
  if c.appointment_id is not null then
   update service_appointments set fee_refunded_at=coalesce(fee_refunded_at,now()), updated_at=now() where id=c.appointment_id;
   perform public.notify_appointment((select requester_id from service_appointments where id=c.appointment_id), c.appointment_id, 'fee-refunded', 'Taxa devolvida', 'A taxa de deslocamento foi devolvida.');
  end if;
 end if;
end $$;

-- O app precisa do destino da taxa nas leituras.
drop function if exists public.list_my_service_appointments();
drop function if exists public.get_service_appointment_detail(uuid);

-- Fase 2a: o app precisa do estado da cobrança da taxa.
create function public.list_my_service_appointments()
returns table(id uuid, requester_id uuid, provider_id uuid, vehicle_id uuid, starts_at timestamptz, ends_at timestamptz, description text, status text, service_request_id uuid, maintenance_plan_id uuid, vehicle_label text, provider_name text, vehicle_odometer integer, proposed_starts_at timestamptz, proposed_ends_at timestamptz, proposed_by uuid, service_mode text, location_label text, started_at timestamptz, finished_at timestamptz, cancel_reason text, requester_name text, has_review boolean, travel_fee_cents integer, stage text, eta_minutes integer, delivery_at timestamptz, delivery_proposed_at timestamptz, delay_minutes integer, delay_status text, delay_arrival_at timestamptz, created_at timestamptz, fee_charge_id uuid, payment_due_at timestamptz, fee_paid_at timestamptz, fee_released_at timestamptz, fee_refund_requested_at timestamptz, fee_refunded_at timestamptz, fee_retained_at timestamptz, fee_dispute_opened_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select a.id, a.requester_id, a.provider_id, a.vehicle_id, a.starts_at, a.ends_at, a.description, a.status,
    a.service_request_id, a.maintenance_plan_id, v.model || ' · ' || v.plate, p.business_name,
    a.vehicle_odometer, a.proposed_starts_at, a.proposed_ends_at, a.proposed_by,
    a.service_mode, a.location_label, a.started_at, a.finished_at, a.cancel_reason, r.full_name,
    exists(select 1 from public.reviews rv where rv.appointment_id = a.id and rv.reviewer_id = a.requester_id),
    a.travel_fee_cents, a.stage, a.eta_minutes, a.delivery_at, a.delivery_proposed_at,
    a.delay_minutes, a.delay_status, a.delay_arrival_at, a.created_at,
    a.fee_charge_id, a.payment_due_at, a.fee_paid_at, a.fee_released_at,
    a.fee_refund_requested_at, a.fee_refunded_at, a.fee_retained_at, a.fee_dispute_opened_at
  from public.service_appointments a join public.vehicles v on v.id = a.vehicle_id
  join public.provider_profiles p on p.provider_id = a.provider_id
  join public.profiles r on r.id = a.requester_id
  where auth.uid() in (a.requester_id, a.provider_id)
  order by a.starts_at desc limit 200;
$$;
revoke all on function public.list_my_service_appointments() from public, anon;
grant execute on function public.list_my_service_appointments() to authenticated;

drop function if exists public.get_service_appointment_detail(p_id uuid);
create function public.get_service_appointment_detail(p_id uuid)
returns table(id uuid, requester_id uuid, provider_id uuid, vehicle_id uuid, starts_at timestamptz, ends_at timestamptz, description text, status text, service_request_id uuid, maintenance_plan_id uuid, vehicle_label text, provider_name text, vehicle_odometer integer, proposed_starts_at timestamptz, proposed_ends_at timestamptz, proposed_by uuid, service_mode text, location_label text, started_at timestamptz, finished_at timestamptz, cancel_reason text, requester_name text, has_review boolean, travel_fee_cents integer, stage text, eta_minutes integer, delivery_at timestamptz, delivery_proposed_at timestamptz, delay_minutes integer, delay_status text, delay_arrival_at timestamptz, created_at timestamptz, fee_charge_id uuid, payment_due_at timestamptz, fee_paid_at timestamptz, fee_released_at timestamptz, fee_refund_requested_at timestamptz, fee_refunded_at timestamptz, fee_retained_at timestamptz, fee_dispute_opened_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select a.id, a.requester_id, a.provider_id, a.vehicle_id, a.starts_at, a.ends_at, a.description, a.status,
    a.service_request_id, a.maintenance_plan_id, v.model || ' · ' || v.plate, p.business_name,
    a.vehicle_odometer, a.proposed_starts_at, a.proposed_ends_at, a.proposed_by,
    a.service_mode, a.location_label, a.started_at, a.finished_at, a.cancel_reason, r.full_name,
    exists(select 1 from public.reviews rv where rv.appointment_id = a.id and rv.reviewer_id = a.requester_id),
    a.travel_fee_cents, a.stage, a.eta_minutes, a.delivery_at, a.delivery_proposed_at,
    a.delay_minutes, a.delay_status, a.delay_arrival_at, a.created_at,
    a.fee_charge_id, a.payment_due_at, a.fee_paid_at, a.fee_released_at,
    a.fee_refund_requested_at, a.fee_refunded_at, a.fee_retained_at, a.fee_dispute_opened_at
  from public.service_appointments a join public.vehicles v on v.id = a.vehicle_id
  join public.provider_profiles p on p.provider_id = a.provider_id
  join public.profiles r on r.id = a.requester_id
  where a.id = p_id and auth.uid() in (a.requester_id, a.provider_id);
$$;
revoke all on function public.get_service_appointment_detail(p_id uuid) from public, anon;
grant execute on function public.get_service_appointment_detail(p_id uuid) to authenticated;

-- O ciclo por minuto também aciona a conciliação das taxas quando há trabalho pendente.
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
    or exists (select 1 from public.service_provider_transfers t where t.appointment_id is not null and t.status in ('pending', 'processing')) then
    perform net.http_post(
      url := project_url || '/functions/v1/process-appointment-fees',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', cron_secret),
      body := '{}'::jsonb,
      timeout_milliseconds := 20000);
  end if;
end $$;
revoke all on function public.run_product_notification_cycle() from public, anon, authenticated;
