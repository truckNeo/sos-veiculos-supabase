-- Uma operação durável por cobrança estornada ou repasse de disputa.
-- POST financeiro nunca é repetido automaticamente após resultado incerto.
create table public.asaas_dispute_operations (
  id uuid primary key default gen_random_uuid(),
  dispute_id uuid not null references public.service_disputes(id),
  request_id uuid not null references public.service_requests(id),
  charge_id uuid references public.service_payment_charges(id),
  decision public.service_dispute_status not null check (decision in ('driver_refunded', 'provider_released')),
  amount_cents integer not null check (amount_cents > 0),
  asaas_payment_id text,
  wallet_id text,
  sandbox boolean not null,
  status text not null default 'pending' check (status in ('pending','processing','confirmed','manual_review')),
  external_id text,
  requested_by uuid not null references public.profiles(id),
  decision_note text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (dispute_id, charge_id),
  check ((decision = 'driver_refunded' and charge_id is not null and asaas_payment_id is not null)
      or (decision = 'provider_released' and charge_id is null and wallet_id is not null))
);
alter table public.asaas_dispute_operations enable row level security;
revoke all on public.asaas_dispute_operations from anon, authenticated;
grant select, update on public.asaas_dispute_operations to service_role;

create or replace function public.begin_asaas_dispute_settlement(
  p_request_id uuid, p_decision public.service_dispute_status, p_note text
) returns setof public.asaas_dispute_operations
language plpgsql security definer set search_path = public as $$
declare d public.service_disputes; r public.service_requests; gross integer; wallet text;
  sandbox_mode boolean; transfer_row public.service_provider_transfers;
begin
  if not public.is_service_dispute_admin() then raise exception 'Acesso restrito ao console de disputas.' using errcode='42501'; end if;
  if p_decision is null or p_decision not in ('driver_refunded','provider_released') then raise exception 'Decisão financeira inválida.' using errcode='22023'; end if;
  if p_note is null or char_length(trim(p_note)) not between 10 and 2000 then raise exception 'Justificativa inválida.' using errcode='22023'; end if;
  select * into r from public.service_requests where id=p_request_id for update;
  select * into d from public.service_disputes where request_id=p_request_id and status='open' for update;
  if d.id is null or r.workflow_phase <> 'in_dispute' then raise exception 'Disputa aberta não encontrada.'; end if;
  if exists(select 1 from public.asaas_dispute_operations where dispute_id=d.id and decision<>p_decision) then raise exception 'Já existe outra decisão financeira em processamento.'; end if;
  if exists(select 1 from public.asaas_dispute_operations where dispute_id=d.id) then
    return query select * from public.asaas_dispute_operations where dispute_id=d.id order by created_at,id;
    return;
  end if;
  if exists(select 1 from public.provider_wallet_entries where request_id=p_request_id and status<>'held') then raise exception 'Saldo já movimentado; requer conciliação financeira.'; end if;
  if exists(select 1 from public.service_provider_transfers where request_id=p_request_id) then raise exception 'Já existe repasse; requer conciliação financeira.'; end if;
  if exists(select 1 from public.service_payment_charges where request_id=p_request_id and status='paid' and (payment_provider<>'asaas' or asaas_payment_id is null)) then raise exception 'Cobrança fora do Asaas; requer conciliação financeira.'; end if;
  if (select count(distinct asaas_sandbox) from public.service_payment_charges where request_id=p_request_id and status='paid') <> 1 then raise exception 'Cobranças ausentes ou ambientes financeiros incompatíveis.'; end if;
  select coalesce(sum(gross_amount_cents),0) into gross from public.provider_wallet_entries where request_id=p_request_id and status='held';
  if gross <= 0 or gross <> (select coalesce(sum(amount_cents),0) from public.service_payment_charges where request_id=p_request_id and status='paid') then raise exception 'Saldo retido divergente das cobranças; requer conciliação.'; end if;
  if p_decision='driver_refunded' then
    insert into public.asaas_dispute_operations(dispute_id,request_id,charge_id,decision,amount_cents,asaas_payment_id,sandbox,requested_by,decision_note)
    select d.id,p_request_id,c.id,p_decision,c.amount_cents,c.asaas_payment_id,c.asaas_sandbox,auth.uid(),trim(p_note)
    from public.service_payment_charges c where c.request_id=p_request_id and c.status='paid';
  else
    select wallet_id into wallet from public.provider_asaas_accounts where provider_id=r.selected_provider_id and status='verified';
    if wallet is null then raise exception 'Subconta do prestador não verificada.'; end if;
    select asaas_sandbox into sandbox_mode from public.service_payment_charges where request_id=p_request_id and status='paid' limit 1;
    insert into public.service_provider_transfers(request_id,provider_id,gross_amount_cents,platform_fee_cents,provider_net_cents,status,initiated_at)
    values(p_request_id,r.selected_provider_id,gross,gross*10/100,gross-gross*10/100,'processing',now()) returning * into transfer_row;
    insert into public.asaas_dispute_operations(id,dispute_id,request_id,decision,amount_cents,wallet_id,sandbox,requested_by,decision_note)
    values(transfer_row.id,d.id,p_request_id,p_decision,transfer_row.provider_net_cents,wallet,sandbox_mode,auth.uid(),trim(p_note));
  end if;
  return query select * from public.asaas_dispute_operations where dispute_id=d.id order by created_at,id;
end; $$;

create or replace function public.claim_asaas_dispute_operation(p_operation_id uuid)
returns setof public.asaas_dispute_operations
language sql security definer set search_path=public as $$
  update public.asaas_dispute_operations set status='processing',updated_at=now()
  where id=p_operation_id and status='pending' returning *;
$$;

-- Mantém a assinatura pública, mas impede que o app feche uma disputa sem
-- comprovação do gateway. A Edge Function usa esta mesma validação ao finalizar.
create or replace function public.decide_service_dispute(
  p_request_id uuid, p_decision public.service_dispute_status, p_decision_note text
) returns void language plpgsql security definer set search_path=public as $$
declare d public.service_disputes; r public.service_requests; transfer_row public.service_provider_transfers;
  newest uuid; allocated integer;
begin
  if not public.is_service_dispute_admin() then raise exception 'Acesso restrito ao console de disputas.' using errcode='42501'; end if;
  if p_decision is null or p_decision not in ('provider_released','driver_refunded','cancelled') then raise exception 'Decisão inválida.' using errcode='22023'; end if;
  if p_decision_note is null or char_length(trim(p_decision_note)) not between 10 and 2000 then raise exception 'Justificativa inválida.' using errcode='22023'; end if;
  select * into r from public.service_requests where id=p_request_id for update;
  select * into d from public.service_disputes where request_id=p_request_id for update;
  if d.id is null then raise exception 'Disputa não encontrada.'; end if;
  if d.status=p_decision then return; end if;
  if d.status<>'open' then raise exception 'Disputa já decidida.'; end if;
  if p_decision='cancelled' then
    if exists(select 1 from public.service_payment_charges where request_id=p_request_id and status='paid')
      or exists(select 1 from public.asaas_dispute_operations where dispute_id=d.id) then
      raise exception 'Há pagamento recebido; escolha reembolso ou repasse.';
    end if;
  else
    if not exists(select 1 from public.asaas_dispute_operations where dispute_id=d.id and decision=p_decision)
      or exists(select 1 from public.asaas_dispute_operations where dispute_id=d.id and (decision<>p_decision or status<>'confirmed')) then
      raise exception 'Aguardando confirmação financeira do Asaas. Atualize a decisão após a confirmação.';
    end if;
    if p_decision='provider_released' then
      select * into transfer_row from public.service_provider_transfers where request_id=p_request_id for update;
      select id into newest from public.provider_wallet_entries where request_id=p_request_id and status='held' order by created_at desc,id desc limit 1;
      select coalesce(sum(gross_amount_cents*10/100),0) into allocated from public.provider_wallet_entries where request_id=p_request_id and status='held' and id<>newest;
      update public.provider_wallet_entries set status='available',released_at=now(),
        platform_fee_cents=case when id=newest then transfer_row.platform_fee_cents-allocated else gross_amount_cents*10/100 end,
        provider_net_cents=gross_amount_cents-(case when id=newest then transfer_row.platform_fee_cents-allocated else gross_amount_cents*10/100 end)
      where request_id=p_request_id and status='held';
      update public.service_provider_transfers set status='completed', completed_at=now(),
        asaas_transfer_id=(select external_id from public.asaas_dispute_operations where dispute_id=d.id and decision='provider_released')
      where id=transfer_row.id;
    else
      update public.provider_wallet_entries set status='reversed',released_at=null where request_id=p_request_id and status='held';
    end if;
  end if;
  update public.service_disputes set status=p_decision,decision_note=trim(p_decision_note),decided_by=auth.uid(),decided_at=now() where id=d.id;
  update public.service_requests set workflow_phase=(case when p_decision='cancelled' then 'cancelled' else 'completed' end)::public.service_workflow_phase,
    status=(case when p_decision='cancelled' then 'cancelled' else 'completed' end)::public.service_request_status,
    closed_at=now(),payment_released_at=case when p_decision='provider_released' then now() else payment_released_at end where id=p_request_id;
  insert into public.service_request_events(request_id,actor_id,status,note)
  values(p_request_id,auth.uid(),case when p_decision='cancelled' then 'cancelled'::public.service_request_status else 'completed'::public.service_request_status end,
    'Disputa decidida após confirmação financeira: '||p_decision||'. '||trim(p_decision_note));
end; $$;
revoke all on function public.begin_asaas_dispute_settlement(uuid,public.service_dispute_status,text),public.claim_asaas_dispute_operation(uuid) from public;
grant execute on function public.begin_asaas_dispute_settlement(uuid,public.service_dispute_status,text) to authenticated;
grant execute on function public.claim_asaas_dispute_operation(uuid) to service_role;
-- As funções administrativas anteriores revogavam PUBLIC sem conceder execução à role da Edge Function.
grant execute on function public.complete_asaas_payment_release_with_review(uuid,text,smallint,text),public.claim_asaas_provider_transfer(uuid),public.mark_asaas_transfer_manual_review(uuid,text) to service_role;
