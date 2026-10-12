-- Push ao motorista nos eventos do atendimento.
--
-- Hoje o motorista só descobre que recebeu proposta, que o prestador saiu,
-- chegou ou terminou se estiver com o app aberto: o Realtime cobre isso, mas
-- não existe push nenhum para esses eventos. Com o app fechado, o fluxo trava
-- esperando uma ação que o motorista não sabe que precisa fazer.
--
-- O padrão é o mesmo já usado no dispatch: gatilho enfileira, Edge Function
-- drena e envia, scheduler do backend chama a função. Enfileirar no banco
-- evita depender de quem está com o app aberto e dá retry natural.

create table public.driver_event_push_outbox (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in (
    'offer_received',
    'provider_en_route',
    'provider_on_site',
    'awaiting_driver_confirmation',
    'dispute_opened',
    'service_closed'
  )),
  -- Distingue eventos repetíveis, como uma proposta por prestador.
  ref_id uuid,
  status text not null default 'queued' check (status in ('queued', 'sent', 'failed')),
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  sent_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

-- NULL não colide com NULL em unique, então a chave usa um valor fixo no
-- lugar do ref_id ausente: sem isso, uma transição repetida duplicaria push.
create unique index driver_event_push_outbox_unique_event
  on public.driver_event_push_outbox (
    request_id, kind, coalesce(ref_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );
create index driver_event_push_outbox_queued_idx
  on public.driver_event_push_outbox (created_at)
  where status = 'queued';

create trigger driver_event_push_outbox_set_updated_at
  before update on public.driver_event_push_outbox
  for each row execute function public.set_updated_at();

alter table public.driver_event_push_outbox enable row level security;
revoke all on public.driver_event_push_outbox from anon, authenticated;

/**
 * Enfileira o evento. Silencioso em caso de duplicata: o gatilho não pode
 * derrubar a transação que originou o evento.
 */
create or replace function public.enqueue_driver_event_push(
  p_request_id uuid,
  p_recipient_id uuid,
  p_kind text,
  p_ref_id uuid default null
)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_recipient_id is null then return; end if;
  insert into public.driver_event_push_outbox (request_id, recipient_id, kind, ref_id)
  values (p_request_id, p_recipient_id, p_kind, p_ref_id)
  on conflict do nothing;
end;
$$;

/** Proposta recebida: avisa o motorista dono do chamado. */
create or replace function public.enqueue_offer_received_push()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  driver uuid;
begin
  select requester_id into driver from public.service_requests where id = new.request_id;
  perform public.enqueue_driver_event_push(new.request_id, driver, 'offer_received', new.id);
  return new;
end;
$$;

create trigger provider_offers_enqueue_driver_push
  after insert on public.provider_offers
  for each row execute function public.enqueue_offer_received_push();

/** Mudanças de andamento que o motorista precisa saber mesmo com o app fechado. */
create or replace function public.enqueue_service_request_driver_push()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'provider_en_route' then
      perform public.enqueue_driver_event_push(new.id, new.requester_id, 'provider_en_route');
    elsif new.status = 'provider_on_site' then
      perform public.enqueue_driver_event_push(new.id, new.requester_id, 'provider_on_site');
    elsif new.status in ('completed', 'cancelled') then
      perform public.enqueue_driver_event_push(new.id, new.requester_id, 'service_closed');
    end if;
  end if;

  if new.workflow_phase is distinct from old.workflow_phase then
    if new.workflow_phase = 'awaiting_driver_confirmation' then
      perform public.enqueue_driver_event_push(
        new.id, new.requester_id, 'awaiting_driver_confirmation'
      );
    elsif new.workflow_phase = 'in_dispute' then
      -- Os dois lados acompanham a disputa.
      perform public.enqueue_driver_event_push(new.id, new.requester_id, 'dispute_opened');
      perform public.enqueue_driver_event_push(
        new.id, new.selected_provider_id, 'dispute_opened', new.selected_provider_id
      );
    end if;
  end if;

  return new;
end;
$$;

create trigger service_requests_enqueue_driver_push
  after update on public.service_requests
  for each row execute function public.enqueue_service_request_driver_push();

revoke all on function public.enqueue_driver_event_push(uuid, uuid, text, uuid) from public;
