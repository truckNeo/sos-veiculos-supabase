-- Disputa aberta pelos dois lados e registro da confirmação de chegada.
--
-- 1) open_service_dispute só aceitava o solicitante, e só na fase
--    awaiting_driver_confirmation. Por isso dois botões do app sempre
--    falhavam: "ABRIR DISPUTA" do prestador e "PRESTADOR NÃO ESTÁ NO LOCAL"
--    do motorista, que é disparado na chegada (fase diagnosis ou
--    service_released).
--
-- 2) A confirmação de chegada do motorista só exibia um alerta no app, sem
--    deixar rastro. Passa a gravar um evento, para relatório e auditoria.
--
-- decide_service_dispute não exige fase de entrada: ele apenas requer disputa
-- aberta e conclui ou cancela o atendimento. Disputa aberta na chegada
-- continua decidível pelo console.

create or replace function public.open_service_dispute(p_request_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  request_row public.service_requests;
  actor_role text;
begin
  if nullif(trim(p_reason), '') is null or char_length(trim(p_reason)) < 10 then
    raise exception 'Descreva o problema com ao menos 10 caracteres.' using errcode = '22023';
  end if;

  select * into request_row from public.service_requests where id = p_request_id for update;
  if request_row.id is null then
    raise exception 'Atendimento não encontrado.' using errcode = 'P0001';
  end if;

  if request_row.requester_id = actor then
    actor_role := 'driver';
  elsif request_row.selected_provider_id = actor then
    actor_role := 'provider';
  else
    raise exception 'Apenas os participantes do atendimento podem abrir disputa.' using errcode = '42501';
  end if;

  -- A duplicidade é verificada antes da fase: depois da primeira disputa o
  -- atendimento está em in_dispute, e a checagem de fase daria uma mensagem
  -- enganosa para quem só está tentando abrir de novo.
  if exists (select 1 from public.service_disputes where request_id = p_request_id) then
    raise exception 'Este atendimento já possui uma disputa.' using errcode = 'P0001';
  end if;

  -- Fases em que já existe serviço em andamento ou aguardando conferência.
  if request_row.workflow_phase not in ('diagnosis', 'service_released', 'awaiting_driver_confirmation') then
    raise exception 'Este atendimento não pode abrir disputa neste momento.' using errcode = 'P0001';
  end if;

  update public.service_requests
  set workflow_phase = 'in_dispute', status = 'disputed'
  where id = p_request_id;

  insert into public.service_disputes (request_id, opened_by, reason)
  values (p_request_id, actor, trim(p_reason));

  insert into public.service_request_events (request_id, actor_id, status, note)
  values (
    p_request_id,
    actor,
    'disputed',
    case actor_role
      when 'provider' then 'Prestador abriu uma disputa.'
      else 'Motorista abriu uma disputa.'
    end
  );
end;
$$;

/**
 * Registra a confirmação do motorista de que o prestador chegou ao local.
 * Não altera a fase do atendimento: serve como trilha de auditoria.
 */
create or replace function public.confirm_provider_arrival(p_request_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  driver uuid := auth.uid();
  request_row public.service_requests;
begin
  select * into request_row from public.service_requests where id = p_request_id;
  if request_row.id is null or request_row.requester_id <> driver then
    raise exception 'Apenas o motorista do atendimento pode confirmar a chegada.' using errcode = '42501';
  end if;

  if request_row.status <> 'provider_on_site' then
    raise exception 'A chegada só pode ser confirmada quando o prestador está no local.' using errcode = 'P0001';
  end if;

  -- Idempotente: reconfirmar não duplica o evento.
  if exists (
    select 1 from public.service_request_events
    where request_id = p_request_id
      and actor_id = driver
      and note = 'Motorista confirmou a chegada do prestador.'
  ) then
    return;
  end if;

  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, driver, 'provider_on_site', 'Motorista confirmou a chegada do prestador.');
end;
$$;

revoke all on function public.confirm_provider_arrival(uuid) from public;
grant execute on function public.confirm_provider_arrival(uuid) to authenticated;
