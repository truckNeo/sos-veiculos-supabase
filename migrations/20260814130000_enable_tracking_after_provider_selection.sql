-- O deslocamento do prestador selecionado deve ser acompanhável pelo motorista
-- sem depender de uma segunda ação manual depois da seleção da proposta.
-- O rastreamento continua limitado ao atendimento e os pontos permanecem
-- efêmeros conforme a migration de tracking.
create or replace function public.enable_service_request_tracking_on_selection()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.selected_provider_id is not null
    and (old.selected_provider_id is distinct from new.selected_provider_id)
    and new.workflow_phase not in ('completed', 'cancelled') then
    new.tracking_enabled := true;
    new.tracking_consent_at := coalesce(new.tracking_consent_at, timezone('utc', now()));
    new.tracking_revoked_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists service_requests_enable_tracking_on_selection on public.service_requests;
create trigger service_requests_enable_tracking_on_selection
  before update of selected_provider_id on public.service_requests
  for each row execute function public.enable_service_request_tracking_on_selection();

-- Mantém chamados já selecionados compatíveis com o fluxo novo.
update public.service_requests
set tracking_enabled = true,
    tracking_consent_at = coalesce(tracking_consent_at, timezone('utc', now())),
    tracking_revoked_at = null
where selected_provider_id is not null
  and workflow_phase not in ('completed', 'cancelled')
  and not tracking_enabled;
