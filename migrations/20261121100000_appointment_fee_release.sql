-- Fase 2b: a taxa paga é liberada ao prestador quando o motorista confirma a chegada (no local)
-- ou o recebimento do veículo (leva e traz). O repasse reutiliza o motor dos chamados.

-- Cria o repasse com a comissão de 10%, igual ao chamado. Idempotente; não faz nada sem taxa paga.
create or replace function public.release_appointment_fee(p_appointment uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare a public.service_appointments; gross integer; platform_fee integer;
begin
  select * into a from public.service_appointments where id = p_appointment for update;
  if not found or a.fee_released_at is not null or a.fee_charge_id is null or a.fee_paid_at is null then return; end if;
  select coalesce(sum(e.gross_amount_cents), 0) into gross from public.provider_wallet_entries e
    where e.appointment_id = a.id and e.provider_id = a.provider_id and e.status = 'held';
  if gross <= 0 then raise exception 'Saldo da taxa não disponível para liberação.' using errcode = 'P0001'; end if;
  platform_fee := (gross * 10) / 100;
  insert into public.service_provider_transfers(appointment_id, provider_id, gross_amount_cents, platform_fee_cents, provider_net_cents)
  values (a.id, a.provider_id, gross, platform_fee, gross - platform_fee)
  on conflict (appointment_id) where appointment_id is not null do nothing;
  update public.service_appointments set fee_released_at = now(), updated_at = now() where id = a.id;
end $$;
revoke all on function public.release_appointment_fee(uuid) from public, anon, authenticated;

do $$
declare d text;
  arrival text := E'    perform public.notify_appointment(a.provider_id, a.id, ''arrival-confirmed''';
  delivery text := E'    perform public.notify_appointment(a.provider_id, a.id, ''delivery-confirmed''';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'driver_appointment_action';
  if position(arrival in d) = 0 or position(delivery in d) = 0 then raise exception 'driver_appointment_action mudou; ajuste a migration.'; end if;
  d := replace(d, arrival, E'    perform public.release_appointment_fee(a.id);\n' || arrival);
  d := replace(d, delivery, E'    perform public.release_appointment_fee(a.id);\n' || delivery);
  execute d;
end $$;

create or replace function public.claim_asaas_provider_transfer(p_transfer_id uuid)
returns table(transfer_id uuid, provider_net_cents integer, wallet_id text)
language plpgsql security definer set search_path to 'public' as $$
declare t public.service_provider_transfers; r public.service_requests; ap public.service_appointments; target_wallet text;
begin
  select * into t from public.service_provider_transfers x where x.id = p_transfer_id;
  if t.id is null then return; end if;
  if t.request_id is not null then
    select * into r from public.service_requests q where q.id = t.request_id for update;
  else
    select * into ap from public.service_appointments q where q.id = t.appointment_id for update;
  end if;
  select * into t from public.service_provider_transfers x where x.id = p_transfer_id for update;
  if t.id is null or t.status <> 'pending' then return; end if;
  if t.request_id is not null then
    if r.provider_arrival_confirmed_at is null or r.workflow_phase = 'in_dispute' then raise exception 'Confirmação pendente ou pagamento em disputa.'; end if;
  elsif ap.fee_released_at is null then
    raise exception 'Confirmação pendente.';
  end if;
  if exists (select 1 from public.service_payment_charges c
    where (c.request_id = t.request_id or c.appointment_id = t.appointment_id) and c.kind = 'dispatch' and (c.status <> 'paid' or c.settled_at is null)) then
    raise exception 'Aguardando liquidação.'; end if;
  select pa.wallet_id into target_wallet from public.provider_asaas_accounts pa where pa.provider_id = t.provider_id and pa.status = 'verified';
  if target_wallet is null then raise exception 'Conta não verificada.'; end if;
  update public.service_provider_transfers x set status = 'processing', initiated_at = now() where x.id = t.id;
  return query select t.id, t.provider_net_cents, target_wallet;
end $$;

create or replace function public.complete_dispatch_transfer(p_transfer_id uuid, p_asaas_transfer_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare t public.service_provider_transfers; latest uuid; allocated integer;
begin
  select * into t from public.service_provider_transfers where id = p_transfer_id for update;
  if t.id is null then raise exception 'Repasse inexistente.'; end if;
  if t.status = 'completed' then return; end if;
  if nullif(trim(p_asaas_transfer_id), '') is null or t.asaas_transfer_id is distinct from p_asaas_transfer_id then raise exception 'Referência financeira divergente.'; end if;
  if t.request_id is not null then
    if not exists (select 1 from public.service_requests r where r.id = t.request_id and r.provider_arrival_confirmed_at is not null) then raise exception 'Chegada não confirmada.'; end if;
  elsif not exists (select 1 from public.service_appointments a where a.id = t.appointment_id and a.fee_released_at is not null) then
    raise exception 'Liberação não confirmada.';
  end if;
  if exists (select 1 from public.service_payment_charges c
    where (c.request_id = t.request_id or c.appointment_id = t.appointment_id) and c.kind = 'dispatch' and (c.status <> 'paid' or c.settled_at is null)) then
    raise exception 'Pagamento ainda não liquidado.'; end if;
  if t.gross_amount_cents <> (select coalesce(sum(e.gross_amount_cents), 0) from public.provider_wallet_entries e
    where (e.request_id = t.request_id or e.appointment_id = t.appointment_id) and e.provider_id = t.provider_id and e.status = 'held') then
    raise exception 'Saldo divergente; requer conciliação.'; end if;
  select e.id into latest from public.provider_wallet_entries e join public.service_payment_charges c on c.id = e.charge_id
    where (e.request_id = t.request_id or e.appointment_id = t.appointment_id) and e.status = 'held' and c.kind = 'dispatch'
    order by e.created_at desc, e.id limit 1;
  select coalesce(sum((e.gross_amount_cents * 10) / 100), 0) into allocated from public.provider_wallet_entries e
    join public.service_payment_charges c on c.id = e.charge_id
    where (e.request_id = t.request_id or e.appointment_id = t.appointment_id) and e.status = 'held' and c.kind = 'dispatch' and e.id <> latest;
  update public.provider_wallet_entries e set status = 'available',
    platform_fee_cents = case when e.id = latest then t.platform_fee_cents - allocated else (e.gross_amount_cents * 10) / 100 end,
    provider_net_cents = e.gross_amount_cents - (case when e.id = latest then t.platform_fee_cents - allocated else (e.gross_amount_cents * 10) / 100 end), released_at = now()
    where (e.request_id = t.request_id or e.appointment_id = t.appointment_id) and e.status = 'held'
      and exists (select 1 from public.service_payment_charges c where c.id = e.charge_id and c.kind = 'dispatch');
  update public.service_provider_transfers set status = 'completed', completed_at = now(), failure_reason = null where id = t.id;
  if t.request_id is not null then
    update public.service_requests set payment_released_at = now() where id = t.request_id;
  else
    perform public.notify_appointment(t.provider_id, t.appointment_id, 'fee-released', 'Taxa de deslocamento liberada',
      'O valor da taxa já está disponível na sua carteira.');
  end if;
end $$;
