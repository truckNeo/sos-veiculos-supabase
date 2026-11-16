-- Fase 1 do gerenciamento de agendamentos: três tipos de atendimento (oficina,
-- mecânico no local e leva e traz) com as etapas de logística de cada um.
-- A taxa de deslocamento é informada ao confirmar, mas a cobrança pelo app entra
-- numa próxima etapa; até lá ela é só registrada.
--
-- Estado: `status` continua sendo o estado de alto nível; `stage` é a etapa de
-- logística dentro dele (a caminho, chegou, na oficina, entrega...).
alter table public.service_appointments drop constraint service_appointments_service_mode_check;
alter table public.service_appointments drop constraint appointment_onsite_location;
alter table public.service_appointments
  add constraint service_appointments_service_mode_check check (service_mode in ('workshop','onsite','pickup')),
  add constraint appointment_onsite_location check (service_mode = 'workshop' or (
    location_latitude between -90 and 90 and location_longitude between -180 and 180
    and length(trim(coalesce(location_label, ''))) between 3 and 500)),
  add column travel_fee_cents integer check (travel_fee_cents is null or travel_fee_cents > 0),
  add column stage text check (stage is null or stage in ('heading','arrived','in_workshop','delivery_requested',
    'delivery_scheduled','heading_delivery','arrived_delivery')),
  add column eta_minutes integer check (eta_minutes is null or eta_minutes between 5 and 240),
  add column delivery_at timestamptz,
  add column delivery_proposed_at timestamptz,
  add column delay_minutes integer,
  add column delay_status text check (delay_status is null or delay_status in ('pending','accepted')),
  add column delay_arrival_at timestamptz;

-- Atendimento com deslocamento só se confirma com a taxa informada.
create function public.require_travel_fee() returns trigger language plpgsql as $$
begin
  if old.status = 'requested' and new.status = 'confirmed' and new.service_mode in ('onsite','pickup') and new.travel_fee_cents is null then
    raise exception 'Informe a taxa de deslocamento para confirmar.' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger appointment_require_travel_fee before update of status on public.service_appointments
  for each row execute function public.require_travel_fee();

create or replace function public.create_service_appointment_v2(p_vehicle_id uuid, p_provider_id uuid, p_starts_at timestamptz,
  p_duration_minutes integer, p_description text, p_plan_id uuid default null,
  p_service_mode text default 'workshop', p_latitude double precision default null,
  p_longitude double precision default null, p_address_label text default null)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare result uuid; dur integer;
begin
  if not exists(select 1 from public.favorite_mechanic_invites where driver_id = auth.uid() and provider_id = p_provider_id and status = 'accepted') then
    raise exception 'Você só pode agendar com mecânicos favoritos que aceitaram seu convite.' using errcode = 'P0001';
  end if;
  if p_service_mode is null or p_service_mode not in ('workshop','onsite','pickup') then
    raise exception 'Escolha se vai levar o veículo, se o mecânico vai até você ou se ele busca e entrega o veículo.' using errcode = 'P0001';
  end if;
  if p_service_mode in ('onsite','pickup') then
    if p_latitude is null or not (p_latitude between -90 and 90) or p_longitude is null or not (p_longitude between -180 and 180)
      or length(trim(coalesce(p_address_label, ''))) not between 3 and 500 then
      raise exception 'Informe o local onde o mecânico deve ir.' using errcode = 'P0001';
    end if;
    if not exists(select 1 from public.provider_profiles p join public.provider_locations l on l.provider_id = p.provider_id
      where p.provider_id = p_provider_id
        and extensions.st_dwithin(extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326)::extensions.geography,
          l.location, p.service_radius_km * 1000)) then
      raise exception 'O local informado está fora da área de atendimento do prestador.' using errcode = 'P0001';
    end if;
  end if;
  if p_plan_id is not null and not exists(select 1 from public.vehicle_maintenance_plans where id = p_plan_id and vehicle_id = p_vehicle_id and public.can_manage_vehicle(vehicle_id)) then
    raise exception 'Plano indisponível.' using errcode = '42501';
  end if;
  select appointment_duration_minutes into dur from public.provider_profiles where provider_id = p_provider_id;
  result = public.create_service_appointment(p_vehicle_id, p_provider_id, p_starts_at, coalesce(dur, p_duration_minutes), p_description);
  update public.service_appointments set maintenance_plan_id = p_plan_id, service_mode = p_service_mode,
    location_latitude = case when p_service_mode in ('onsite','pickup') then p_latitude end,
    location_longitude = case when p_service_mode in ('onsite','pickup') then p_longitude end,
    location_label = case when p_service_mode in ('onsite','pickup') then trim(p_address_label) end,
    vehicle_odometer = (select r.odometer from public.vehicles v join public.vehicle_odometer_readings r on r.id = v.odometer_reading_id where v.id = p_vehicle_id)
  where id = result;
  return result;
end $$;

create function public.confirm_service_appointment(p_id uuid, p_travel_fee_cents integer default null) returns void
language plpgsql security definer set search_path = public as $$
declare a public.service_appointments;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is distinct from a.provider_id then raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if a.service_mode in ('onsite','pickup') then
    if p_travel_fee_cents is null or p_travel_fee_cents not between 100 and 1000000 then
      raise exception 'Informe a taxa de deslocamento (de R$ 1,00 a R$ 10.000,00).' using errcode = 'P0001'; end if;
    update public.service_appointments set travel_fee_cents = p_travel_fee_cents where id = a.id;
  end if;
  perform public.respond_service_appointment(p_id, 'confirmed');
end $$;
revoke all on function public.confirm_service_appointment(uuid, integer) from public, anon;
grant execute on function public.confirm_service_appointment(uuid, integer) to authenticated;

-- Aviso interno; a chave deduplica repetições do mesmo evento.
create function public.notify_appointment(p_user uuid, p_appointment uuid, p_key text, p_title text, p_body text) returns void
language sql security definer set search_path = public as $$
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
  values(p_user, 'appointments', p_title, p_body, p_appointment, p_appointment::text || ':' || p_key)
  on conflict(dedupe_key) do nothing;
$$;
revoke all on function public.notify_appointment(uuid, uuid, text, text, text) from public, anon, authenticated;

-- Ações do prestador ao longo do atendimento.
create function public.provider_appointment_action(p_id uuid, p_action text, p_minutes integer default null, p_at timestamptz default null)
returns void language plpgsql security definer set search_path = public as $$
declare a public.service_appointments; base timestamptz; tag text := extract(epoch from clock_timestamp())::bigint::text;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is distinct from a.provider_id then raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;

  if p_action = 'start' then
    if a.status = 'in_service' then return; end if;
    if a.service_mode <> 'workshop' or a.status <> 'confirmed' or a.service_request_id is not null then
      raise exception 'Só é possível iniciar um agendamento confirmado na oficina.' using errcode = 'P0001'; end if;
    if now() < a.starts_at - interval '30 minutes' then
      raise exception 'O atendimento só pode ser iniciado a partir de 30 minutos antes do horário.' using errcode = 'P0001'; end if;
    update public.service_appointments set status = 'in_service', started_at = now(), updated_at = now() where id = a.id;
    perform public.notify_appointment(a.requester_id, a.id, 'started', 'Atendimento iniciado', 'O prestador iniciou o atendimento do seu veículo.');

  elsif p_action = 'heading' then
    if a.stage = 'heading' then return; end if;
    if a.service_mode not in ('onsite','pickup') or a.status <> 'confirmed' or a.stage is not null then
      raise exception 'Este agendamento não está pronto para sair.' using errcode = 'P0001'; end if;
    if now() < a.starts_at - interval '120 minutes' then
      raise exception 'Você pode avisar que está a caminho a partir de 2 horas antes do horário.' using errcode = 'P0001'; end if;
    update public.service_appointments set stage = 'heading', updated_at = now() where id = a.id;
    perform public.notify_appointment(a.requester_id, a.id, 'heading', 'Mecânico a caminho',
      case when a.service_mode = 'pickup' then 'O mecânico saiu para buscar o seu veículo.' else 'O mecânico saiu para o seu endereço.' end);

  elsif p_action = 'arrived' then
    if a.stage = 'arrived' then return; end if;
    if a.status <> 'confirmed' or a.stage is distinct from 'heading' then raise exception 'Avise primeiro que está a caminho.' using errcode = 'P0001'; end if;
    update public.service_appointments set stage = 'arrived', delay_minutes = null, delay_status = null, delay_arrival_at = null, updated_at = now() where id = a.id;
    perform public.notify_appointment(a.requester_id, a.id, 'arrived', 'Mecânico chegou',
      case when a.service_mode = 'pickup' then 'Entregue o veículo e confirme a retirada no app.' else 'Confirme a chegada do mecânico no app.' end);

  elsif p_action = 'finish' then
    if a.status = 'completed' then return; end if;
    if a.service_request_id is not null then raise exception 'Este atendimento é concluído pelo fluxo do chamado.' using errcode = 'P0001'; end if;
    if a.status <> 'in_service' or a.service_mode = 'pickup' then
      raise exception 'Inicie o atendimento antes de finalizar.' using errcode = 'P0001'; end if;
    update public.service_appointments set status = 'completed', finished_at = now(), stage = null, updated_at = now() where id = a.id;
    perform public.notify_appointment(a.requester_id, a.id, 'completed', 'Atendimento concluído', 'O prestador finalizou o atendimento. Avalie o serviço.');
    perform public.auto_complete_appointment_plan(a.id);

  elsif p_action = 'finish_service' then
    if a.stage = 'delivery_requested' then return; end if;
    if a.service_mode <> 'pickup' or a.status <> 'in_service' or a.stage is distinct from 'in_workshop' then
      raise exception 'O veículo precisa estar na oficina para finalizar o serviço.' using errcode = 'P0001'; end if;
    if p_minutes is null or p_minutes not between 5 and 240 then raise exception 'Informe em quantos minutos você chega.' using errcode = 'P0001'; end if;
    update public.service_appointments set stage = 'delivery_requested', eta_minutes = p_minutes, updated_at = now() where id = a.id;
    perform public.notify_appointment(a.requester_id, a.id, 'delivery-requested', 'Serviço finalizado',
      'O mecânico quer levar o veículo e chega em ' || p_minutes || ' min se for agora. Escolha agora ou um horário.');

  elsif p_action = 'propose_delivery' then
    if a.service_mode <> 'pickup' or a.stage is distinct from 'delivery_scheduled' then raise exception 'Não há entrega combinada para alterar.' using errcode = 'P0001'; end if;
    if p_at is null or p_at <= now() then raise exception 'Escolha um horário futuro para a entrega.' using errcode = 'P0001'; end if;
    update public.service_appointments set delivery_proposed_at = p_at, updated_at = now() where id = a.id;
    perform public.notify_appointment(a.requester_id, a.id, 'delivery-proposed:' || tag, 'Novo horário de entrega',
      'O mecânico propôs outro horário para entregar o veículo. Aceite ou mantenha o combinado.');

  elsif p_action = 'heading_delivery' then
    if a.stage = 'heading_delivery' then return; end if;
    if a.service_mode <> 'pickup' or a.stage is distinct from 'delivery_scheduled' then raise exception 'A entrega ainda não foi combinada.' using errcode = 'P0001'; end if;
    update public.service_appointments set stage = 'heading_delivery', delivery_proposed_at = null, updated_at = now() where id = a.id;
    perform public.notify_appointment(a.requester_id, a.id, 'heading-delivery', 'Mecânico a caminho', 'Ele saiu com o seu veículo.');

  elsif p_action = 'arrived_delivery' then
    if a.stage = 'arrived_delivery' then return; end if;
    if a.stage is distinct from 'heading_delivery' then raise exception 'Avise primeiro que está a caminho da entrega.' using errcode = 'P0001'; end if;
    update public.service_appointments set stage = 'arrived_delivery', delay_minutes = null, delay_status = null, delay_arrival_at = null, updated_at = now() where id = a.id;
    perform public.notify_appointment(a.requester_id, a.id, 'arrived-delivery', 'Mecânico chegou com o veículo', 'Confira o veículo e confirme o recebimento no app.');

  elsif p_action = 'inform_delay' then
    if p_minutes is null or p_minutes not between 5 and 120 then raise exception 'Informe o atraso em minutos (de 5 a 120).' using errcode = 'P0001'; end if;
    if a.service_mode not in ('onsite','pickup') then raise exception 'Atraso se informa em atendimentos com deslocamento.' using errcode = 'P0001'; end if;
    if a.status = 'confirmed' and a.stage in ('heading') or (a.status = 'confirmed' and a.stage is null) then
      base := a.starts_at;
    elsif a.status = 'in_service' and a.stage in ('delivery_scheduled','heading_delivery') then
      base := coalesce(a.delivery_at, now());
    else raise exception 'Não há deslocamento em andamento para informar atraso.' using errcode = 'P0001'; end if;
    update public.service_appointments set delay_minutes = p_minutes, delay_status = 'pending', delay_arrival_at = base + make_interval(mins => p_minutes), updated_at = now() where id = a.id;
    perform public.notify_appointment(a.requester_id, a.id, 'delay:' || tag, 'O mecânico vai atrasar',
      'Nova chegada em ' || p_minutes || ' min além do combinado. Aceite ou cancele.');
  else
    raise exception 'Ação inválida.' using errcode = 'P0001';
  end if;
end $$;
revoke all on function public.provider_appointment_action(uuid, text, integer, timestamptz) from public, anon;
grant execute on function public.provider_appointment_action(uuid, text, integer, timestamptz) to authenticated;

-- Ações do motorista (confirmações e escolhas).
create function public.driver_appointment_action(p_id uuid, p_action text, p_at timestamptz default null, p_accept boolean default null)
returns void language plpgsql security definer set search_path = public as $$
declare a public.service_appointments;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is distinct from a.requester_id then raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;

  if p_action = 'confirm_arrival' then
    if a.status = 'in_service' then return; end if;
    if a.service_mode <> 'onsite' or a.status <> 'confirmed' or a.stage is distinct from 'arrived' then
      raise exception 'O mecânico ainda não avisou que chegou.' using errcode = 'P0001'; end if;
    update public.service_appointments set status = 'in_service', stage = null, started_at = now(), updated_at = now() where id = a.id;
    perform public.notify_appointment(a.provider_id, a.id, 'arrival-confirmed', 'Chegada confirmada', 'O motorista confirmou a sua chegada. Bom atendimento!');

  elsif p_action = 'confirm_pickup' then
    if a.stage = 'in_workshop' then return; end if;
    if a.service_mode <> 'pickup' or a.status <> 'confirmed' or a.stage is distinct from 'arrived' then
      raise exception 'O mecânico ainda não avisou que chegou.' using errcode = 'P0001'; end if;
    update public.service_appointments set status = 'in_service', stage = 'in_workshop', started_at = now(), updated_at = now() where id = a.id;
    perform public.notify_appointment(a.provider_id, a.id, 'pickup-confirmed', 'Retirada confirmada', 'O motorista confirmou a retirada. O veículo está com você.');

  elsif p_action = 'choose_delivery' then
    if a.stage is distinct from 'delivery_requested' then raise exception 'O mecânico ainda não finalizou o serviço.' using errcode = 'P0001'; end if;
    if p_at is not null and p_at <= now() then raise exception 'Escolha um horário futuro ou entrega agora.' using errcode = 'P0001'; end if;
    update public.service_appointments set stage = 'delivery_scheduled', delivery_at = p_at, updated_at = now() where id = a.id;
    perform public.notify_appointment(a.provider_id, a.id, 'delivery-chosen', 'Entrega combinada',
      case when p_at is null then 'O motorista quer receber o veículo agora.' else 'O motorista escolheu receber o veículo mais tarde.' end);

  elsif p_action = 'respond_delivery' then
    if a.delivery_proposed_at is null then raise exception 'Não há proposta de entrega.' using errcode = 'P0001'; end if;
    if p_accept is null then raise exception 'Escolha aceitar ou manter o combinado.' using errcode = 'P0001'; end if;
    update public.service_appointments set delivery_at = case when p_accept then delivery_proposed_at else delivery_at end, delivery_proposed_at = null, updated_at = now() where id = a.id;
    perform public.notify_appointment(a.provider_id, a.id, 'delivery-answer:' || extract(epoch from clock_timestamp())::bigint::text,
      case when p_accept then 'Entrega alterada' else 'Entrega mantida' end,
      case when p_accept then 'O motorista aceitou o novo horário de entrega.' else 'O motorista manteve o horário combinado.' end);

  elsif p_action = 'confirm_delivery' then
    if a.status = 'completed' then return; end if;
    if a.service_mode <> 'pickup' or a.stage is distinct from 'arrived_delivery' then
      raise exception 'O mecânico ainda não avisou que chegou com o veículo.' using errcode = 'P0001'; end if;
    update public.service_appointments set status = 'completed', finished_at = now(), stage = null, updated_at = now() where id = a.id;
    perform public.notify_appointment(a.provider_id, a.id, 'delivery-confirmed', 'Entrega confirmada', 'O motorista confirmou o recebimento do veículo.');
    perform public.notify_appointment(a.requester_id, a.id, 'completed', 'Atendimento concluído', 'Veículo entregue. Avalie o serviço.');
    perform public.auto_complete_appointment_plan(a.id);

  elsif p_action = 'respond_delay' then
    if a.delay_status is distinct from 'pending' then raise exception 'Não há atraso para responder.' using errcode = 'P0001'; end if;
    if p_accept is null then raise exception 'Escolha aceitar ou cancelar.' using errcode = 'P0001'; end if;
    if p_accept then
      update public.service_appointments set delay_status = 'accepted', updated_at = now() where id = a.id;
      perform public.notify_appointment(a.provider_id, a.id, 'delay-accepted:' || extract(epoch from clock_timestamp())::bigint::text, 'Atraso aceito', 'O motorista aceitou o novo horário.');
    else
      if a.status <> 'confirmed' then raise exception 'Com o veículo com o mecânico não é possível cancelar; fale com ele.' using errcode = 'P0001'; end if;
      update public.service_appointments set status = 'cancelled', cancel_reason = 'delay_refused', stage = null, delay_status = null, updated_at = now() where id = a.id;
      perform public.notify_appointment(a.provider_id, a.id, 'delay-refused', 'Agendamento cancelado', 'O motorista não aceitou o novo horário e cancelou o agendamento.');
    end if;
  else
    raise exception 'Ação inválida.' using errcode = 'P0001';
  end if;
end $$;
revoke all on function public.driver_appointment_action(uuid, text, timestamptz, boolean) from public, anon;
grant execute on function public.driver_appointment_action(uuid, text, timestamptz, boolean) to authenticated;

-- Lista e detalhe com as mesmas colunas, para os dois papéis.
create function public.list_my_service_appointments()
returns table(id uuid, requester_id uuid, provider_id uuid, vehicle_id uuid, starts_at timestamptz, ends_at timestamptz,
  description text, status text, service_request_id uuid, maintenance_plan_id uuid, vehicle_label text, provider_name text,
  vehicle_odometer integer, proposed_starts_at timestamptz, proposed_ends_at timestamptz, proposed_by uuid,
  service_mode text, location_label text, started_at timestamptz, finished_at timestamptz, cancel_reason text, requester_name text,
  has_review boolean, travel_fee_cents integer, stage text, eta_minutes integer, delivery_at timestamptz,
  delivery_proposed_at timestamptz, delay_minutes integer, delay_status text, delay_arrival_at timestamptz, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select a.id, a.requester_id, a.provider_id, a.vehicle_id, a.starts_at, a.ends_at, a.description, a.status,
    a.service_request_id, a.maintenance_plan_id, v.model || ' · ' || v.plate, p.business_name,
    a.vehicle_odometer, a.proposed_starts_at, a.proposed_ends_at, a.proposed_by,
    a.service_mode, a.location_label, a.started_at, a.finished_at, a.cancel_reason, r.full_name,
    exists(select 1 from public.reviews rv where rv.appointment_id = a.id and rv.reviewer_id = a.requester_id),
    a.travel_fee_cents, a.stage, a.eta_minutes, a.delivery_at, a.delivery_proposed_at,
    a.delay_minutes, a.delay_status, a.delay_arrival_at, a.created_at
  from public.service_appointments a join public.vehicles v on v.id = a.vehicle_id
  join public.provider_profiles p on p.provider_id = a.provider_id
  join public.profiles r on r.id = a.requester_id
  where auth.uid() in (a.requester_id, a.provider_id)
  order by a.starts_at desc limit 200;
$$;
revoke all on function public.list_my_service_appointments() from public, anon;
grant execute on function public.list_my_service_appointments() to authenticated;

drop function public.get_service_appointment_detail(uuid);
create function public.get_service_appointment_detail(p_id uuid)
returns table(id uuid, requester_id uuid, provider_id uuid, vehicle_id uuid, starts_at timestamptz, ends_at timestamptz,
  description text, status text, service_request_id uuid, maintenance_plan_id uuid, vehicle_label text, provider_name text,
  vehicle_odometer integer, proposed_starts_at timestamptz, proposed_ends_at timestamptz, proposed_by uuid,
  service_mode text, location_label text, started_at timestamptz, finished_at timestamptz, cancel_reason text, requester_name text,
  has_review boolean, travel_fee_cents integer, stage text, eta_minutes integer, delivery_at timestamptz,
  delivery_proposed_at timestamptz, delay_minutes integer, delay_status text, delay_arrival_at timestamptz, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select a.id, a.requester_id, a.provider_id, a.vehicle_id, a.starts_at, a.ends_at, a.description, a.status,
    a.service_request_id, a.maintenance_plan_id, v.model || ' · ' || v.plate, p.business_name,
    a.vehicle_odometer, a.proposed_starts_at, a.proposed_ends_at, a.proposed_by,
    a.service_mode, a.location_label, a.started_at, a.finished_at, a.cancel_reason, r.full_name,
    exists(select 1 from public.reviews rv where rv.appointment_id = a.id and rv.reviewer_id = a.requester_id),
    a.travel_fee_cents, a.stage, a.eta_minutes, a.delivery_at, a.delivery_proposed_at,
    a.delay_minutes, a.delay_status, a.delay_arrival_at, a.created_at
  from public.service_appointments a join public.vehicles v on v.id = a.vehicle_id
  join public.provider_profiles p on p.provider_id = a.provider_id
  join public.profiles r on r.id = a.requester_id
  where a.id = p_id and auth.uid() in (a.requester_id, a.provider_id);
$$;
revoke all on function public.get_service_appointment_detail(uuid) from public, anon;
grant execute on function public.get_service_appointment_detail(uuid) to authenticated;
