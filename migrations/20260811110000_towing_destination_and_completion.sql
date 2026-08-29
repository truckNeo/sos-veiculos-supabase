-- Destino operacional para guincho e conclusão explícita do transporte.
alter table public.service_requests
  add column destination_label text,
  add column destination_set_at timestamptz;

create or replace function public.set_service_request_destination(
  p_request_id uuid,
  p_destination_label text
)
returns table (request_id uuid, destination_label text, destination_set_at timestamptz)
language plpgsql security definer set search_path = public
as $$
declare
  requester uuid := auth.uid();
  target_problem public.request_problem_type;
  target_phase public.service_workflow_phase;
  saved_at timestamptz := timezone('utc', now());
  normalized_label text := nullif(trim(coalesce(p_destination_label, '')), '');
begin
  if requester is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;
  if normalized_label is null or char_length(normalized_label) < 5 or char_length(normalized_label) > 500 then
    raise exception 'Informe um destino entre 5 e 500 caracteres.' using errcode = '22023';
  end if;
  select request_row.problem_type, request_row.workflow_phase
  into target_problem, target_phase
  from public.service_requests as request_row
  where request_row.id = p_request_id and request_row.requester_id = requester
  for update;
  if target_problem is null then
    raise exception 'Chamado não encontrado ou sem permissão.' using errcode = '42501';
  end if;
  if target_problem <> 'towing' then
    raise exception 'Destino só pode ser definido para chamados de guincho.' using errcode = 'P0001';
  end if;
  if target_phase in ('completed', 'cancelled', 'awaiting_driver_confirmation') then
    raise exception 'O destino não pode mais ser alterado nesta etapa.' using errcode = 'P0001';
  end if;

  update public.service_requests as request_row
  set destination_label = normalized_label, destination_set_at = saved_at
  where request_row.id = p_request_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, requester, (select status from public.service_requests where id = p_request_id), 'Motorista definiu o destino do guincho: ' || normalized_label);
  return query select p_request_id, normalized_label, saved_at;
end;
$$;

create or replace function public.mark_towing_transport_completed(p_request_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  provider uuid := auth.uid();
  target_problem public.request_problem_type;
  target_phase public.service_workflow_phase;
  target_status public.service_request_status;
  target_destination text;
begin
  select request_row.problem_type, request_row.workflow_phase, request_row.status, request_row.destination_label
  into target_problem, target_phase, target_status, target_destination
  from public.service_requests as request_row
  where request_row.id = p_request_id and request_row.selected_provider_id = provider
  for update;
  if provider is null or target_problem is null or target_problem <> 'towing' or target_phase <> 'service_released' or target_status <> 'in_service' then
    raise exception 'O trajeto de guincho ainda não está pronto para finalização.' using errcode = 'P0001';
  end if;
  if target_destination is null then
    raise exception 'O motorista ainda não informou o destino do guincho.' using errcode = 'P0001';
  end if;

  update public.service_requests as request_row
  set workflow_phase = 'awaiting_driver_confirmation', service_completed_at = timezone('utc', now())
  where request_row.id = p_request_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, provider, 'in_service', 'Prestador finalizou o trajeto no destino informado.');
end;
$$;

revoke all on function public.set_service_request_destination(uuid, text) from public;
revoke all on function public.mark_towing_transport_completed(uuid) from public;
grant execute on function public.set_service_request_destination(uuid, text) to authenticated;
grant execute on function public.mark_towing_transport_completed(uuid) to authenticated;
