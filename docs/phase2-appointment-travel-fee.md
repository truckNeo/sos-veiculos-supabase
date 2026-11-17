# Fase 2: cobrança da taxa de deslocamento do agendamento

Status: proposta para aprovação. Nada deste documento foi implementado.

## 1. Regras (já aprovadas)

- Só a taxa de deslocamento passa pelo app. A mão de obra é paga direto ao mecânico.
- A taxa é informada no mesmo passo em que o mecânico confirma o horário.
- Prazo de pagamento = o menor entre 12 h após a confirmação e 2 h antes do horário.
- Dinheiro retido no app até a liberação:
  - Mecânico vai até mim: liberada quando o motorista confirma a chegada.
  - Leva e traz: liberada quando o motorista confirma o recebimento do veículo na entrega.
- O prestador fica com 100% da taxa quando o deslocamento se completa (a comissão da plataforma segue o motor atual: 10%).
- Reembolso integral: motorista cancela antes de o mecânico sair, mecânico cancela, atraso recusado, ou mecânico passa de 30 min no local.
- Motorista cancela com o mecânico a caminho: taxa fica retida e o prestador pode abrir disputa.
- Oficina não tem taxa.

## 2. O que existe hoje (lido no código)

O motor financeiro é todo chaveado por `request_id` (chamado):

| Peça | Dependência de chamado |
|---|---|
| `service_payment_charges` | `request_id` e `offer_id` NOT NULL; UNIQUE `(request_id, kind)`; RLS pelo `service_requests.requester_id` |
| `provider_wallet_entries` | `request_id` NOT NULL, `charge_id` UNIQUE |
| `service_provider_transfers` | `request_id` NOT NULL e UNIQUE |
| `confirm_asaas_charge_payment` | cria a entrada `held` e escreve em `service_request_events` |
| `confirm_provider_arrival` | cria o repasse (10% de comissão) a partir das entradas `held` |
| `complete_dispatch_transfer` | exige `provider_arrival_confirmed_at` do chamado |
| `reconcileDispatchTransfer` (Edge) | lê o chamado e as cobranças `dispatch` por `request_id` |
| `create-asaas-pix` (Edge) | lê a cobrança por id, exige `kind='dispatch'` |

Peças que **já servem sem mudança**, porque só usam `asaas_payment_id`: o webhook `asaas-webhook` (`reconcilePayment` -> `confirm_asaas_charge_payment`), o fluxo Pix/cartão de `create-asaas-pix` (após ler a cobrança), `confirm-asaas-sandbox-payment`, a carteira (`my_wallet_summary`, saque), a conta Asaas do prestador (`provider_asaas_accounts`).

## 3. Opções avaliadas

**A. Chamado "contêiner"** (criar um `service_request` + `provider_offer` só para carregar a cobrança). Reaproveita tudo, mas o chamado dispara despacho a outros prestadores, fila de push, a trava de um atendimento ativo por veículo e as fases do fluxo de chamados. Teria que neutralizar cada um. Frágil: qualquer gatilho novo de chamado afeta agendamentos.

**B. Tabelas financeiras próprias do agendamento.** Isolado, mas duplica Pix, repasse, carteira e conciliação. Dobra a superfície onde um bug custa dinheiro.

**C. Dono polimórfico (recomendada).** Os três registros financeiros passam a pertencer a um chamado **ou** a um agendamento. Reaproveita Pix, webhook, carteira e repasse; muda só a chave de ligação.

## 4. Desenho da opção C

### 4.1 Esquema (migration 1, só estrutura)

- `service_payment_charges`: `request_id` e `offer_id` passam a nullable; nova coluna `appointment_id uuid references service_appointments(id) on delete restrict`; `check (num_nonnulls(request_id, appointment_id) = 1)`; `check (appointment_id is null or offer_id is null)`; índice único parcial `(appointment_id, kind) where appointment_id is not null`. O UNIQUE `(request_id, kind)` continua valendo (nulos não colidem).
- `provider_wallet_entries`: `request_id` nullable, `appointment_id` nova, mesmo check.
- `service_provider_transfers`: `request_id` nullable, `appointment_id` nova, mesmo check, índice único parcial `(appointment_id)`.
- RLS: nova policy de leitura por `service_appointments.driver_id = auth.uid()` para cobranças e repasses (as policies atuais continuam).
- `service_appointments`: `fee_charge_id`, `payment_due_at`, `fee_paid_at`, `fee_released_at`, `fee_refunded_at`.
- Nenhum dado existente muda. Dry-run antes; reversível (colunas novas e checks).

### 4.2 Funções SQL (migration 2)

| Função | Comportamento |
|---|---|
| `confirm_service_appointment` (altera) | Em modo com taxa, cria a cobrança `pending` (`kind='dispatch'`, `appointment_id`), define `payment_due_at` e avisa o motorista ("Pague a taxa até X"). Como no chamado, não exige conta Asaas `verified` na confirmação; a trava fica no pagamento (`create-asaas-pix`). |
| `confirm_asaas_charge_payment` (altera) | Se a cobrança é de agendamento: grava `fee_paid_at`, cria a entrada `held` com `appointment_id`, escreve na timeline do agendamento (não em `service_request_events`) e notifica o prestador. Ramo de chamado fica intacto. |
| `provider_appointment_action` (altera) | `heading` ("Estou a caminho") só com `fee_paid_at` preenchido, como já é feito nos chamados (`require_confirmed_payment_before_departure`). |
| `confirm_appointment_fee_release(p_id)` (nova, driver) | Valida o estágio (chegada no onsite, entrega no pickup), cria `service_provider_transfers` com `appointment_id` e comissão de 10%, marca `fee_released_at`. Idempotente. |
| `complete_dispatch_transfer` (altera) | Valida a chegada pelo dono (chamado ou agendamento). |
| `cancel/refuse/delay` em `driver_appointment_action` e `provider_appointment_action` (alteram) | Se há taxa paga e a regra é de reembolso integral, marcam `refund_pending` na cobrança; se o motorista cancela com `stage = 'heading'`, a taxa fica retida e o agendamento fica elegível a disputa. |
| `process_late_appointments` (altera) | Cobrança não paga em `payment_due_at` -> agendamento `expired` com motivo "taxa não paga" e push aos dois. Mecânico além de 30 min no local -> reembolso integral. |

### 4.3 Edge Functions

- `create-asaas-pix`: selecionar `appointment_id`; aceitar cobrança de agendamento; descrição "SOS Veículos - taxa de deslocamento"; checar que o chamador é o `driver_id` do agendamento.
- `_shared/dispatch-transfer.ts`: carregar o dono (chamado ou agendamento) e validar a confirmação pelo campo certo (`provider_arrival_confirmed_at` ou `fee_released_at`). Resto do repasse idêntico.
- `release-asaas-payment`: aceitar `appointmentId` e chamar `confirm_appointment_fee_release` antes de reconciliar o repasse.
- `refund-appointment-fee` (nova): `POST /payments/{id}/refund` do Asaas para cobranças com `refund_pending`, idempotente, conciliada pelo webhook `PAYMENT_REFUNDED` (já tratado por `record_payment_reversal`).
- `asaas-webhook`: sem mudança.

### 4.4 App

- Detalhe do agendamento (motorista), etapa "Pagar a taxa": QR/copia-e-cola reaproveitando a tela de pagamento de deslocamento dos chamados, com contagem até `payment_due_at`.
- Prestador: "Estou a caminho" desabilitado com a dica "Aguardando pagamento da taxa" até `fee_paid_at`.
- Motorista: "Confirmar chegada" (onsite) e "Confirmar recebimento" (pickup) passam a chamar `release-asaas-payment` e mostram o estado do repasse.
- `FEE_MODES_ENABLED` só vira `true` em produção depois da validação no sandbox (seção 6).

## 5. Riscos e como tratar

| Risco | Tratamento |
|---|---|
| `request_id` nullable quebra funções que fazem join por `request_id` | Lista fechada das 27 funções que citam as tabelas (seção 7); cada uma é auditada, as de chamado só ganham `where request_id is not null` quando necessário. Teste de contrato garante que o fluxo de chamado não muda. |
| Cobrança duplicada | UNIQUE parcial por `(appointment_id, kind)` e `claim_asaas_charge_checkout` já existente. |
| Repasse em ambiente errado (sandbox x produção) | Reaproveita as checagens `asaas_sandbox`/`isAsaasSandbox()` já existentes. |
| Valor preso (pago, mas agendamento cancelado) | Nunca cancelar com `fee_paid_at` sem passar pela regra de reembolso/retenção; teste de contrato cobre cada ramo. |
| Reembolso não está implementado | Entra na fase 2c; até lá o app **bloqueia** cancelar um agendamento com taxa paga e oferece só "falar com suporte". |

## 6. Ordem de entrega e validação

1. **2a, pagar e travar a saída.** Migration 1 e 2 (cobrança, confirmação, trava do "a caminho"), `create-asaas-pix` e a tela de pagamento. Teste: contrato PGlite + sandbox (`confirm-asaas-sandbox-payment`).
2. **2b, liberar.** `confirm_appointment_fee_release`, ajuste do repasse e do `release-asaas-payment`. Teste: sandbox ponta a ponta até `TRANSFER_DONE`.
3. **2c, desfazer.** Prazo vencido, reembolso e retenção com disputa. Teste: cada regra de cancelamento no sandbox.
4. Liberar `FEE_MODES_ENABLED` para usuários reais.

Cada etapa é um PR pequeno, migration com dry-run antes, e a validação no sandbox é feita com o Jefferson (a chave do Asaas chega mascarada para o assistente).

## 7. Funções a auditar na migration

`begin_asaas_dispute_settlement`, `begin_asaas_payment_release`, `claim_asaas_charge_checkout`, `claim_asaas_provider_transfer`, `claim_asaas_withdrawal`, `complete_asaas_payment_release_with_review`, `complete_dispatch_transfer`, `confirm_asaas_charge_payment`, `confirm_provider_arrival`, `confirm_service_charge_payment`, `decide_service_dispute`, `is_dispatch_payment_confirmed`, `list_open_service_disputes`, `mark_asaas_transfer_manual_review`, `mark_service_charge_asaas_checkout`, `mark_service_charge_checkout`, `my_wallet_summary`, `prevent_paid_dispatch_cancellation`, `process_overdue_dispatch_arrivals`, `provider_cancel_dispatch`, `record_payment_reversal`, `release_service_payment_with_review`, `request_manual_provider_arrival`, `reserve_pix_withdrawal`, `select_dispatch_offer`, `submit_final_service_quote`, `transition_service_request_status`.

## 8. Decisões que preciso de você

1. Aprova a opção C (dono polimórfico)?
2. Cobrança só por Pix na taxa, ou também cartão (o `create-asaas-pix` já suporta)? Sugestão: só Pix.
3. Pode o prestador confirmar uma taxa antes de ter a conta Asaas aprovada? Sugestão: não, a confirmação com taxa é recusada até a conta estar `verified`.
4. Até o reembolso (2c) existir, bloquear o cancelamento de agendamento com taxa paga? Sugestão: sim.

## 9. Status de implementação

- 2a (cobrança e trava da saída), 2b (repasse na chegada/entrega) e 2c (prazo, reembolso, retenção e disputa) implementadas e aplicadas.
- Retenção: motorista cancela com o mecânico a caminho (e o mecânico dentro de 30 min do horário) = taxa retida; o prestador tem 48 h para `open_appointment_fee_dispute`; sem disputa a taxa volta ao motorista. A decisão da disputa é `decide_appointment_fee_dispute(id, 'provider'|'driver')` (service_role, sem tela de administração ainda).
- Reembolso: `refund-appointment-fee` (app, após cancelar) e `process-appointment-fees` (pg_cron, quando há pendência) chamam `POST /payments/{id}/refund`; o webhook `PAYMENT_REFUNDED` fecha a carteira.
- Pendente: validar tudo no sandbox do Asaas e só então ligar `FEE_MODES_ENABLED` para usuários reais.
