# Agenda, manutenção e colaborador — implantação

Implementação de 12/09/2026. Plano no workspace mobile: `docs/PLANO-AGENDA-MANUTENCAO-COLABORADOR.md`.

## Banco

A consulta remota de 12/09 encontrou o histórico aplicado até `20260830120000`. As três migrations de favoritos e as duas migrations de produto de setembro ainda não estavam aplicadas. Por isso, corrigimos as duas migrations **não aplicadas** de setembro para usar `product_notifications`; `app_notifications` permanece com o contrato de favoritos.

Ordem pendente: `20260831150000`, `20260831160000`, `20260831170000`, `20260906010000`, `20260906011000`, `20260912100000`. A última migration contém os contratos V2 de produto, permissões e proteção de chamados direcionados. Não editar migrations já aplicadas neste ambiente.

O teste `tests/check-schema.cjs` executa a sequência completa em PGlite e depois os contratos. Somente PostGIS, índices espaciais e serviços externos Auth/Storage são substituídos. Não mede concorrência entre conexões nem comprova Storage HTTP/push. Executar `npm ci --prefix tests` e `npm test --prefix tests`. O teste isolado anterior permanece em `tests/product-features.cjs`.

## Funções e API

Publicar `process-product-notifications` com verificação JWT da plataforma desabilitada; `auth: 'secret'` verifica a credencial administrativa dentro da função. Publicar `shared-vehicle-attachment` com `auth: 'user'`; o handler verifica o acesso antes e depois do download e não emite URLs assinadas. O endpoint retorna bytes com `Cache-Control: no-store` e MIME validado. Fotos já baixadas fora do controle do aplicativo não podem ser revogadas.

O scheduler está em `sos-veiculos-api/src/product-notifications.service.ts`. Depois de publicar funções/migrations, configurar somente no backend:

```
PRODUCT_NOTIFICATIONS_ENABLED=true
PRODUCT_NOTIFICATIONS_URL=https://<project>.supabase.co/functions/v1/process-product-notifications
PRODUCT_NOTIFICATIONS_SECRET_KEY=<chave secreta default aceita pelo @supabase/server>
```

O processo da API deve permanecer ativo. Executa a cada minuto, com timeout de 45 segundos e sem chamadas concorrentes na mesma instância. Os leases do banco coordenam instâncias distintas. Revisar logs `delivered`, `failed` e `exhausted`; falhas esgotadas precisam de investigação antes de reabrir tentativas. Nunca colocar a chave secreta no mobile ou em arquivos versionados.

## Compatibilidade e rollback

- Apps antigos continuam com favoritos e chamados avulsos. A conclusão antiga de manutenção retorna pedido de atualização; não pode avançar ciclos baseados em km usando somente data.
- Acessos compartilhados antigos preservam apenas dados básicos/planos, sem escopos adicionais e sem expiração automática do acesso já aceito.
- Desabilitar o scheduler e retirar entradas novas do app em caso de falha. Preservar registros/vínculos criados. Não reverter o banco apagando históricos.
- Não publicar app novo antes de migrations e funções. Homologar Auth/Storage reais, permissões negativas por API, duas conversões concorrentes, atualização concorrente de km e a jornada integrada em Android/iOS.
- Esta documentação não constitui evidência de deploy ou homologação; conferir o registro de implementação no mobile para os resultados efetivamente executados.
