-- Amplia o raio máximo de atendimento do prestador de 500 km para 700 km.
do $$
declare c record;
begin
  for c in
    select con.conname
    from pg_constraint con
    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = any (con.conkey)
    where con.conrelid = 'public.provider_profiles'::regclass
      and con.contype = 'c'
      and a.attname = 'service_radius_km'
  loop
    execute format('alter table public.provider_profiles drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.provider_profiles
  add constraint provider_profiles_service_radius_km_check
  check (service_radius_km between 1 and 700);

create or replace function public.save_provider_business_profile(
  p_business_name text,
  p_legal_name text,
  p_postal_code text,
  p_address_street text,
  p_address_number text,
  p_address_complement text,
  p_address_neighborhood text,
  p_address_city text,
  p_address_state text,
  p_service_radius_km integer,
  p_is_available boolean,
  p_services public.request_problem_type[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_provider_id uuid := auth.uid();
  normalized_services public.request_problem_type[];
begin
  if current_provider_id is null or not exists (
    select 1 from public.provider_profiles where provider_id = current_provider_id
  ) then
    raise exception 'Apenas prestadores podem atualizar este perfil.' using errcode = '42501';
  end if;

  select array_agg(distinct service)
  into normalized_services
  from unnest(coalesce(p_services, '{}'::public.request_problem_type[])) as service;

  if nullif(trim(p_business_name), '') is null
    or nullif(trim(p_legal_name), '') is null
    or regexp_replace(coalesce(p_postal_code, ''), '[^0-9]', '', 'g') !~ '^[0-9]{8}$'
    or nullif(trim(p_address_street), '') is null
    or nullif(trim(p_address_number), '') is null
    or nullif(trim(p_address_neighborhood), '') is null
    or nullif(trim(p_address_city), '') is null
    or upper(trim(coalesce(p_address_state, ''))) !~ '^[A-Z]{2}$' then
    raise exception 'Preencha os dados completos do estabelecimento.' using errcode = '22023';
  end if;

  if p_service_radius_km is null or p_service_radius_km not between 1 and 700 then
    raise exception 'Informe um raio de atendimento entre 1 e 700 km.' using errcode = '22023';
  end if;

  if normalized_services is null or cardinality(normalized_services) = 0 then
    raise exception 'Selecione pelo menos uma especialidade.' using errcode = '22023';
  end if;

  update public.provider_profiles
  set
    business_name = trim(p_business_name),
    legal_name = trim(p_legal_name),
    postal_code = regexp_replace(p_postal_code, '[^0-9]', '', 'g'),
    address_street = trim(p_address_street),
    address_number = trim(p_address_number),
    address_complement = nullif(trim(p_address_complement), ''),
    address_neighborhood = trim(p_address_neighborhood),
    address_city = trim(p_address_city),
    address_state = upper(trim(p_address_state)),
    service_radius_km = p_service_radius_km,
    is_available = coalesce(p_is_available, false)
  where provider_id = current_provider_id;

  delete from public.provider_services where provider_id = current_provider_id;

  insert into public.provider_services (provider_id, problem_type)
  select current_provider_id, service
  from unnest(normalized_services) as service;
end;
$$;
