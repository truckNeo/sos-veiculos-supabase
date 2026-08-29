-- Phase 4: Evolve service_request_locations for V2
-- Adds session, sequence, telemetry fields, geography column, and idempotency.
-- Preserves existing columns (latitude, longitude, accuracy_meters, expires_at)
-- for backward compatibility during migration.

-- 1. Add tracking session reference (nullable for legacy rows)
alter table public.service_request_locations
  add column tracking_session_id uuid references public.service_request_tracking_sessions(id) on delete set null;

-- 2. Add sequence for idempotency and out-of-order detection
alter table public.service_request_locations
  add column sequence integer check (sequence is null or sequence >= 0);

-- 3. Add telemetry fields
alter table public.service_request_locations
  add column speed_mps double precision check (speed_mps is null or speed_mps >= 0),
  add column heading_degrees double precision check (heading_degrees is null or (heading_degrees >= 0 and heading_degrees < 360)),
  add column altitude_meters double precision;

-- 4. Add server-side received timestamp (distinct from captured_at = device time)
alter table public.service_request_locations
  add column received_at timestamptz;

-- 5. Add PostGIS geography column for spatial queries
alter table public.service_request_locations
  add column location extensions.geography(Point, 4326);

-- 6. Backfill geography from existing lat/lon for existing rows
update public.service_request_locations
  set location = extensions.ST_SetSRID(extensions.ST_MakePoint(longitude, latitude), 4326)::extensions.geography
  where location is null and latitude is not null and longitude is not null;

-- 7. Unique constraint: one sequence per session (idempotency)
create unique index tracking_location_session_sequence_uniq
  on public.service_request_locations(tracking_session_id, sequence)
  where tracking_session_id is not null and sequence is not null;

-- 8. Index for session-based history queries
create index tracking_location_session_captured_idx
  on public.service_request_locations(tracking_session_id, captured_at)
  where tracking_session_id is not null;

-- 9. Geospatial index for future distance/proximity queries on history
create index tracking_location_geo_idx
  on public.service_request_locations using gist(location);

-- 10. Mark expires_at as legacy (comment, no drop)
comment on column public.service_request_locations.expires_at
  is 'LEGACY: Used by V1 tracking to filter stale positions. V2 uses Redis TTL. Do not remove until V1 is fully decommissioned.';

-- 11. Mark record_service_request_location RPC as deprecated
comment on function public.record_service_request_location(uuid, double precision, double precision, double precision)
  is 'DEPRECATED: V1 tracking RPC. V2 uses WebSocket via NestJS. Preserved for backward compatibility. Remove after V1 decommission.';

