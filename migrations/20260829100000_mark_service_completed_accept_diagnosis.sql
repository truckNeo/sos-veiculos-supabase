-- Permitir que o prestador finalize o atendimento a partir da fase
-- 'diagnosis' (MVP sem orçamento final) além de 'service_released'.

create or replace function public.mark_service_completed(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_provider_id uuid := auth.uid();
begin
  update public.service_requests as request_row
  set workflow_phase = 'awaiting_driver_confirmation',
      service_completed_at = timezone('utc', now())
  where request_row.id = p_request_id
    and request_row.selected_provider_id = current_provider_id
    and request_row.workflow_phase in ('service_released', 'diagnosis');
  if not found then
    raise exception 'Este serviço não está disponível para conclusão.' using errcode = 'P0001';
  end if;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, current_provider_id, 'in_service',
    'Prestador informou que o serviço está pronto para conferência.');
end;
$$;
