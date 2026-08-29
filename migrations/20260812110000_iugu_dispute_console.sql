-- Console operacional de disputas: acesso explícito por usuário autorizado.
create table public.service_dispute_admins (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  granted_at timestamptz not null default timezone('utc', now()),
  granted_by uuid references public.profiles(id) on delete set null
);
alter table public.service_dispute_admins enable row level security;
revoke all on public.service_dispute_admins from anon, authenticated;

create or replace function public.is_service_dispute_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.service_dispute_admins where user_id = auth.uid()); $$;

create or replace function public.list_open_service_disputes()
returns table (
  dispute_id uuid, request_id uuid, reason text, dispute_status public.service_dispute_status,
  created_at timestamptz, requester_name text, provider_name text,
  gross_amount_cents integer, transfer_status public.iugu_transfer_status
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.is_service_dispute_admin() then raise exception 'Acesso restrito ao console de disputas.' using errcode = '42501'; end if;
  return query
  select dispute.id, dispute.request_id, dispute.reason, dispute.status, dispute.created_at,
    requester.full_name, provider.business_name, transfer.gross_amount_cents, transfer.status
  from public.service_disputes dispute
  join public.service_requests request_row on request_row.id = dispute.request_id
  join public.profiles requester on requester.id = request_row.requester_id
  join public.provider_profiles provider on provider.provider_id = request_row.selected_provider_id
  left join public.service_provider_transfers transfer on transfer.request_id = dispute.request_id
  where dispute.status = 'open'
  order by dispute.created_at asc;
end;
$$;

create or replace function public.decide_service_dispute(
  p_request_id uuid,
  p_decision public.service_dispute_status,
  p_decision_note text
)
returns void language plpgsql security definer set search_path = public
as $$
declare admin uuid := auth.uid(); dispute_row public.service_disputes; request_status public.service_request_status; target_provider uuid;
begin
  if not public.is_service_dispute_admin() then raise exception 'Acesso restrito ao console de disputas.' using errcode = '42501'; end if;
  if p_decision not in ('provider_released', 'driver_refunded', 'cancelled') then raise exception 'Decisão inválida.' using errcode = '22023'; end if;
  if p_decision_note is null or char_length(trim(p_decision_note)) < 10 or char_length(trim(p_decision_note)) > 2000 then raise exception 'A decisão deve conter uma justificativa entre 10 e 2000 caracteres.' using errcode = '22023'; end if;
  select * into dispute_row from public.service_disputes where request_id = p_request_id and status = 'open' for update;
  if dispute_row.id is null then raise exception 'Disputa aberta não encontrada.' using errcode = 'P0001'; end if;
  select selected_provider_id, status into target_provider, request_status from public.service_requests where id = p_request_id for update;
  update public.service_disputes set status = p_decision, decision_note = trim(p_decision_note), decided_by = admin, decided_at = timezone('utc', now()) where id = dispute_row.id;
  if p_decision = 'provider_released' then
    update public.provider_wallet_entries set status = 'available', released_at = timezone('utc', now()) where request_id = p_request_id and provider_id = target_provider and status = 'held';
    update public.service_requests set workflow_phase = 'completed', status = 'completed', closed_at = timezone('utc', now()), payment_released_at = timezone('utc', now()) where id = p_request_id;
  elsif p_decision = 'driver_refunded' then
    update public.provider_wallet_entries set status = 'reversed', released_at = null where request_id = p_request_id and provider_id = target_provider and status = 'held';
    update public.service_requests set workflow_phase = 'completed', status = 'completed', closed_at = timezone('utc', now()) where id = p_request_id;
  else
    update public.service_requests set workflow_phase = 'cancelled', status = 'cancelled', closed_at = timezone('utc', now()) where id = p_request_id;
  end if;
  insert into public.service_request_events(request_id, actor_id, status, note) values (p_request_id, admin, case when p_decision = 'cancelled' then 'cancelled'::public.service_request_status else 'completed'::public.service_request_status end, 'Disputa decidida pelo console: ' || p_decision || '. ' || trim(p_decision_note));
end;
$$;

revoke all on function public.is_service_dispute_admin(), public.list_open_service_disputes(), public.decide_service_dispute(uuid, public.service_dispute_status, text) from public;
grant execute on function public.is_service_dispute_admin(), public.list_open_service_disputes(), public.decide_service_dispute(uuid, public.service_dispute_status, text) to authenticated;
