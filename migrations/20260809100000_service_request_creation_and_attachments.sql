-- Abertura de chamado e anexos privados.
-- O aplicativo não recebe permissão de inserir chamados diretamente: a RPC cria
-- o chamado e seu primeiro evento de auditoria na mesma transação.

drop policy "vehicle participants can open request" on public.service_requests;

create or replace function public.open_service_request(
  p_vehicle_id uuid,
  p_problem_type public.request_problem_type,
  p_description text,
  p_latitude double precision,
  p_longitude double precision,
  p_address_label text default null
)
returns table (
  id uuid,
  vehicle_id uuid,
  status public.service_request_status,
  opened_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  current_requester_id uuid := auth.uid();
  target_vehicle_status public.vehicle_status;
  created_request public.service_requests;
  normalized_description text := trim(coalesce(p_description, ''));
  normalized_address text := nullif(trim(coalesce(p_address_label, '')), '');
begin
  if current_requester_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.profiles profile
    where profile.id = current_requester_id and profile.role = 'driver'
  ) then
    raise exception 'Somente motoristas podem abrir chamados.' using errcode = '42501';
  end if;

  if char_length(normalized_description) not between 5 and 2000 then
    raise exception 'Descreva o problema entre 5 e 2000 caracteres.' using errcode = '22023';
  end if;

  if p_latitude is null or p_latitude not between -90 and 90
    or p_longitude is null or p_longitude not between -180 and 180 then
    raise exception 'Informe uma localização válida para o chamado.' using errcode = '22023';
  end if;

  if normalized_address is not null and char_length(normalized_address) > 500 then
    raise exception 'O endereço pode ter no máximo 500 caracteres.' using errcode = '22023';
  end if;

  select vehicle.status
  into target_vehicle_status
  from public.vehicles vehicle
  where vehicle.id = p_vehicle_id
    and public.can_access_vehicle(vehicle.id)
  for update;

  if target_vehicle_status is null then
    raise exception 'Veículo não encontrado ou sem permissão de uso.' using errcode = 'P0001';
  end if;

  if target_vehicle_status <> 'active' then
    raise exception 'Selecione um veículo ativo antes de abrir um chamado.' using errcode = 'P0001';
  end if;

  insert into public.service_requests (
    requester_id,
    vehicle_id,
    problem_type,
    description,
    latitude,
    longitude,
    address_label,
    status
  ) values (
    current_requester_id,
    p_vehicle_id,
    p_problem_type,
    normalized_description,
    p_latitude,
    p_longitude,
    normalized_address,
    'open'
  ) returning * into created_request;

  insert into public.service_request_events (request_id, actor_id, status, note)
  values (created_request.id, current_requester_id, 'open', 'Chamado aberto pelo motorista.');

  return query
  select created_request.id, created_request.vehicle_id,
    created_request.status, created_request.opened_at;
end;
$$;

revoke all on function public.open_service_request(
  uuid, public.request_problem_type, text, double precision, double precision, text
) from public;
grant execute on function public.open_service_request(
  uuid, public.request_problem_type, text, double precision, double precision, text
) to authenticated;

-- O bucket é privado. O contrato de caminho é <usuario>/<chamado>/<arquivo>.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'request-attachments',
  'request-attachments',
  false,
  15728640,
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'audio/mp4', 'audio/m4a', 'audio/aac']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "requester can upload request attachment objects"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'request-attachments'
    and owner_id = auth.uid()::text
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (
      select 1
      from public.service_requests request
      where request.id::text = (storage.foldername(name))[2]
        and request.requester_id = auth.uid()
    )
  );

create policy "request participants can read attachment objects"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'request-attachments'
    and exists (
      select 1
      from public.service_requests request
      where request.id::text = (storage.foldername(name))[2]
        and public.is_request_participant(request.id)
    )
  );

create policy "requester can delete request attachment objects"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'request-attachments'
    and owner_id = auth.uid()::text
    and exists (
      select 1
      from public.service_requests request
      where request.id::text = (storage.foldername(name))[2]
        and request.requester_id = auth.uid()
    )
  );

drop policy "requester can add attachments" on public.request_attachments;
create policy "requester can add attachments"
  on public.request_attachments for insert to authenticated
  with check (
    uploaded_by = auth.uid()
    and storage_path like auth.uid()::text || '/' || request_id::text || '/%'
    and exists (
      select 1 from public.service_requests request
      where request.id = request_id and request.requester_id = auth.uid()
    )
  );
