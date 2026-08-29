-- SOS Veículo: núcleo de identidade, frota, prestadores e atendimentos.
-- Esta migration não contém chaves nem dados pessoais reais.

create extension if not exists pgcrypto;

create type public.app_role as enum ('driver', 'provider');
create type public.account_kind as enum ('individual', 'company');
create type public.organization_member_role as enum ('owner', 'manager', 'driver');
create type public.vehicle_status as enum ('active', 'maintenance', 'inactive');
create type public.request_problem_type as enum ('engine', 'tire', 'electrical', 'other');
create type public.service_request_status as enum (
  'open',
  'collecting_offers',
  'offer_accepted',
  'provider_en_route',
  'provider_on_site',
  'in_service',
  'completed',
  'cancelled'
);
create type public.offer_status as enum ('submitted', 'accepted', 'rejected', 'withdrawn', 'expired');
create type public.attachment_kind as enum ('image', 'audio');

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.app_role not null,
  account_kind public.account_kind not null default 'individual',
  full_name text not null check (char_length(trim(full_name)) >= 2),
  phone text not null,
  -- A aplicação/Edge Function grava um HMAC ou hash com segredo; nunca o documento puro.
  document_hash text not null unique,
  document_last4 text not null check (document_last4 ~ '^[0-9]{4}$'),
  avatar_path text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete restrict,
  legal_name text not null check (char_length(trim(legal_name)) >= 2),
  trade_name text,
  cnpj_hash text not null unique,
  cnpj_last4 text not null check (cnpj_last4 ~ '^[0-9]{4}$'),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  member_role public.organization_member_role not null default 'driver',
  created_at timestamptz not null default timezone('utc', now()),
  primary key (organization_id, user_id)
);

create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  owner_profile_id uuid references public.profiles(id) on delete restrict,
  organization_id uuid references public.organizations(id) on delete restrict,
  assigned_driver_id uuid references public.profiles(id) on delete set null,
  plate text not null unique,
  make text,
  model text not null,
  year smallint check (year between 1950 and 2100),
  vin text,
  status public.vehicle_status not null default 'active',
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint vehicles_have_one_owner check (
    (owner_profile_id is not null and organization_id is null)
    or (owner_profile_id is null and organization_id is not null)
  )
);

create table public.provider_profiles (
  provider_id uuid primary key references public.profiles(id) on delete cascade,
  business_name text not null,
  bio text,
  service_radius_km integer not null default 30 check (service_radius_km between 1 and 500),
  is_available boolean not null default false,
  is_verified boolean not null default false,
  average_rating numeric(3, 2) not null default 0 check (average_rating between 0 and 5),
  completed_services integer not null default 0 check (completed_services >= 0),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table public.provider_services (
  provider_id uuid not null references public.provider_profiles(provider_id) on delete cascade,
  problem_type public.request_problem_type not null,
  primary key (provider_id, problem_type)
);

create table public.provider_locations (
  provider_id uuid primary key references public.provider_profiles(provider_id) on delete cascade,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  updated_at timestamptz not null default timezone('utc', now())
);

create table public.service_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete restrict,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  problem_type public.request_problem_type not null,
  description text not null check (char_length(trim(description)) >= 5),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  address_label text,
  status public.service_request_status not null default 'open',
  history_access_allowed boolean not null default false,
  opened_at timestamptz not null default timezone('utc', now()),
  closed_at timestamptz,
  updated_at timestamptz not null default timezone('utc', now())
);

create table public.request_attachments (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  uploaded_by uuid not null references public.profiles(id) on delete restrict,
  kind public.attachment_kind not null,
  storage_path text not null unique,
  created_at timestamptz not null default timezone('utc', now())
);

create table public.provider_offers (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  provider_id uuid not null references public.provider_profiles(provider_id) on delete restrict,
  travel_fee_cents integer not null default 0 check (travel_fee_cents >= 0),
  labor_fee_cents integer not null default 0 check (labor_fee_cents >= 0),
  parts_estimate_cents integer check (parts_estimate_cents >= 0),
  estimated_arrival_minutes integer check (estimated_arrival_minutes between 1 and 1440),
  notes text,
  status public.offer_status not null default 'submitted',
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  unique (request_id, provider_id)
);

create unique index provider_offers_one_accepted_offer_per_request
  on public.provider_offers (request_id)
  where status = 'accepted';

create table public.history_access_grants (
  request_id uuid not null references public.service_requests(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  provider_id uuid not null references public.provider_profiles(provider_id) on delete cascade,
  granted_by uuid not null references public.profiles(id) on delete restrict,
  granted_at timestamptz not null default timezone('utc', now()),
  revoked_at timestamptz,
  primary key (request_id, provider_id)
);

create table public.service_request_events (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  status public.service_request_status not null,
  note text,
  created_at timestamptz not null default timezone('utc', now())
);

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique references public.service_requests(id) on delete cascade,
  reviewer_id uuid not null references public.profiles(id) on delete restrict,
  provider_id uuid not null references public.provider_profiles(provider_id) on delete restrict,
  rating smallint not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default timezone('utc', now())
);

create index organization_members_user_id_idx on public.organization_members(user_id);
create index vehicles_organization_id_idx on public.vehicles(organization_id);
create index vehicles_assigned_driver_id_idx on public.vehicles(assigned_driver_id);
create index provider_profiles_available_idx on public.provider_profiles(is_available) where is_available;
create index provider_services_problem_type_idx on public.provider_services(problem_type);
create index service_requests_requester_id_idx on public.service_requests(requester_id);
create index service_requests_vehicle_id_idx on public.service_requests(vehicle_id);
create index service_requests_open_location_idx on public.service_requests(status, latitude, longitude)
  where status in ('open', 'collecting_offers');
create index provider_offers_provider_id_idx on public.provider_offers(provider_id);
create index provider_offers_request_id_idx on public.provider_offers(request_id);
create index request_events_request_id_idx on public.service_request_events(request_id, created_at desc);

create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();
create trigger organizations_set_updated_at before update on public.organizations
  for each row execute function public.set_updated_at();
create trigger vehicles_set_updated_at before update on public.vehicles
  for each row execute function public.set_updated_at();
create trigger provider_profiles_set_updated_at before update on public.provider_profiles
  for each row execute function public.set_updated_at();
create trigger service_requests_set_updated_at before update on public.service_requests
  for each row execute function public.set_updated_at();
create trigger provider_offers_set_updated_at before update on public.provider_offers
  for each row execute function public.set_updated_at();
