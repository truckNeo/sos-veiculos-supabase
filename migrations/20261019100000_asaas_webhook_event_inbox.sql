-- Registro durável dos eventos recebidos do Asaas.
--
-- O webhook processava o evento e respondia 200 em qualquer caso: o erro da
-- RPC de confirmação era apenas logado, e os updates de transferência, saque e
-- conta nem eram checados. Como o Asaas trata 200 como entrega confirmada e
-- não reenvia, uma falha de banco deixava pagamento ou repasse sem
-- conciliação, sem fila e sem rastro além do log.
--
-- A correção é gravar o evento antes de processá-lo. Com ele persistido, o
-- webhook pode responder erro e deixar o Asaas reentregar: a reentrega é
-- barata e já é idempotente do lado do domínio (confirm_asaas_charge_payment
-- retorna sem efeito quando a cobrança já está paga). O que não podia
-- acontecer é o evento sumir, e isso deixa de ser possível.
--
-- Não há drenador próprio de propósito: a fila de reentrega é a do Asaas.
-- Esta tabela existe para idempotência, auditoria e diagnóstico do que falhou.

create table public.asaas_webhook_events (
  id uuid primary key default gen_random_uuid(),
  -- O id do evento quando o Asaas manda um; senão, evento + referência, que é
  -- o que distingue duas notificações diferentes do mesmo tipo.
  dedupe_key text not null unique,
  event_type text not null,
  payload jsonb not null,
  status text not null default 'pending' check (status in ('pending', 'processed', 'failed')),
  -- Conta as entregas, não as tentativas nossas: a segunda entrega do mesmo
  -- evento incrementa, e um número alto indica reentrega em laço.
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  processed_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

-- Consulta de diagnóstico: o que ficou para trás.
create index asaas_webhook_events_unprocessed_idx
  on public.asaas_webhook_events (created_at)
  where status <> 'processed';

create trigger asaas_webhook_events_set_updated_at
  before update on public.asaas_webhook_events
  for each row execute function public.set_updated_at();

alter table public.asaas_webhook_events enable row level security;
revoke all on public.asaas_webhook_events from anon, authenticated;

/**
 * Grava a entrega e informa se o evento já foi processado antes.
 *
 * A reentrega de um evento já processado não pode reexecutar o efeito
 * financeiro, então o chamador usa `already_processed` para parar cedo.
 */
create or replace function public.record_asaas_webhook_event(
  p_dedupe_key text,
  p_event_type text,
  p_payload jsonb
)
returns table (event_id uuid, already_processed boolean)
language plpgsql security definer set search_path = public as $$
begin
  return query
  insert into public.asaas_webhook_events (dedupe_key, event_type, payload, attempts)
  values (p_dedupe_key, p_event_type, p_payload, 1)
  on conflict (dedupe_key) do update
    set attempts = public.asaas_webhook_events.attempts + 1,
        -- O payload da reentrega é o estado mais recente do evento.
        payload = excluded.payload
  returning public.asaas_webhook_events.id,
            public.asaas_webhook_events.status = 'processed';
end;
$$;

/** Encerra o evento como concluído. */
create or replace function public.mark_asaas_webhook_event_processed(p_event_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.asaas_webhook_events
  set status = 'processed', processed_at = timezone('utc', now()), last_error = null
  where id = p_event_id;
end;
$$;

/**
 * Marca a falha e guarda o motivo. O evento fica consultável pelo índice de
 * não processados até que uma reentrega do Asaas o conclua.
 */
create or replace function public.mark_asaas_webhook_event_failed(
  p_event_id uuid,
  p_error text
)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.asaas_webhook_events
  set status = 'failed', last_error = left(coalesce(p_error, 'erro não informado'), 2000)
  where id = p_event_id;
end;
$$;
