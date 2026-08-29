-- Atualiza o motorista assim que uma proposta de deslocamento é enviada,
-- retirada ou selecionada, sem alterar a regra de seleção existente.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'provider_offers'
  ) then
    alter publication supabase_realtime add table public.provider_offers;
  end if;
end;
$$;
