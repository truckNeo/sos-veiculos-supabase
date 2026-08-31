-- Módulo 7: convites de mecânicos favoritos.
-- Motoristas descobrem prestadores; cada convite só é visível aos seus participantes.

create table public.favorite_mechanic_invites (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.profiles(id) on delete cascade,
  provider_id uuid not null references public.provider_profiles(provider_id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  responded_at timestamptz,
  unique (driver_id, provider_id)
);

create index favorite_mechanic_invites_provider_idx
  on public.favorite_mechanic_invites(provider_id, status);
create index favorite_mechanic_invites_driver_idx
  on public.favorite_mechanic_invites(driver_id, status);

create trigger favorite_mechanic_invites_updated_at
  before update on public.favorite_mechanic_invites
  for each row execute function public.set_updated_at();

alter table public.favorite_mechanic_invites enable row level security;
grant select, insert, update, delete on public.favorite_mechanic_invites to authenticated;

create policy "participants can read favorite mechanic invites"
  on public.favorite_mechanic_invites for select to authenticated
  using (driver_id = auth.uid() or provider_id = auth.uid());

create policy "drivers can create favorite mechanic invites"
  on public.favorite_mechanic_invites for insert to authenticated
  with check (
    driver_id = auth.uid()
    and exists (select 1 from public.profiles where id = auth.uid() and role = 'driver')
    and exists (select 1 from public.profiles where id = provider_id and role = 'provider')
  );

create policy "drivers can remove favorite mechanic invites"
  on public.favorite_mechanic_invites for delete to authenticated
  using (driver_id = auth.uid());

create policy "providers can respond to favorite mechanic invites"
  on public.favorite_mechanic_invites for update to authenticated
  using (provider_id = auth.uid())
  with check (provider_id = auth.uid());

create or replace function public.list_available_favorite_mechanics()
returns table (
  provider_id uuid,
  business_name text,
  full_name text,
  average_rating numeric,
  completed_services integer,
  service_radius_km integer
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'driver') then
    raise exception 'Apenas motoristas podem listar mecânicos.' using errcode = '42501';
  end if;
  return query
    select pp.provider_id, pp.business_name, p.full_name,
      pp.average_rating, pp.completed_services, pp.service_radius_km
    from public.provider_profiles pp
    join public.profiles p on p.id = pp.provider_id
    where p.role = 'provider' and pp.is_available = true
    order by pp.average_rating desc, pp.completed_services desc, pp.business_name;
end;
$$;

create or replace function public.list_my_favorite_mechanics()
returns table (
  invite_id uuid,
  provider_id uuid,
  business_name text,
  full_name text,
  average_rating numeric,
  completed_services integer,
  service_radius_km integer,
  status text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select i.id, i.provider_id, pp.business_name, p.full_name,
      pp.average_rating, pp.completed_services, pp.service_radius_km, i.status
    from public.favorite_mechanic_invites i
    join public.provider_profiles pp on pp.provider_id = i.provider_id
    join public.profiles p on p.id = pp.provider_id
    where i.driver_id = auth.uid()
    order by i.created_at desc;
end;
$$;

create or replace function public.create_favorite_mechanic_invite(p_provider_id uuid)
returns public.favorite_mechanic_invites
language plpgsql security invoker set search_path = public
as $$
declare result public.favorite_mechanic_invites;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'driver') then
    raise exception 'Apenas motoristas podem enviar convites.' using errcode = '42501';
  end if;
  insert into public.favorite_mechanic_invites(driver_id, provider_id, status, responded_at)
  values (auth.uid(), p_provider_id, 'pending', null)
  on conflict (driver_id, provider_id) do update
    set status = 'pending', responded_at = null, updated_at = timezone('utc', now());
  select * into result from public.favorite_mechanic_invites
  where driver_id = auth.uid() and provider_id = p_provider_id;
  return result;
end;
$$;

create or replace function public.list_received_favorite_mechanic_invites()
returns table (
  invite_id uuid,
  driver_id uuid,
  driver_name text,
  status text,
  created_at timestamptz
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select i.id, i.driver_id, p.full_name, i.status, i.created_at
    from public.favorite_mechanic_invites i
    join public.profiles p on p.id = i.driver_id
    where i.provider_id = auth.uid()
    order by i.created_at desc;
end;
$$;

create or replace function public.respond_favorite_mechanic_invite(
  p_invite_id uuid,
  p_status text
)
returns public.favorite_mechanic_invites
language plpgsql security invoker set search_path = public
as $$
declare result public.favorite_mechanic_invites;
begin
  if p_status not in ('accepted', 'rejected') then
    raise exception 'Resposta de convite inválida.' using errcode = '22023';
  end if;
  update public.favorite_mechanic_invites
  set status = p_status, responded_at = timezone('utc', now())
  where id = p_invite_id and provider_id = auth.uid();
  if not found then
    raise exception 'Convite não encontrado para este prestador.' using errcode = '42501';
  end if;
  select * into result from public.favorite_mechanic_invites where id = p_invite_id;
  return result;
end;
$$;

revoke all on function public.list_available_favorite_mechanics() from public;
revoke all on function public.list_my_favorite_mechanics() from public;
revoke all on function public.create_favorite_mechanic_invite(uuid) from public;
revoke all on function public.list_received_favorite_mechanic_invites() from public;
revoke all on function public.respond_favorite_mechanic_invite(uuid, text) from public;
grant execute on function public.list_available_favorite_mechanics() to authenticated;
grant execute on function public.list_my_favorite_mechanics() to authenticated;
grant execute on function public.create_favorite_mechanic_invite(uuid) to authenticated;
grant execute on function public.list_received_favorite_mechanic_invites() to authenticated;
grant execute on function public.respond_favorite_mechanic_invite(uuid, text) to authenticated;
