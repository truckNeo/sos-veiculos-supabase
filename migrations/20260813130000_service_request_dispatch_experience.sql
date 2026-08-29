-- Presença efêmera na descoberta e chat privado após a seleção do prestador.
-- Não expõe a identidade dos prestadores que apenas visualizaram o chamado.

create table public.service_request_provider_views (
  request_id uuid not null references public.service_requests(id) on delete cascade,
  provider_id uuid not null references public.provider_profiles(provider_id) on delete cascade,
  last_viewed_at timestamptz not null default timezone('utc', now()),
  primary key (request_id, provider_id)
);

create index service_request_provider_views_recent_idx
  on public.service_request_provider_views(request_id, last_viewed_at desc);

alter table public.service_request_provider_views enable row level security;
revoke all on public.service_request_provider_views from authenticated;

create or replace function public.mark_service_request_view(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_provider_id uuid := auth.uid();
  provider_location extensions.geography;
  provider_location_updated_at timestamptz;
  provider_radius_meters integer;
  request_location extensions.geography;
  request_problem public.request_problem_type;
  request_status public.service_request_status;
  request_phase public.service_workflow_phase;
begin
  if current_provider_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;

  select provider_location_row.location, provider_location_row.updated_at,
    provider.service_radius_km * 1000
  into provider_location, provider_location_updated_at, provider_radius_meters
  from public.provider_profiles provider
  join public.provider_locations provider_location_row
    on provider_location_row.provider_id = provider.provider_id
  where provider.provider_id = current_provider_id and provider.is_available;

  if provider_location is null
    or provider_location_updated_at < timezone('utc', now()) - interval '15 minutes' then
    raise exception 'Atualize sua localização e disponibilidade para visualizar chamados.' using errcode = 'P0001';
  end if;

  select request.location, request.problem_type, request.status, request.workflow_phase
  into request_location, request_problem, request_status, request_phase
  from public.service_requests request
  where request.id = p_request_id;

  if request_location is null
    or request_status not in ('open', 'collecting_offers')
    or request_phase <> 'open'
    or not exists (
      select 1 from public.provider_services service
      where service.provider_id = current_provider_id and service.problem_type = request_problem
    )
    or not extensions.st_dwithin(request_location, provider_location, provider_radius_meters) then
    raise exception 'Este chamado não está disponível para visualização.' using errcode = '42501';
  end if;

  insert into public.service_request_provider_views (request_id, provider_id, last_viewed_at)
  values (p_request_id, current_provider_id, timezone('utc', now()))
  on conflict (request_id, provider_id)
  do update set last_viewed_at = excluded.last_viewed_at;
end;
$$;

create or replace function public.get_service_request_discovery_summary(p_request_id uuid)
returns table (active_viewers integer, offer_count integer)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.service_requests request
    where request.id = p_request_id and request.requester_id = auth.uid()
  ) then
    raise exception 'Chamado não encontrado ou sem permissão.' using errcode = '42501';
  end if;

  return query
  select
    (
      select count(*)::integer
      from public.service_request_provider_views view_row
      where view_row.request_id = request.id
        and view_row.last_viewed_at >= timezone('utc', now()) - interval '3 minutes'
    ),
    (
      select count(*)::integer
      from public.provider_offers offer
      where offer.request_id = request.id and offer.status = 'submitted'
    )
  from public.service_requests request
  where request.id = p_request_id;
end;
$$;

revoke all on function public.mark_service_request_view(uuid) from public;
revoke all on function public.get_service_request_discovery_summary(uuid) from public;
grant execute on function public.mark_service_request_view(uuid) to authenticated;
grant execute on function public.get_service_request_discovery_summary(uuid) to authenticated;

create table public.service_request_messages (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete restrict,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default timezone('utc', now())
);

create index service_request_messages_timeline_idx
  on public.service_request_messages(request_id, created_at, id);

create or replace function public.can_access_selected_service_request_chat(p_request_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.service_requests request
    where request.id = p_request_id
      and (request.requester_id = auth.uid() or request.selected_provider_id = auth.uid())
  );
$$;

alter table public.service_request_messages enable row level security;
create policy "selected request participants can read chat"
  on public.service_request_messages for select to authenticated
  using (public.can_access_selected_service_request_chat(request_id));
create policy "selected request participants can send chat"
  on public.service_request_messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and public.can_access_selected_service_request_chat(request_id)
    and exists (
      select 1 from public.service_requests request
      where request.id = request_id
        and request.workflow_phase not in ('completed', 'cancelled')
    )
  );

revoke all on public.service_request_messages from authenticated;
grant select, insert on public.service_request_messages to authenticated;
revoke all on function public.can_access_selected_service_request_chat(uuid) from public;
grant execute on function public.can_access_selected_service_request_chat(uuid) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'service_request_messages'
  ) then
    alter publication supabase_realtime add table public.service_request_messages;
  end if;
end;
$$;
