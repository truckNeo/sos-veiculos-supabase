-- Veículos acessíveis e escolha do veículo ativo por motorista.

create table public.profile_vehicle_preferences (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  active_vehicle_id uuid references public.vehicles(id) on delete set null,
  updated_at timestamptz not null default timezone('utc', now())
);

create unique index vehicles_plate_normalized_key
  on public.vehicles (upper(plate));

create or replace function public.is_organization_vehicle_manager(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.organizations organization
    where organization.id = target_organization_id
      and organization.owner_id = auth.uid()
  )
  or exists (
    select 1
    from public.organization_members member
    where member.organization_id = target_organization_id
      and member.user_id = auth.uid()
      and member.member_role in ('owner', 'manager')
  );
$$;

create or replace function public.can_manage_vehicle(target_vehicle_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.vehicles vehicle
    where vehicle.id = target_vehicle_id
      and (
        vehicle.owner_profile_id = auth.uid()
        or public.is_organization_vehicle_manager(vehicle.organization_id)
      )
  );
$$;

create or replace function public.can_select_active_vehicle(target_vehicle_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles profile
    join public.vehicles vehicle on vehicle.id = target_vehicle_id
    where profile.id = auth.uid()
      and profile.role = 'driver'
      and vehicle.status = 'active'
      and public.can_access_vehicle(vehicle.id)
  );
$$;

create or replace function public.clear_ineligible_active_vehicle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status <> 'active' then
    update public.profile_vehicle_preferences
    set active_vehicle_id = null, updated_at = timezone('utc', now())
    where active_vehicle_id = new.id;
  end if;
  return new;
end;
$$;

drop policy "owners can create vehicles" on public.vehicles;
drop policy "owners can update vehicles" on public.vehicles;

create policy "owners and managers can create vehicles"
  on public.vehicles for insert to authenticated
  with check (
    owner_profile_id = auth.uid()
    or public.is_organization_vehicle_manager(organization_id)
  );

create policy "owners and managers can update vehicles"
  on public.vehicles for update to authenticated
  using (public.can_manage_vehicle(id))
  with check (
    owner_profile_id = auth.uid()
    or public.is_organization_vehicle_manager(organization_id)
  );

alter table public.profile_vehicle_preferences enable row level security;

create policy "drivers can read own vehicle preference"
  on public.profile_vehicle_preferences for select to authenticated
  using (profile_id = auth.uid());
create policy "drivers can create own vehicle preference"
  on public.profile_vehicle_preferences for insert to authenticated
  with check (
    profile_id = auth.uid()
    and public.can_select_active_vehicle(active_vehicle_id)
  );
create policy "drivers can update own vehicle preference"
  on public.profile_vehicle_preferences for update to authenticated
  using (profile_id = auth.uid())
  with check (
    profile_id = auth.uid()
    and public.can_select_active_vehicle(active_vehicle_id)
  );
create policy "drivers can delete own vehicle preference"
  on public.profile_vehicle_preferences for delete to authenticated
  using (profile_id = auth.uid());

create trigger vehicles_clear_ineligible_active_vehicle
  after update of status on public.vehicles
  for each row execute function public.clear_ineligible_active_vehicle();

revoke all on function public.is_organization_vehicle_manager(uuid) from public;
revoke all on function public.can_select_active_vehicle(uuid) from public;
grant execute on function public.is_organization_vehicle_manager(uuid) to authenticated;
grant execute on function public.can_select_active_vehicle(uuid) to authenticated;

grant select, insert, update, delete on public.profile_vehicle_preferences to authenticated;
