-- A conclusão do trajeto de guincho segue a mesma regra de chegada
-- confirmada que os demais atendimentos.
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
  arrival_confirmed_at timestamptz;
begin
  select request_row.problem_type, request_row.workflow_phase,
    request_row.status, request_row.destination_label,
    request_row.provider_arrival_confirmed_at
  into target_problem, target_phase, target_status, target_destination,
    arrival_confirmed_at
  from public.service_requests as request_row
  where request_row.id = p_request_id
    and request_row.selected_provider_id = provider
  for update;

  if provider is null
     or target_problem is null
     or target_problem <> 'towing'
     or target_phase <> 'service_released'
     or target_status not in ('provider_on_site', 'in_service') then
    raise exception 'O trajeto de guincho ainda não está pronto para finalização.'
      using errcode = 'P0001';
  end if;

  if arrival_confirmed_at is null then
    raise exception 'Aguarde a confirmação de chegada para concluir o atendimento.'
      using errcode = 'P0001';
  end if;

  if target_destination is null then
    raise exception 'O motorista ainda não informou o destino do guincho.'
      using errcode = 'P0001';
  end if;

  update public.service_requests as request_row
  set workflow_phase = 'awaiting_driver_confirmation',
      service_completed_at = timezone('utc', now())
  where request_row.id = p_request_id;

  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, provider, 'in_service',
    'Prestador finalizou o trajeto no destino informado.');
end;
$$;
