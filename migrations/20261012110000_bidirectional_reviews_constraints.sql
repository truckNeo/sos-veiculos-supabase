-- Permite que os dois lados avaliem o mesmo atendimento.
--
-- A migration 20260830110000_bidirectional_reviews.sql adicionou driver_id,
-- mas manteve provider_id NOT NULL e request_id UNIQUE. Com isso a avaliação
-- do prestador sobre o motorista nunca foi gravada: faltava provider_id e,
-- mesmo com ele, a unique por chamado colidia com a avaliação do motorista.
--
-- Modelo de dados, que é o já assumido pelas consultas do app
-- (src/providers/providerReviews.ts e src/reviews/driverReviews.ts):
--   motorista -> prestador : provider_id preenchido, driver_id nulo
--   prestador -> motorista : driver_id preenchido, provider_id nulo
-- Por isso provider_id passa a ser nullable e um CHECK garante que exatamente
-- um dos dois esteja preenchido. Sem esse CHECK, uma avaliação do prestador
-- que trouxesse provider_id apareceria na aba "Recebidas" dele mesmo.

alter table public.reviews
  alter column provider_id drop not null;

-- A unique de request_id é de coluna, então o nome é gerado pelo Postgres.
-- O bloco procura qualquer unique que cubra exatamente (request_id), em vez
-- de confiar no nome, porque o estado do banco remoto não foi conferido.
do $$
declare
  constraint_name text;
begin
  select con.conname into constraint_name
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace nsp on nsp.oid = rel.relnamespace
  where nsp.nspname = 'public'
    and rel.relname = 'reviews'
    and con.contype = 'u'
    and con.conkey = array[
      (select attnum from pg_attribute
        where attrelid = con.conrelid and attname = 'request_id')
    ]
  limit 1;

  if constraint_name is not null then
    execute format('alter table public.reviews drop constraint %I', constraint_name);
  end if;
end;
$$;

-- Um atendimento aceita no máximo uma avaliação por autor.
alter table public.reviews
  drop constraint if exists reviews_request_reviewer_key;
alter table public.reviews
  add constraint reviews_request_reviewer_key unique (request_id, reviewer_id);

-- Exatamente um lado avaliado por linha.
alter table public.reviews
  drop constraint if exists reviews_single_target_check;
alter table public.reviews
  add constraint reviews_single_target_check
  check ((provider_id is not null) <> (driver_id is not null));

-- Funções de liberação de pagamento gravam a avaliação do motorista com
-- `on conflict (request_id) do nothing`. Sem a unique de coluna, esse ON
-- CONFLICT não encontra índice correspondente e a liberação passaria a falhar
-- em runtime com "no unique or exclusion constraint matching".
--
-- O alvo é reescrito a partir da definição viva, em vez de recriar as funções
-- aqui: elas carregam regra financeira (repasse, comissão, métricas) que não
-- deve ser duplicada nesta migration e sair de sincronia.
do $$
declare
  fn record;
  occurrences integer;
  rewritten integer := 0;
begin
  for fn in
    select p.oid, p.proname, pg_get_functiondef(p.oid) as definition, p.prosrc
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosrc ilike '%on conflict (request_id)%'
      and p.prosrc ilike '%reviews%'
  loop
    -- Só reescreve quando há exatamente uma ocorrência, para não trocar por
    -- engano um ON CONFLICT de outra tabela dentro da mesma função.
    occurrences := (length(fn.prosrc) - length(replace(fn.prosrc, 'on conflict (request_id)', ''))) /
                   length('on conflict (request_id)');
    if occurrences <> 1 then
      raise exception 'Função %: % ocorrências de "on conflict (request_id)"; revise manualmente.',
        fn.proname, occurrences;
    end if;
    execute replace(fn.definition, 'on conflict (request_id)', 'on conflict (request_id, reviewer_id)');
    rewritten := rewritten + 1;
  end loop;

  raise notice 'Alvo de ON CONFLICT ajustado em % função(ões).', rewritten;

  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosrc ilike '%on conflict (request_id)%'
      and p.prosrc ilike '%reviews%'
  ) then
    raise exception 'Ainda há função referenciando a unique antiga de reviews.';
  end if;
end;
$$;
