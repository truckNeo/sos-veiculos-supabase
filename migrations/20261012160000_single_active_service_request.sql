-- Impede abrir um segundo chamado com um atendimento ainda em andamento.
--
-- Nem a tela nem a função verificavam isso: dava para abrir vários chamados
-- ao mesmo tempo, cada um recebendo propostas e cobranças, sem o motorista
-- perceber que tinha mais de um aberto.

create or replace function public.open_service_request(
  p_vehicle_id uuid,
  p_problem_type public.request_problem_type,
  p_description text,
  p_latitude double precision,
  p_longitude double precision,
  p_address_label text default null
)
returns table (
  id uuid,
  vehicle_id uuid,
  status public.service_request_status,
  opened_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  current_requester_id uuid := auth.uid();
  target_vehicle_status public.vehicle_status;
  created_request public.service_requests;
  normalized_description text := trim(coalesce(p_description, ''));
  normalized_address text := nullif(trim(coalesce(p_address_label, '')), '');
begin
  if current_requester_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.profiles profile
    where profile.id = current_requester_id and profile.role = 'driver'
  ) then
    raise exception 'Somente motoristas podem abrir chamados.' using errcode = '42501';
  end if;

  if char_length(normalized_description) not between 5 and 2000 then
    raise exception 'Descreva o problema entre 5 e 2000 caracteres.' using errcode = '22023';
  end if;

  if p_latitude is null or p_latitude not between -90 and 90
    or p_longitude is null or p_longitude not between -180 and 180 then
    raise exception 'Informe uma localização válida para o chamado.' using errcode = '22023';
  end if;

  if normalized_address is not null and char_length(normalized_address) > 500 then
    raise exception 'O endereço pode ter no máximo 500 caracteres.' using errcode = '22023';
  end if;

  -- Um chamado ativo por vez: nem a tela nem a função impediam abrir um
  -- segundo, e o motorista ficava com dois atendimentos concorrendo pelo
  -- mesmo veículo, cada um com propostas e cobranças próprias.
  if exists (
    select 1 from public.service_requests active
    where active.requester_id = current_requester_id
      and active.workflow_phase not in ('completed', 'cancelled')
  ) then
    raise exception 'Você já tem um atendimento em andamento. Conclua ou cancele antes de abrir outro.'
      using errcode = 'P0001';
  end if;

  select vehicle.status
  into target_vehicle_status
  from public.vehicles vehicle
  where vehicle.id = p_vehicle_id
    and public.can_access_vehicle(vehicle.id)
  for update;

  if target_vehicle_status is null then
    raise exception 'Veículo não encontrado ou sem permissão de uso.' using errcode = 'P0001';
  end if;

  if target_vehicle_status <> 'active' then
    raise exception 'Selecione um veículo ativo antes de abrir um chamado.' using errcode = 'P0001';
  end if;

  insert into public.service_requests (
    requester_id,
    vehicle_id,
    problem_type,
    description,
    latitude,
    longitude,
    address_label,
    status
  ) values (
    current_requester_id,
    p_vehicle_id,
    p_problem_type,
    normalized_description,
    p_latitude,
    p_longitude,
    normalized_address,
    'open'
  ) returning * into created_request;

  insert into public.service_request_events (request_id, actor_id, status, note)
  values (created_request.id, current_requester_id, 'open', 'Chamado aberto pelo motorista.');

  return query
  select created_request.id, created_request.vehicle_id,
    created_request.status, created_request.opened_at;
end;
$$;

