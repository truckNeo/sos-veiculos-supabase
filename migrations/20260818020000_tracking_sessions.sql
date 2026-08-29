-- Phase 4: Tracking sessions for V2 architecture
-- Separates tracking sessions for auditing, debug, sequence namespacing and history.

create table public.service_request_tracking_sessions (
  id uuid primary key default gen_random_uuid(),

  request_id uuid not null references public.service_requests(id) on delete cascade,
  provider_id uuid not null references public.provider_profiles(provider_id) on delete cascade,

  stage text not null check (stage in ('provider_to_customer', 'on_site', 'towing_to_destination')),

  started_at timestamptz not null default timezone('utc', now()),
  ended_at timestamptz,
  end_reason text check (end_reason is null or end_reason in ('completed', 'cancelled', 'phase_changed', 'app_killed')),

  platform text check (platform is null or platform in ('android', 'ios')),
  app_version text,

  created_at timestamptz not null default timezone('utc', now())
);

create index tracking_sessions_request_idx
  on public.service_request_tracking_sessions(request_id, started_at desc);

create index tracking_sessions_provider_idx
  on public.service_request_tracking_sessions(provider_id);

-- RLS: participants can read their own sessions
alter table public.service_request_tracking_sessions enable row level security;

create policy "participants can read tracking sessions"
  on public.service_request_tracking_sessions for select to authenticated
  using (public.is_request_participant(request_id));

-- NestJS (service_role) does INSERT/UPDATE — no direct client writes
revoke all on public.service_request_tracking_sessions from authenticated;
grant select on public.service_request_tracking_sessions to authenticated;

