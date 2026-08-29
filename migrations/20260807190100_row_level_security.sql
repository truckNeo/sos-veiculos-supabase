-- SOS Veículo: isolamento de dados por usuário, organização e participação no chamado.

create or replace function public.is_organization_member(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.organization_members member
    where member.organization_id = target_organization_id
      and member.user_id = auth.uid()
  );
$$;

create or replace function public.is_organization_owner(target_organization_id uuid)
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
        or vehicle.assigned_driver_id = auth.uid()
        or public.is_organization_member(vehicle.organization_id)
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

create or replace function public.is_request_participant(target_request_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.service_requests request
    where request.id = target_request_id
      and request.requester_id = auth.uid()
  )
  or exists (
    select 1
    from public.provider_offers offer
    where offer.request_id = target_request_id
      and offer.provider_id = auth.uid()
  );
$$;

revoke all on function public.is_organization_member(uuid) from public;
revoke all on function public.is_organization_owner(uuid) from public;
revoke all on function public.can_access_vehicle(uuid) from public;
revoke all on function public.can_manage_vehicle(uuid) from public;
revoke all on function public.is_request_participant(uuid) from public;
grant execute on function public.is_organization_member(uuid) to authenticated;
grant execute on function public.is_organization_owner(uuid) to authenticated;
grant execute on function public.can_access_vehicle(uuid) to authenticated;
grant execute on function public.can_manage_vehicle(uuid) to authenticated;
grant execute on function public.is_request_participant(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.vehicles enable row level security;
alter table public.provider_profiles enable row level security;
alter table public.provider_services enable row level security;
alter table public.provider_locations enable row level security;
alter table public.service_requests enable row level security;
alter table public.request_attachments enable row level security;
alter table public.provider_offers enable row level security;
alter table public.history_access_grants enable row level security;
alter table public.service_request_events enable row level security;
alter table public.reviews enable row level security;

create policy "profile owners can read their profile"
  on public.profiles for select to authenticated
  using (id = auth.uid());
create policy "profile owners can create their profile"
  on public.profiles for insert to authenticated
  with check (id = auth.uid());
create policy "profile owners can update their profile"
  on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "organization members can read organization"
  on public.organizations for select to authenticated
  using (public.is_organization_member(id) or owner_id = auth.uid());
create policy "authenticated users can create owned organization"
  on public.organizations for insert to authenticated
  with check (owner_id = auth.uid());
create policy "organization owners can update organization"
  on public.organizations for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "organization owners can delete organization"
  on public.organizations for delete to authenticated
  using (owner_id = auth.uid());

create policy "organization members can read memberships"
  on public.organization_members for select to authenticated
  using (public.is_organization_member(organization_id));
create policy "organization owners can add memberships"
  on public.organization_members for insert to authenticated
  with check (public.is_organization_owner(organization_id));
create policy "organization owners can update memberships"
  on public.organization_members for update to authenticated
  using (public.is_organization_owner(organization_id))
  with check (public.is_organization_owner(organization_id));
create policy "organization owners can remove memberships"
  on public.organization_members for delete to authenticated
  using (public.is_organization_owner(organization_id));

create policy "vehicle participants can read vehicles"
  on public.vehicles for select to authenticated
  using (public.can_access_vehicle(id));
create policy "owners can create vehicles"
  on public.vehicles for insert to authenticated
  with check (
    owner_profile_id = auth.uid()
    or public.is_organization_owner(organization_id)
  );
create policy "owners can update vehicles"
  on public.vehicles for update to authenticated
  using (public.can_manage_vehicle(id))
  with check (
    owner_profile_id = auth.uid()
    or public.is_organization_owner(organization_id)
  );
create policy "owners can delete vehicles"
  on public.vehicles for delete to authenticated
  using (public.can_manage_vehicle(id));

create policy "providers can read their provider profile"
  on public.provider_profiles for select to authenticated
  using (provider_id = auth.uid());
create policy "requesters can read providers who sent an offer"
  on public.provider_profiles for select to authenticated
  using (
    exists (
      select 1
      from public.provider_offers offer
      join public.service_requests request on request.id = offer.request_id
      where offer.provider_id = provider_profiles.provider_id
        and request.requester_id = auth.uid()
    )
  );
create policy "providers can create their provider profile"
  on public.provider_profiles for insert to authenticated
  with check (provider_id = auth.uid());
create policy "providers can update their provider profile"
  on public.provider_profiles for update to authenticated
  using (provider_id = auth.uid()) with check (provider_id = auth.uid());

create policy "providers can manage own services"
  on public.provider_services for all to authenticated
  using (provider_id = auth.uid()) with check (provider_id = auth.uid());
create policy "requesters can read services from offering providers"
  on public.provider_services for select to authenticated
  using (
    exists (
      select 1
      from public.provider_offers offer
      join public.service_requests request on request.id = offer.request_id
      where offer.provider_id = provider_services.provider_id
        and request.requester_id = auth.uid()
    )
  );
create policy "providers can manage own location"
  on public.provider_locations for all to authenticated
  using (provider_id = auth.uid()) with check (provider_id = auth.uid());

create policy "request participants can read requests"
  on public.service_requests for select to authenticated
  using (requester_id = auth.uid() or public.is_request_participant(id));
create policy "vehicle participants can open request"
  on public.service_requests for insert to authenticated
  with check (requester_id = auth.uid() and public.can_access_vehicle(vehicle_id));
create policy "requester can update request"
  on public.service_requests for update to authenticated
  using (requester_id = auth.uid()) with check (requester_id = auth.uid());

create policy "request participants can read attachments"
  on public.request_attachments for select to authenticated
  using (public.is_request_participant(request_id));
create policy "requester can add attachments"
  on public.request_attachments for insert to authenticated
  with check (
    uploaded_by = auth.uid()
    and exists (
      select 1 from public.service_requests request
      where request.id = request_id and request.requester_id = auth.uid()
    )
  );
create policy "requester can delete own attachments"
  on public.request_attachments for delete to authenticated
  using (uploaded_by = auth.uid());

create policy "providers can read own offers"
  on public.provider_offers for select to authenticated
  using (provider_id = auth.uid());
create policy "requesters can read offers on own request"
  on public.provider_offers for select to authenticated
  using (
    exists (
      select 1 from public.service_requests request
      where request.id = request_id and request.requester_id = auth.uid()
    )
  );
create policy "providers can create own offers"
  on public.provider_offers for insert to authenticated
  with check (provider_id = auth.uid());
create policy "providers can update own offers"
  on public.provider_offers for update to authenticated
  using (provider_id = auth.uid()) with check (provider_id = auth.uid());
create policy "providers can delete own offers"
  on public.provider_offers for delete to authenticated
  using (provider_id = auth.uid());

create policy "requesters can grant history access"
  on public.history_access_grants for insert to authenticated
  with check (
    granted_by = auth.uid()
    and exists (
      select 1 from public.service_requests request
      where request.id = request_id
        and request.requester_id = auth.uid()
        and request.vehicle_id = vehicle_id
    )
  );
create policy "requesters and granted providers can read history grants"
  on public.history_access_grants for select to authenticated
  using (granted_by = auth.uid() or provider_id = auth.uid());
create policy "requesters can revoke history access"
  on public.history_access_grants for update to authenticated
  using (granted_by = auth.uid()) with check (granted_by = auth.uid());

create policy "request participants can read status events"
  on public.service_request_events for select to authenticated
  using (public.is_request_participant(request_id));

create policy "requesters and reviewed providers can read review"
  on public.reviews for select to authenticated
  using (reviewer_id = auth.uid() or provider_id = auth.uid());
create policy "requester can create review after service"
  on public.reviews for insert to authenticated
  with check (
    reviewer_id = auth.uid()
    and exists (
      select 1
      from public.service_requests request
      join public.provider_offers offer on offer.request_id = request.id
      where request.id = request_id
        and request.requester_id = auth.uid()
        and request.status = 'completed'
        and offer.provider_id = reviews.provider_id
        and offer.status = 'accepted'
    )
  );

revoke all on all tables in schema public from anon;
revoke all on public.profiles from authenticated;
grant select, insert on public.profiles to authenticated;
grant update (full_name, phone, avatar_path) on public.profiles to authenticated;
grant select, insert, update, delete on public.organizations to authenticated;
grant select, insert, update, delete on public.organization_members to authenticated;
grant select, insert, update, delete on public.vehicles to authenticated;
grant select, insert, update, delete on public.provider_profiles to authenticated;
grant select, insert, update, delete on public.provider_services to authenticated;
grant select, insert, update, delete on public.provider_locations to authenticated;
grant select, insert, update, delete on public.service_requests to authenticated;
grant select, insert, update, delete on public.request_attachments to authenticated;
grant select, insert, update, delete on public.provider_offers to authenticated;
grant select, insert, update, delete on public.history_access_grants to authenticated;
grant select on public.service_request_events to authenticated;
grant select, insert on public.reviews to authenticated;
grant usage on type public.app_role, public.account_kind, public.organization_member_role,
  public.vehicle_status, public.request_problem_type, public.service_request_status,
  public.offer_status, public.attachment_kind to authenticated;
