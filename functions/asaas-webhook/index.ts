import {withSupabase} from 'npm:@supabase/server';

/**
 * Webhook de NOTIFICAÇÃO de eventos do Asaas (Integrações → Webhooks).
 *
 * Só recebe avisos; não autoriza nada (isso é o `asaas-operation-webhook`).
 * Aqui é onde a integração real vai reagir aos eventos — hoje só valida o token,
 * loga e responde 200. Os pontos de conexão com o banco estão marcados com TODO.
 *
 * Configuração no painel Asaas (sandbox):
 *   Integrações → Webhooks → Adicionar Webhook
 *     URL           = https://<project>.supabase.co/functions/v1/asaas-webhook
 *     Token         = valor de ASAAS_WEBHOOK_TOKEN (chega no header asaas-access-token)
 *     Tipo de envio = Sequencialmente
 *     Eventos       = PAYMENT_RECEIVED, PAYMENT_CONFIRMED,
 *                     TRANSFER_DONE, TRANSFER_FAILED,
 *                     ACCOUNT_STATUS_GENERAL_APPROVAL_APPROVED
 *
 * IMPORTANTE: o Asaas espera 200 rápido. Se responder erro (ou demorar), ele
 * re-tenta e depois "interrompe a fila" — nenhum evento novo chega até religar.
 * Por isso: validar, enfileirar/processar o mínimo, responder 200. Trabalho
 * pesado deve ir para uma fila/So worker, não no caminho da resposta.
 */

const secureEqual = (a: string, b: string) => {
  if (a.length !== b.length || a.length === 0) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
};

type AsaasEvent = {
  id?: string;          // id do evento (use para idempotência)
  event: string;        // PAYMENT_RECEIVED, TRANSFER_DONE, ...
  dateCreated?: string;
  payment?: {
    id?: string;
    status?: string;
    value?: number;
    netValue?: number;
    externalReference?: string | null;
    customer?: string;
  };
  transfer?: {
    id?: string;
    status?: string;
    value?: number;
    failReason?: string | null;
    externalReference?: string | null;
    operationType?: string;
  };
  account?: {
    id?: string;
    walletId?: string;
  };
};

export default {
  fetch: withSupabase({auth: 'none'}, async (request, _ctx) => {
    const expected = (Deno.env.get('ASAAS_WEBHOOK_TOKEN') ?? '').trim();
    if (!expected) {
      console.error('asaas-webhook: ASAAS_WEBHOOK_TOKEN não configurado.');
      return Response.json({message: 'Webhook não configurado.'}, {status: 503});
    }
    if (!secureEqual((request.headers.get('asaas-access-token') ?? '').trim(), expected)) {
      return Response.json({message: 'Não autorizado.'}, {status: 401});
    }

    let body: AsaasEvent;
    try {
      body = await request.json() as AsaasEvent;
    } catch {
      return Response.json({message: 'Payload inválido.'}, {status: 400});
    }

    // TODO(idempotência): registrar body.id numa tabela `asaas_webhook_events`
    // (unique) e sair cedo se já processado — o Asaas pode reenviar o mesmo evento.

    console.log(`asaas-webhook: ${body.event} evt=${body.id ?? '-'} ` +
      `payment=${body.payment?.id ?? '-'} transfer=${body.transfer?.id ?? '-'} account=${body.account?.id ?? '-'}`);

    switch (body.event) {
      case 'PAYMENT_RECEIVED':
      case 'PAYMENT_CONFIRMED': {
        // Cliente pagou a cobrança PIX → o valor está retido na conta da plataforma.
        // TODO: rpc confirm_asaas_charge_payment(payment.id) → marca a charge 'paid'
        //   e cria a wallet_entry 'held'; usar payment.externalReference para achar o registro.
        break;
      }
      case 'TRANSFER_DONE': {
        // Repasse ao mecânico liquidou.
        // TODO: marcar service_provider_transfer 'completed' + wallet_entry 'available'
        //   (match por transfer.externalReference).
        break;
      }
      case 'TRANSFER_FAILED': {
        // Repasse falhou (ex.: chave/conta inválida) — valor volta à plataforma.
        // TODO: marcar transfer 'manual_review' com transfer.failReason e alertar operação.
        console.warn(`asaas-webhook: TRANSFER_FAILED ${body.transfer?.id} — ${body.transfer?.failReason ?? 's/ motivo'}`);
        break;
      }
      case 'ACCOUNT_STATUS_GENERAL_APPROVAL_APPROVED': {
        // Subconta do mecânico aprovada → já pode receber repasses.
        // TODO: update provider_asaas_accounts set status='verified' where asaas_account_id = account.id
        break;
      }
      default:
        // Evento não tratado: ok, só ignora (mantém 200 para não interromper a fila).
        break;
    }

    return Response.json({received: true});
  }),
};
