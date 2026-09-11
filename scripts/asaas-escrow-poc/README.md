# PoC — Pagamento retido (marketplace) no sandbox do Asaas

Valida, só via API, o fluxo de pagamento retido do SOS Veículos:

> cliente aceita orçamento → **mecânico envia link de pagamento** → **cliente paga** →
> valor fica **retido** pela plataforma → serviço concluído e OK →
> **pagamento liberado** para o mecânico.

Só o caminho feliz — sem disputa/reembolso.

## O que a 1ª rodada de testes descobriu

| Hipótese | Resultado |
| --- | --- |
| "Split de pagamento" + "Conta Escrow" seguram o valor até liberar | ❌ **Não.** O split é executado no recebimento e o valor cai **disponível** na subconta do mecânico. A Conta Escrow só retém cobranças emitidas pela própria subconta, não créditos de split. (`GET /payments/{id}/escrow` → 404 na subconta; ver comando `escrow-probe`.) |
| Cobrança **sem split** + `POST /transfers` na liberação | ✅ **Sim.** 100% do líquido fica retido na conta da plataforma; o repasse ao mecânico é uma transferência manual pós-serviço. É o modelo do código Iugu atual. |

Então a PoC usa **cobrança sem split + transfer**.

## Como o Asaas implementa

| Etapa do app | Asaas |
| --- | --- |
| Mecânico é vendedor da plataforma | **Subconta** (`POST /accounts`) → `walletId` + `apiKey` |
| Subconta precisa poder receber repasse | **Autoaprovação de subcontas** ligada no sandbox (ver abaixo) → `general = APPROVED` |
| Mecânico envia o link | Cobrança PIX criada pela conta mestre (`POST /payments`), **sem split** → `invoiceUrl` + PIX copia-e-cola |
| Cliente paga | Sandbox: `POST /sandbox/payment/{id}/confirm` |
| Valor retido | Cai 100% do `netValue` no saldo da **conta mestre** (a plataforma) |
| Serviço OK → liberar | `POST /transfers` — sandbox: `{ value, walletId }` (interna); produção: `{ value, operationType: "PIX", pixAddressKey }` |
| Comissão | A plataforma transfere menos que o bruto; a diferença fica no saldo dela |
| Autorizar o repasse | A transferência volta `authorized:false` / `PENDING`: a conta da plataforma tem **autorização de ações críticas** (vale para PIX e walletId). Concluir com token `000000` no painel, OU configurar o **webhook de validação de operações** (Configurações → Segurança) que devolve `{"status":"APPROVED"}` — é o caminho de automação em produção |

### Repasse ao mecânico — o que funciona onde

| Rota | Sandbox | Observação |
| --- | --- | --- |
| `POST /transfers { walletId }` (interna Asaas→Asaas, `operationType: INTERNAL`) | ✅ **funciona** (`DONE`, gera comprovante, credita o saldo da subconta) | mecanismo correto quando o mecânico é subconta; instantânea e sem tarifa |
| `POST /transfers { operationType: PIX, pixAddressKey }` | ❌ a subconta sandbox **não registra chave PIX** (`"não está totalmente aprovada para utilizar o Pix"` — falta prova de vida, não simulável) | em produção a subconta real faz prova de vida no onboarding e isso passa a funcionar |
| `POST /transfers { operationType: PIX, bankAccount }` p/ a conta bancária fake da subconta | ❌ `status: FAILED` — `"Falha ao processar a transferência."` | conta bancária fictícia não resolve PIX no sandbox |

Por isso o script faz o repasse por **`walletId` interno** no sandbox (e usa a chave PIX
automaticamente se ela existir — caminho de produção).

## Pré-requisitos no painel sandbox (uma vez)

1. Conta mestre precisa ser **Pessoa Jurídica (CNPJ)** — CPF não cria subconta.
2. Em **Minha conta → Configurações → Sandbox**, ligar **as duas** opções:
   - **BaaS para subcontas**
   - **Autoaprovação de subcontas**

   Sem isso, a subconta fica `documentation: PENDING` / `general: PENDING` e **não recebe
   `transfers`** (o script cadastra conta bancária e tenta enviar documento sozinho, mas o
   documento de identificação *não* pode ser enviado via API — só pelo link de onboarding
   ou pela autoaprovação do sandbox). Subcontas criadas *depois* de ligar nascem aprovadas.
3. Cadastrar uma **chave PIX** na conta mestre (para o `pixQrCode`; a `invoiceUrl` funciona sem isso).

## Rodando

Requer **Node >= 22**.

```sh
cd scripts/asaas-escrow-poc
cp .env.example .env      # cole a API key sandbox da conta mestre (PJ) em ASAAS_API_KEY

node --env-file=.env asaas-escrow-poc.ts whoami   # confere que a conta é JURIDICA
node --env-file=.env asaas-escrow-poc.ts all      # fluxo completo

# passo a passo:
#   setup-provider  create-customer  create-charge  link  pay  status  release  balance
# utilitários: approve-provider  escrow-probe  webhook-selftest  state  reset
```

`.asaas-poc-state.json` guarda os IDs gerados (subconta, walletId, apiKey da subconta,
cobrança, transfer) para rodar passos isolados. Está no `.gitignore` junto do `.env`.
`reset` apaga só esse arquivo — o que foi criado no sandbox permanece.

## Autorizar os repasses sem token manual (webhook de validação)

Toda transferência da conta da plataforma volta `authorized: false` / `PENDING` porque a
conta tem **autorização de ações críticas**. Manualmente: painel → Transferências → abrir →
token `000000`. Automático: o **webhook de validação de operações** — implementado em
`functions/asaas-operation-webhook/`.

```sh
# 1. deploy da função
supabase functions deploy asaas-operation-webhook

# 2. segredo (mesmo valor será colado no painel Asaas)
supabase secrets set ASAAS_OPERATION_WEBHOOK_TOKEN=<um token forte>
#   opcionais: ASAAS_OPERATION_WEBHOOK_MAX_VALUE=5000  ASAAS_OPERATION_WEBHOOK_ALLOWED_OPS=PIX,INTERNAL

# 3. painel Asaas sandbox → Integrações → Mecanismos de segurança:
#      URL   = https://<project>.supabase.co/functions/v1/asaas-operation-webhook
#      Token = <o mesmo ASAAS_OPERATION_WEBHOOK_TOKEN>

# 4. testar o endpoint isoladamente (defina ASAAS_WEBHOOK_URL + ASAAS_OPERATION_WEBHOOK_TOKEN no .env)
node --env-file=.env asaas-escrow-poc.ts webhook-selftest   # espera 200 {"status":"APPROVED"}
```

~5s após cada `POST /transfers` o Asaas chama a função; ela responde `{"status":"APPROVED"}`
(para `TRANSFER` dentro do teto e dos `operationType` permitidos) e a transferência nasce
`authorized: true` e liquida sozinha (`DONE`). Regras: recusa tudo que não for `TRANSFER`,
acima do teto, ou `operationType` fora da lista. O `TODO` no código marca onde plugar a
conferência contra a tabela de repasses quando a integração Asaas real existir.

> ✅ **Funciona no sandbox** (testado 2026-09-10: transfer `authorized:true` → `DONE`,
> mecânico creditado, hit `200` do Asaas visível nos logs da Edge Function). Só habilitar
> a tela **"Validação de saque via Webhook"** (Situação: Habilitado) com URL + token, e o
> token do painel tem que ser **byte a byte** igual ao secret `ASAAS_OPERATION_WEBHOOK_TOKEN`.
> Se o token não bater, o Asaas recebe `401`, tenta 3x e **cancela** a transferência.
>
> Dica: o *Edit* de secret no painel Supabase tende a misturar o valor antigo — se precisar
> trocar, **delete e adicione de novo**. Dá pra conferir o valor do secret sem vê-lo: ele é
> guardado como SHA-256 cru (`GET api.supabase.com/v1/projects/{ref}/secrets`, campo `value`).

## Webhook de notificação de eventos

Tela diferente (`Integrações → Webhooks`) — só **avisa**, não autoriza. Implementado em
`functions/asaas-webhook/` (hoje valida o token, loga e responde 200; os `TODO` marcam
onde reagir a cada evento).

```sh
supabase functions deploy asaas-webhook
supabase secrets set ASAAS_WEBHOOK_TOKEN=<token forte>   # ≠ do token do outro webhook
```

Painel Asaas sandbox → Integrações → Webhooks → Adicionar Webhook:

| Campo | Valor |
| --- | --- |
| Nome | `sos-veiculos-eventos` |
| URL | `https://<project>.supabase.co/functions/v1/asaas-webhook` |
| E-mail | seu e-mail |
| Versão da API | a mais recente (v3) |
| Token de autenticação | **Gerar Token** e usar esse valor em `ASAAS_WEBHOOK_TOKEN` (ou colar aqui o que você definiu) |
| Tipo de envio | Sequencialmente |
| Fila de sincronização | ativada |
| Eventos | Cobranças: `PAYMENT_RECEIVED`, `PAYMENT_CONFIRMED` · Transferências: `TRANSFER_DONE`, `TRANSFER_FAILED` · Situação da conta: `GENERAL_APPROVAL_APPROVED` |

> A URL precisa responder `200` no momento de salvar (senão o Asaas cria já
> "interrompido"). Faça o deploy da função **antes** de salvar aqui.

## Próximo passo (integração)

Ao portar para o app, espelhar a forma do módulo Iugu já existente
(`provider_iugu_accounts`, `provider_wallet_entries`, `service_provider_transfers`,
edge functions `create-iugu-pix` / `iugu-webhook` / `release-iugu-payment`), trocando:

- criação da subconta (modelo White Label / Cliente BaaS) + conta bancária + verificação `general = APPROVED`
- `POST /payments` (PIX, sem split) + webhook `PAYMENT_RECEIVED` → marca `held`
- `POST /transfers` na liberação com review → marca `available`
- **webhook de validação de operações** devolvendo `APPROVED` para autorizar os repasses
  automaticamente (equivale ao `signedIuguFetch` com RSA que o código Iugu usa hoje)
