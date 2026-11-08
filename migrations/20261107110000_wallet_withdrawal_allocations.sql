-- Saques parciais reservam centavos, sem alterar ou duplicar lançamentos de origem.
create table public.provider_withdrawal_allocations (
 withdrawal_id uuid not null references public.provider_asaas_withdrawals(id),
 entry_id uuid not null references public.provider_wallet_entries(id),
 amount_cents integer not null check(amount_cents>0),
 primary key(withdrawal_id,entry_id)
);
alter table public.provider_withdrawal_allocations enable row level security;
revoke all on public.provider_withdrawal_allocations from public,anon,authenticated;
grant all on public.provider_withdrawal_allocations to service_role;
alter table public.provider_asaas_accounts add column sandbox boolean, add column financial_block_reason text, add column payout_pix_key text, add column payout_pix_type text check(payout_pix_type in ('CPF','CNPJ','EMAIL','PHONE','EVP'));
alter table public.provider_asaas_withdrawals add column payout_pix_key text, add column payout_pix_type text;

create function public.my_payment_customer_ready() returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from payment_customer_profiles where user_id=auth.uid()) or exists(select 1 from profiles where id=auth.uid() and asaas_customer_id is not null)
$$;
revoke all on function public.my_payment_customer_ready() from public,anon;
grant execute on function public.my_payment_customer_ready() to authenticated;

create function public.my_wallet_summary() returns table(held_cents bigint,available_cents bigint,processing_cents bigint,paid_cents bigint)
language sql stable security definer set search_path=public as $$
 select
 coalesce((select sum(gross_amount_cents-gross_amount_cents*10/100) from provider_wallet_entries where provider_id=auth.uid() and status='held'),0),
 greatest(0,coalesce((select sum(provider_net_cents) from provider_wallet_entries where provider_id=auth.uid() and status='available'),0)-
 coalesce((select sum(a.amount_cents) from provider_withdrawal_allocations a join provider_asaas_withdrawals w on w.id=a.withdrawal_id where w.provider_id=auth.uid() and w.status<>'failed'),0)),
 coalesce((select sum(amount_cents) from provider_asaas_withdrawals where provider_id=auth.uid() and status in ('requested','manual_review')),0),
 coalesce((select sum(amount_cents) from provider_asaas_withdrawals where provider_id=auth.uid() and status='paid'),0)
$$;
revoke all on function public.my_wallet_summary() from public,anon;
grant execute on function public.my_wallet_summary() to authenticated;

-- Apenas a Edge autenticada reserva o saldo. A função antiga expunha a chave cifrada ao cliente.
revoke all on function public.claim_asaas_withdrawal(integer) from authenticated;
create function public.reserve_pix_withdrawal(p_provider uuid,p_amount_cents integer,p_key text,p_key_type text,p_command_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare withdrawal_uuid uuid; remaining integer:=p_amount_cents; entry_row record; available bigint;
begin
 if p_amount_cents is null or p_amount_cents<500 or nullif(p_key,'') is null or p_key_type not in ('CPF','CNPJ','EMAIL','PHONE','EVP') then raise exception 'Dados de saque inválidos.'; end if;
 if p_command_id is null then raise exception 'Identificador obrigatório.'; end if;
 perform 1 from provider_asaas_accounts where provider_id=p_provider and status='verified' and financial_block_reason is null for update;
 if not found then raise exception 'Complete a verificação financeira.'; end if;
 if exists(select 1 from service_disputes d join service_requests r on r.id=d.request_id where r.selected_provider_id=p_provider and d.status='open' and exists(select 1 from service_provider_transfers t where t.request_id=r.id)) then raise exception 'Há saldo em disputa; aguarde a conciliação.'; end if;
 if exists(select 1 from provider_asaas_withdrawals where id=p_command_id) then raise exception 'Solicitação já registrada; consulte o resultado.'; end if;
 select coalesce(sum(e.provider_net_cents),0)-(select coalesce(sum(a.amount_cents),0) from provider_withdrawal_allocations a join provider_asaas_withdrawals w on w.id=a.withdrawal_id where w.provider_id=p_provider and w.status<>'failed') into available
 from provider_wallet_entries e where e.provider_id=p_provider and e.status='available';
 if p_amount_cents>available then raise exception 'Saldo disponível insuficiente.'; end if;
 insert into provider_asaas_withdrawals(id,provider_id,amount_cents,status,payout_pix_key,payout_pix_type) values(p_command_id,p_provider,p_amount_cents,'requested',p_key,p_key_type) returning id into withdrawal_uuid;
 for entry_row in select e.id,e.provider_net_cents-coalesce((select sum(a.amount_cents) from provider_withdrawal_allocations a join provider_asaas_withdrawals w on w.id=a.withdrawal_id where a.entry_id=e.id and w.status<>'failed'),0) as remaining
 from provider_wallet_entries e where e.provider_id=p_provider and e.status='available' order by e.created_at,e.id for update loop
  if entry_row.remaining>0 then
   insert into provider_withdrawal_allocations values(withdrawal_uuid,entry_row.id,least(remaining,entry_row.remaining));
   remaining:=remaining-least(remaining,entry_row.remaining);
  end if;
  exit when remaining=0;
 end loop;
 if remaining<>0 then raise exception 'Saldo em conciliação.'; end if;
 return withdrawal_uuid;
end $$;
revoke all on function public.reserve_pix_withdrawal(uuid,integer,text,text,uuid) from public,anon,authenticated;
grant execute on function public.reserve_pix_withdrawal(uuid,integer,text,text,uuid) to service_role;

-- Campo financeiro só pode ser escrito pelas RPCs e serviço, nunca pelo REST do cliente.
create function public.guard_dispatch_confirmation() returns trigger language plpgsql set search_path=public as $$
begin
 if current_user in ('authenticated','anon') then
  if tg_op='INSERT' then
   if new.provider_arrival_confirmed_at is not null or new.provider_snapshot is not null then raise exception 'Confirmação protegida.' using errcode='42501'; end if;
  elsif new.provider_arrival_confirmed_at is distinct from old.provider_arrival_confirmed_at then
   raise exception 'Use a confirmação de chegada.' using errcode='42501';
  end if;
 end if;
 return new;
end $$;
create trigger guard_dispatch_confirmation before insert or update on public.service_requests for each row execute function public.guard_dispatch_confirmation();

create function public.new_withdrawal_command() returns uuid language sql volatile as $$ select gen_random_uuid() $$;
revoke all on function public.new_withdrawal_command() from public,anon;
grant execute on function public.new_withdrawal_command() to authenticated;

-- Ambiente de contas existentes só é inferido quando todas as cobranças concordam.
update public.provider_asaas_accounts a set sandbox=c.sandbox
from (select provider_id,bool_and(asaas_sandbox) sandbox from public.service_payment_charges
 where asaas_payment_id is not null group by provider_id having count(distinct asaas_sandbox)=1) c
where c.provider_id=a.provider_id;

create table public.provider_payout_audit (
 id uuid primary key default gen_random_uuid(), provider_id uuid not null references profiles(id),
 key_type text not null, key_last4 text not null, created_at timestamptz not null default now()
);
alter table public.provider_payout_audit enable row level security;
revoke all on public.provider_payout_audit from public,anon,authenticated;
grant all on public.provider_payout_audit to service_role;
create function public.audit_payout_destination() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.payout_pix_key is distinct from old.payout_pix_key or new.payout_pix_type is distinct from old.payout_pix_type then
  insert into provider_payout_audit(provider_id,key_type,key_last4) values(new.provider_id,new.payout_pix_type,right(new.payout_pix_key,4));
 end if;
 return new;
end $$;
create trigger audit_payout_destination after update on public.provider_asaas_accounts for each row execute function public.audit_payout_destination();

-- Estorno/chargeback verificado: valores já transferidos exigem conciliação antes de sacar.
alter table public.service_payment_charges add column financial_status text, add column gateway_net_cents integer;
create function public.record_payment_reversal(p_charge_id uuid,p_state text) returns void
language plpgsql security definer set search_path=public as $$
declare c public.service_payment_charges;
begin
 select * into c from service_payment_charges where id=p_charge_id for update;
 if c.id is null then raise exception 'Cobrança inexistente.'; end if;
 if p_state not in ('REFUNDED','REFUND_REQUESTED','REFUND_IN_PROGRESS','CHARGEBACK_REQUESTED','CHARGEBACK_DISPUTE','AWAITING_CHARGEBACK_REVERSAL','DUNNING_REQUESTED') then raise exception 'Estado inválido.'; end if;
 update service_payment_charges set financial_status=p_state,settled_at=null where id=c.id;
 update provider_asaas_accounts set financial_block_reason='Pagamento em estorno ou contestação: '||c.id where provider_id=c.provider_id;
 if p_state='REFUNDED' then
  update service_payment_charges set status='cancelled' where id=c.id;
  update provider_wallet_entries set status='reversed' where charge_id=c.id and status='held';
 end if;
end $$;
revoke all on function public.record_payment_reversal(uuid,text) from public,anon,authenticated;
grant execute on function public.record_payment_reversal(uuid,text) to service_role;

-- Reserva de onboarding anterior ao POST evita criação concorrente de subcontas.
create table public.provider_onboarding_attempts (
 provider_id uuid primary key references profiles(id), sandbox boolean not null,
 created_at timestamptz not null default now()
);
alter table public.provider_onboarding_attempts enable row level security;
revoke all on public.provider_onboarding_attempts from public,anon,authenticated;
grant all on public.provider_onboarding_attempts to service_role;
