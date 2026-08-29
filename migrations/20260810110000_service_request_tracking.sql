-- Rastreamento por atendimento: consentimento explícito, pontos efêmeros e
-- escrita controlada pelo prestador selecionado.
alter table public.service_requests
  add column tracking_enabled boolean not null default false,
  add column tracking_consent_at timestamptz,
  add column tracking_revoked_at timestamptz;

create table public.service_request_locations (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  provider_id uuid not null references public.provider_profiles(provider_id) on delete cascade,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_meters double precision check (accuracy_meters is null or accuracy_meters >= 0),
  captured_at timestamptz not null default timezone('utc', now()),
  expires_at timestamptz not null,
  created_at timestamptz not null default timezone('utc', now())
);

create index service_request_locations_latest_idx
  on public.service_request_locations(request_id, captured_at desc);

alter table public.service_request_locations enable row level security;
create policy "participants can read current tracking"
  on public.service_request_locations for select to authenticated
  using (
    expires_at > timezone('utc', now())
    and public.is_request_participant(request_id)
  );
revoke all on public.service_request_locations from authenticated;
grant select on public.service_request_locations to authenticated;

create or replace function public.set_service_request_tracking_consent(
  p_request_id uuid,
  p_allowed boolean
)
returns table (request_id uuid, tracking_enabled boolean, tracking_consent_at timestamptz)
language plpgsql security definer set search_path = public
as $$
declare
  requester uuid := auth.uid();
  provider uuid;
  phase public.service_workflow_phase;
  current_status public.service_request_status;
begin
  select selected_provider_id, workflow_phase, status into provider, phase, current_status
  from public.service_requests
  where id = p_request_id and requester_id = requester
  for update;
  if requester is null or provider is null then
    raise exception 'Chamado não encontrado ou sem permissão.' using errcode = '42501';
  end if;
  if phase in ('completed', 'cancelled') then
    raise exception 'O rastreamento não pode ser alterado após o encerramento.' using errcode = 'P0001';
  end if;

  update public.service_requests
  set tracking_enabled = p_allowed,
    tracking_consent_at = case when p_allowed then timezone('utc', now()) else tracking_consent_at end,
    tracking_revoked_at = case when p_allowed then null else timezone('utc', now()) end
  where id = p_request_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, requester, current_status, case when p_allowed then 'Motorista autorizou o rastreamento do prestador.' else 'Motorista revogou o rastreamento do prestador.' end);
  return query select p_request_id, p_allowed, (select tracking_consent_at from public.service_requests where id = p_request_id);
end;
$$;

create or replace function public.record_service_request_location(
  p_request_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_meters double precision default null
)
returns table (id uuid, captured_at timestamptz, expires_at timestamptz)
language plpgsql security definer set search_path = public
as $$
declare
  provider uuid := auth.uid();
  request_provider uuid;
  tracking_enabled boolean;
  request_status public.service_request_status;
  captured timestamptz := timezone('utc', now());
  created_location public.service_request_locations;
begin
  select selected_provider_id, tracking_enabled, status
  into request_provider, tracking_enabled, request_status
  from public.service_requests
  where id = p_request_id
  for update;
  if provider is null or request_provider <> provider then
    raise exception 'Somente o prestador selecionado pode enviar localização.' using errcode = '42501';
  end if;
  if not tracking_enabled then
    raise exception 'O motorista ainda não autorizou o rastreamento.' using errcode = 'P0001';
  end if;
  if request_status not in ('provider_en_route', 'provider_on_site', 'in_service') then
    raise exception 'O chamado não está em uma etapa de rastreamento.' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.service_request_locations location_row
    where location_row.request_id = p_request_id and location_row.provider_id = provider
      and location_row.created_at > captured - interval '15 seconds'
  ) then
    raise exception 'Aguarde antes de enviar outra posição.' using errcode = 'P0001';
  end if;

  insert into public.service_request_locations (request_id, provider_id, latitude, longitude, accuracy_meters, captured_at, expires_at)
  values (p_request_id, provider, p_latitude, p_longitude, p_accuracy_meters, captured, captured + interval '5 minutes')
  returning service_request_locations.id, service_request_locations.captured_at,
    service_request_locations.expires_at into created_location;
  return query select created_location.id, created_location.captured_at, created_location.expires_at;
end;
$$;

revoke all on function public.set_service_request_tracking_consent(uuid, boolean) from public;
revoke all on function public.record_service_request_location(uuid, double precision, double precision, double precision) from public;
grant execute on function public.set_service_request_tracking_consent(uuid, boolean) to authenticated;
grant execute on function public.record_service_request_location(uuid, double precision, double precision, double precision) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'service_request_locations'
  ) then
    alter publication supabase_realtime add table public.service_request_locations;
  end if;
end;
$$;
