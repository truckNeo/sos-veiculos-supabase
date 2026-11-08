-- Identidade do veículo fica vinculada à proposta, sem alterar chamados antigos.
alter table public.provider_vehicles add column color text check (color is null or char_length(trim(color)) between 2 and 40);
alter table public.provider_offers add column provider_snapshot jsonb;
alter table public.service_requests add column provider_snapshot jsonb,
  add column provider_arrival_confirmed_at timestamptz;

create function public.capture_offer_provider_identity() returns trigger
language plpgsql security definer set search_path = public as $$
declare vehicle public.provider_vehicles; identity jsonb; problem public.request_problem_type;
begin
  if tg_op = 'UPDATE' then
    new.provider_snapshot := old.provider_snapshot;
    return new;
  end if;
  select problem_type into problem from public.service_requests where id = new.request_id;
  select * into vehicle from public.provider_vehicles v
  where v.provider_id = new.provider_id and v.is_active
    and (nullif(current_setting('sos.offer_vehicle_id',true),'') is null or v.id=nullif(current_setting('sos.offer_vehicle_id',true),'')::uuid)
    and nullif(trim(v.color),'') is not null and nullif(trim(v.model),'') is not null and nullif(trim(v.plate),'') is not null and (problem <> 'towing' or v.vehicle_type = 'towing')
  order by v.created_at desc, v.id limit 1;
  if vehicle.id is null then raise exception 'Complete modelo, cor e placa do veículo operacional antes de enviar uma proposta.' using errcode = 'P0001'; end if;
  select jsonb_build_object('name', p.full_name, 'businessName', b.business_name,
    'vehicleId', vehicle.id, 'vehicleModel', vehicle.model, 'vehicleColor', vehicle.color,
    'vehiclePlate', vehicle.plate, 'vehicleType', vehicle.vehicle_type)
  into identity from public.profiles p join public.provider_profiles b on b.provider_id=p.id where p.id=new.provider_id;
  new.provider_snapshot := identity;
  return new;
end $$;
create trigger capture_offer_provider_identity before insert or update on public.provider_offers
for each row execute function public.capture_offer_provider_identity();

create function public.capture_selected_provider_identity() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.selected_provider_id is distinct from old.selected_provider_id then
    select o.provider_snapshot into new.provider_snapshot from public.provider_offers o
    where o.request_id=new.id and o.provider_id=new.selected_provider_id and o.status='accepted' order by o.created_at desc limit 1;
  else new.provider_snapshot := old.provider_snapshot;
  end if;
  return new;
end $$;
create trigger capture_selected_provider_identity before update on public.service_requests
for each row execute function public.capture_selected_provider_identity();

-- Fila persistente de repasse: a confirmação autoriza somente o deslocamento.
create or replace function public.confirm_provider_arrival(p_request_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r public.service_requests; gross integer; provider_fee integer;
begin
  select * into r from public.service_requests where id=p_request_id for update;
  if auth.uid() is null or r.requester_id is distinct from auth.uid() then raise exception 'Somente o motorista do atendimento pode confirmar a chegada.' using errcode='42501'; end if;
  if r.provider_arrival_confirmed_at is not null then return; end if;
  if r.status not in ('provider_on_site','in_service','completed') or r.workflow_phase='in_dispute' then raise exception 'A chegada só pode ser confirmada quando o prestador está no local.' using errcode='P0001'; end if;
  if not exists(select 1 from public.service_payment_charges c where c.request_id=r.id and c.kind='dispatch' and c.status='paid') then raise exception 'Pagamento do deslocamento ainda não confirmado.' using errcode='P0001'; end if;
  select coalesce(sum(e.gross_amount_cents),0) into gross from public.provider_wallet_entries e
    join public.service_payment_charges c on c.id=e.charge_id
    where e.request_id=r.id and e.provider_id=r.selected_provider_id and e.status='held' and c.kind='dispatch' and c.status='paid';
  if exists(select 1 from public.asaas_dispute_operations where request_id=r.id) then raise exception 'Pagamento em disputa; aguarde a conciliação.'; end if;
  if gross <= 0 then raise exception 'Saldo do deslocamento não disponível para liberação.' using errcode='P0001'; end if;
  provider_fee := (gross*10)/100;
  insert into public.service_provider_transfers(request_id,provider_id,gross_amount_cents,platform_fee_cents,provider_net_cents)
  values(r.id,r.selected_provider_id,gross,provider_fee,gross-provider_fee) on conflict(request_id) do nothing;
  update public.service_requests set provider_arrival_confirmed_at=now() where id=r.id;
  insert into public.service_request_events(request_id,actor_id,status,note)
  values(r.id,auth.uid(),r.status,'Motorista confirmou a chegada e autorizou a liberação do deslocamento.');
end $$;

-- Somente uma confirmação financeira verificada torna o saldo sacável.
create function public.complete_dispatch_transfer(p_transfer_id uuid,p_asaas_transfer_id text)
returns void language plpgsql security definer set search_path=public as $$
declare t public.service_provider_transfers; latest uuid; allocated integer;
begin
  select * into t from public.service_provider_transfers where id=p_transfer_id for update;
  if t.id is null then raise exception 'Repasse inexistente.'; end if;
  if t.status='completed' then return; end if;
  if nullif(trim(p_asaas_transfer_id),'') is null or t.asaas_transfer_id is distinct from p_asaas_transfer_id then raise exception 'Referência financeira divergente.'; end if;
  if not exists(select 1 from public.service_requests r where r.id=t.request_id and r.provider_arrival_confirmed_at is not null) then raise exception 'Chegada não confirmada.'; end if;
  if exists(select 1 from public.service_payment_charges where request_id=t.request_id and kind='dispatch' and (status<>'paid' or settled_at is null)) then raise exception 'Pagamento ainda não liquidado.'; end if;
  if t.gross_amount_cents <> (select coalesce(sum(gross_amount_cents),0) from public.provider_wallet_entries where request_id=t.request_id and provider_id=t.provider_id and status='held') then raise exception 'Saldo divergente; requer conciliação.'; end if;
  select e.id into latest from public.provider_wallet_entries e join public.service_payment_charges c on c.id=e.charge_id
    where e.request_id=t.request_id and e.status='held' and c.kind='dispatch' order by e.created_at desc,e.id limit 1;
  select coalesce(sum((e.gross_amount_cents*10)/100),0) into allocated from public.provider_wallet_entries e
    join public.service_payment_charges c on c.id=e.charge_id where e.request_id=t.request_id and e.status='held' and c.kind='dispatch' and e.id<>latest;
  update public.provider_wallet_entries e set status='available',
    platform_fee_cents=case when e.id=latest then t.platform_fee_cents-allocated else (e.gross_amount_cents*10)/100 end,
    provider_net_cents=e.gross_amount_cents-(case when e.id=latest then t.platform_fee_cents-allocated else (e.gross_amount_cents*10)/100 end),released_at=now()
    where e.request_id=t.request_id and e.status='held' and exists(select 1 from public.service_payment_charges c where c.id=e.charge_id and c.kind='dispatch');
  update public.service_provider_transfers set status='completed',completed_at=now(),failure_reason=null where id=t.id;
  update public.service_requests set payment_released_at=now() where id=t.request_id;
end $$;
revoke all on function public.complete_dispatch_transfer(uuid,text) from public,anon,authenticated;
grant execute on function public.complete_dispatch_transfer(uuid,text) to service_role;

-- Conclusão/avaliação não executa transferência nem modifica saldo.
create or replace function public.complete_service_with_review(p_request_id uuid,p_rating integer,p_comment text default null)
returns void language plpgsql security definer set search_path=public as $$
declare r public.service_requests;
begin
  if p_rating is null or p_rating not between 1 and 5 or char_length(coalesce(p_comment,''))>2000 then raise exception 'Informe uma avaliação de 1 a 5 estrelas.' using errcode='22023'; end if;
  select * into r from public.service_requests where id=p_request_id for update;
  if auth.uid() is null or r.requester_id is distinct from auth.uid() then raise exception 'Atendimento não autorizado.' using errcode='42501'; end if;
  if r.status='completed' and exists(select 1 from public.reviews where request_id=r.id and reviewer_id=auth.uid()) then return; end if;
  if r.workflow_phase not in ('awaiting_driver_confirmation','release_processing') then raise exception 'Aguarde a conclusão do serviço.' using errcode='P0001'; end if;
  insert into public.reviews(request_id,provider_id,reviewer_id,rating,comment)
    values(r.id,r.selected_provider_id,auth.uid(),p_rating,nullif(trim(p_comment),'')) on conflict do nothing;
  update public.service_requests set workflow_phase='completed',status='completed',driver_confirmed_at=now(),closed_at=now() where id=r.id;
  update public.provider_profiles p set average_rating=(select coalesce(avg(v.rating),0) from public.reviews v where v.provider_id=p.provider_id and v.reviewer_id<>p.provider_id),
    completed_services=(select count(*) from public.service_requests s where s.selected_provider_id=p.provider_id and s.status='completed') where p.provider_id=r.selected_provider_id;
end $$;
revoke all on function public.complete_service_with_review(uuid,integer,text) from public,anon;
grant execute on function public.complete_service_with_review(uuid,integer,text) to authenticated;

-- Dados financeiros sensíveis nunca são consultáveis pelo cliente.
create table public.payment_customer_profiles (
 user_id uuid primary key references public.profiles(id) on delete cascade,
 document_ciphertext text not null, document_iv text not null,
 customer_id text, sandbox boolean, provisioning_at timestamptz,
 updated_at timestamptz not null default now()
);
alter table public.payment_customer_profiles enable row level security;
revoke all on public.payment_customer_profiles from public,anon,authenticated;
grant all on public.payment_customer_profiles to service_role;

alter table public.service_payment_charges add column billing_method text not null default 'PIX' check (billing_method in ('PIX','CREDIT_CARD','DEBIT_CARD')),
 add column settled_at timestamptz;
update public.service_payment_charges set settled_at=now() where status='paid';

create function public.mark_service_charge_checkout(p_charge_id uuid,p_payment_id text,p_method text,p_url text,p_sandbox boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
 if p_method not in ('CREDIT_CARD','DEBIT_CARD') or nullif(p_payment_id,'') is null or nullif(p_url,'') is null then raise exception 'Checkout inválido.'; end if;
 update public.service_payment_charges c set status='awaiting_payment',asaas_payment_id=p_payment_id,
   billing_method=p_method,pix_ticket_url=p_url,asaas_sandbox=p_sandbox
 where c.id=p_charge_id and c.status='pending';
 if not found then raise exception 'Cobrança não disponível.'; end if;
end $$;
revoke all on function public.mark_service_charge_checkout(uuid,text,text,text,boolean) from public,anon,authenticated;
grant execute on function public.mark_service_charge_checkout(uuid,text,text,text,boolean) to service_role;

-- Os caminhos legados não podem autorizar repasse sem chegada.
revoke all on function public.begin_asaas_payment_release(uuid) from public,anon,authenticated;
-- Requisições antigas preservam a autorização explícita já registrada pelo cliente.
update public.service_requests r set provider_arrival_confirmed_at=e.confirmed_at
from (select request_id,min(created_at) confirmed_at from public.service_request_events
 where note='Motorista confirmou a chegada do prestador.' group by request_id) e
where r.id=e.request_id;
-- Não inventa autorização nem reenvia os repasses antigos sem referência.

create function public.submit_provider_dispatch_offer_with_vehicle(p_request_id uuid,p_travel_fee_cents integer,p_estimated_arrival_minutes integer,p_vehicle_id uuid,p_notes text default null)
returns table(id uuid,request_id uuid,provider_id uuid,status public.offer_status,created_at timestamptz)
language plpgsql security definer set search_path=public as $$
begin
 if p_vehicle_id is null or not exists(select 1 from provider_vehicles where id=p_vehicle_id and provider_id=auth.uid() and is_active and color is not null) then raise exception 'Selecione um veículo completo do seu cadastro.'; end if;
 perform set_config('sos.offer_vehicle_id',p_vehicle_id::text,true);
 return query select * from public.submit_provider_dispatch_offer(p_request_id,p_travel_fee_cents,p_estimated_arrival_minutes,p_notes);
 perform set_config('sos.offer_vehicle_id','',true);
end $$;
revoke all on function public.submit_provider_dispatch_offer_with_vehicle(uuid,integer,integer,uuid,text) from public,anon;
grant execute on function public.submit_provider_dispatch_offer_with_vehicle(uuid,integer,integer,uuid,text) to authenticated;

create or replace function public.claim_asaas_provider_transfer(p_transfer_id uuid)
returns table (transfer_id uuid, provider_net_cents integer, wallet_id text)
language plpgsql security definer set search_path=public as $$
declare t public.service_provider_transfers; r public.service_requests; target_wallet text;
begin
 select * into r from service_requests where id=(select request_id from service_provider_transfers where id=p_transfer_id) for update;
 select * into t from service_provider_transfers where id=p_transfer_id for update;
 if t.id is null or t.status<>'pending' then return; end if;
 if r.provider_arrival_confirmed_at is null or r.workflow_phase='in_dispute' then raise exception 'Confirmação pendente ou pagamento em disputa.'; end if;
 if exists(select 1 from service_payment_charges where request_id=r.id and kind='dispatch' and (status<>'paid' or settled_at is null)) then raise exception 'Aguardando liquidação.'; end if;
 select a.wallet_id into target_wallet from provider_asaas_accounts a where a.provider_id=t.provider_id and a.status='verified';
 if target_wallet is null then raise exception 'Conta não verificada.'; end if;
 update service_provider_transfers set status='processing',initiated_at=now() where id=t.id;
 return query select t.id,t.provider_net_cents,target_wallet;
end $$;
