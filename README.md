# sos-veiculos-supabase

Migrations, Edge Functions e testes de contrato do projeto Supabase
`neutjtyhvgzdshlusmsv`.

```
config.toml      NÃO é lido pelo CLI — veja "A armadilha do config.toml"
functions/       Edge Functions (Deno)
migrations/      migrations SQL, aplicadas em ordem de nome
supabase/        functions e migrations como symlink, para o CLI enxergar
tests/           contratos em PGlite + testes de handler
```

## Deploy de Edge Functions

As funções que recebem chamada de **fora do Supabase** precisam da flag
explícita:

```bash
supabase functions deploy asaas-webhook asaas-operation-webhook \
  drain-push-outboxes send-push-notification --no-verify-jwt
```

As demais são publicadas normalmente:

```bash
supabase functions deploy <nome>
```

### Por que a flag é obrigatória

O `config.toml` declara `verify_jwt = false` para essas funções, **mas essa
declaração nunca é lida** (veja a seção seguinte). Sem a flag, o deploy aplica
o padrão do CLI, que é `verify_jwt = true`.

Com `verify_jwt = true`, o gateway do Supabase exige um JWT válido no header
`Authorization` e rejeita a requisição **antes de executar uma linha da
função**. Quem chama essas quatro não manda JWT nenhum:

- o Asaas manda o token dele em `asaas-access-token`;
- o scheduler da API manda o segredo em `apikey` — e o gateway ignora `apikey`.

O resultado é `401 UNAUTHORIZED_NO_AUTH_HEADER`, sem log do nosso lado, sem
erro visível em lugar nenhum. O webhook simplesmente para de receber eventos.

Foi exatamente o que aconteceu até 2026-10-20: o `asaas-webhook` nunca recebeu
um evento neste projeto. O bug de perda silenciosa de evento descrito na
auditoria de 17/10 estava encobrindo este, mais básico — não havia evento
chegando para ser perdido.

### Conferir depois de publicar

```bash
# o sed descarta o aviso de nova versão que o CLI anexa ao JSON
supabase functions list -o json | sed -n '/^\[/,/^\]/p' | python3 -c "
import sys, json
for f in sorted(json.load(sys.stdin), key=lambda x: x['slug']):
    print(f\"{f['slug']:34} verify_jwt={f['verify_jwt']}\")
"
```

Devem ficar com `verify_jwt=False`:

| Função | Quem chama | Como se autentica |
|---|---|---|
| `asaas-webhook` | Asaas | header `asaas-access-token` |
| `asaas-operation-webhook` | Asaas | header `asaas-access-token` |
| `drain-push-outboxes` | scheduler da API | header `apikey` com segredo próprio |
| `send-push-notification` | scheduler da API | header `apikey` com segredo próprio |

Todas as outras devem ficar com `verify_jwt=True`: elas usam `auth: 'user'` e
dependem do JWT do usuário logado, que o cliente Supabase já envia.

Um teste rápido de fora, sem credencial, distingue as duas camadas:

```bash
curl -s -X POST https://<ref>.supabase.co/functions/v1/asaas-webhook -d '{}'
```

- `{"code":"UNAUTHORIZED_NO_AUTH_HEADER"}` → o **gateway** barrou: `verify_jwt`
  está ligado e a função está inacessível.
- `{"message":"Não autorizado."}` → a **função** barrou, em português. É o
  comportamento correto.

## A armadilha do `config.toml`

O CLI lê **`supabase/config.toml`**. Neste repositório o arquivo está na raiz,
e `supabase/config.toml` nunca existiu. Logo, nada do que está nele tem efeito
— nem os blocos `[functions.*] verify_jwt`.

Isso foi verificado em 2026-10-20: com um `supabase/config.toml` inválido o CLI
aborta com erro de parse; sem o arquivo, ele segue adiante com os padrões.

O arquivo foi mantido na raiz de propósito. Ele é o template de
desenvolvimento local gerado pelo `supabase init` e contém valores que **não
valem para produção**, como `site_url = "http://127.0.0.1:3000"`. Movê-lo para
`supabase/config.toml` faria o `verify_jwt` passar a valer, mas armaria uma
armadilha pior:

> ⚠️ **Não rode `supabase config push` neste repositório.** Sem o arquivo no
> caminho esperado, o comando publica os **valores padrão** do CLI na
> configuração do projeto — incluindo `additional_redirect_urls`, o que quebra
> confirmação de conta e recuperação de senha. Ele não pede confirmação.

A configuração real do projeto é mantida pelo dashboard.

## Migrations

```bash
supabase migration list --linked   # só lê: mostra o que está pendente
supabase db push --linked          # aplica as pendentes
```

Migrations já aplicadas não são editadas: corrija sempre com uma nova.

## Testes

```bash
npm ci --prefix tests
npm test --prefix tests            # contratos de produto e segurança (PGlite)
node --test tests/asaas-functions.cjs
```

O type check das Edge Functions roda no CI e pode ser reproduzido sem instalar
o Deno:

```bash
npx deno@2 check functions/<nome>/index.ts
```

O comando exato está em `.github/workflows/quality.yml`. Ele verifica os
arquivos **em conjunto**, de propósito: um client Supabase sem contrato de tipo
assume o contrato da primeira função tipada do programa, e erros que só
aparecem nessa combinação passariam despercebidos arquivo a arquivo.
