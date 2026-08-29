-- MVP inicial: uma transportadora administra apenas a própria frota.
-- Não há convite, vínculo de motorista externo ou atribuição de veículo.

drop function if exists public.invite_organization_driver(text);
drop function if exists public.accept_organization_driver_invitation(text);
drop function if exists public.remove_organization_driver(uuid);
drop function if exists public.assign_organization_vehicle_driver(uuid, uuid);

drop policy if exists "organization managers can read member profiles" on public.profiles;
drop policy if exists "organization members can read organization" on public.organizations;
drop policy if exists "organization members can read memberships" on public.organization_members;
drop policy if exists "organization owners can add memberships" on public.organization_members;
drop policy if exists "organization owners can update memberships" on public.organization_members;
drop policy if exists "organization owners can remove memberships" on public.organization_members;
create policy "organization owners can read organization"
  on public.organizations for select to authenticated
  using (owner_id = auth.uid());

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
        or public.is_organization_owner(vehicle.organization_id)
      )
  );
$$;

create or replace function public.can_access_vehicle(target_vehicle_id uuid)
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
        or public.is_organization_owner(vehicle.organization_id)
        or exists (
          select 1
          from public.history_access_grants access_grant
          where access_grant.vehicle_id = vehicle.id
            and access_grant.provider_id = auth.uid()
            and access_grant.revoked_at is null
        )
      )
  );
$$;

drop policy if exists "owners and managers can create vehicles" on public.vehicles;
drop policy if exists "owners and managers can update vehicles" on public.vehicles;
create policy "vehicle owners can create vehicles"
  on public.vehicles for insert to authenticated
  with check (
    owner_profile_id = auth.uid()
    or public.is_organization_owner(organization_id)
  );
create policy "vehicle owners can update vehicles"
  on public.vehicles for update to authenticated
  using (public.can_manage_vehicle(id))
  with check (
    owner_profile_id = auth.uid()
    or public.is_organization_owner(organization_id)
  );

drop table if exists public.organization_driver_invitations;
alter table public.vehicles drop column if exists assigned_driver_id;
drop table if exists public.organization_members;
drop function if exists public.is_organization_member(uuid);
drop type if exists public.organization_member_role;
