import {withSupabase} from 'npm:@supabase/server';

/**
 * Webhook de NOTIFICAÇÃO de eventos do Asaas (Integrações → Webhooks).
 * Só recebe avisos; não autoriza nada (isso é o `asaas-operation-webhook`).
 *
 * Configuração no painel Asaas:
 *   Integrações → Webhooks → Adicionar Webhook
 *     URL           = https://<project>.supabase.co/functions/v1/asaas-webhook
 *     Token         = valor de ASAAS_WEBHOOK_TOKEN (chega no header asaas-access-token)
 *     Tipo de envio = Sequencialmente
 *     Eventos       = PAYMENT_RECEIVED, PAYMENT_CONFIRMED,
 *                     TRANSFER_DONE, TRANSFER_FAILED,
 *                     ACCOUNT_STATUS_GENERAL_APPROVAL_APPROVED,
 *                     ACCOUNT_STATUS_GENERAL_APPROVAL_REJECTED
 *
 * O Asaas espera 200 rápido; se responder erro (ou demorar) ele re-tenta e
 * depois "interrompe a fila" — nenhum evento novo chega até religar.
 */

const secureEqual = (a: string, b: string) => {
  if (a.length !== b.length || a.length === 0) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
};

type AsaasEvent = {
  id?: string;
  event: string;
  payment?: {id?: string; status?: string; pixTransaction?: {endToEndIdentifier?: string} | null};
  transfer?: {id?: string; status?: string; failReason?: string | null; externalReference?: string | null};
  account?: {id?: string};
};

export default {
  fetch: withSupabase({auth: 'none'}, async (request, ctx) => {
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

    console.log(`asaas-webhook: ${body.event} evt=${body.id ?? '-'} payment=${body.payment?.id ?? '-'} transfer=${body.transfer?.id ?? '-'} account=${body.account?.id ?? '-'}`);

    switch (body.event) {
      case 'PAYMENT_RECEIVED':
      case 'PAYMENT_CONFIRMED': {
        if (body.payment?.id) {
          const {error} = await ctx.supabaseAdmin.rpc('confirm_asaas_charge_payment', {
            p_asaas_payment_id: body.payment.id,
            p_end_to_end_id: body.payment.pixTransaction?.endToEndIdentifier ?? null,
          });
          if (error) console.error('asaas-webhook: confirm_asaas_charge_payment falhou', error.message);
        }
        break;
      }
      case 'TRANSFER_DONE': {
        // Cobre tanto o repasse (conta mestre -> subconta) quanto o saque
        // (subconta -> banco do prestador) — cada tabela só casa um dos dois.
        if (body.transfer?.id) {
          await ctx.supabaseAdmin.from('service_provider_transfers')
            .update({status: 'completed', completed_at: new Date().toISOString()})
            .eq('asaas_transfer_id', body.transfer.id).eq('status', 'processing');
          await ctx.supabaseAdmin.from('provider_asaas_withdrawals')
            .update({status: 'paid'})
            .eq('asaas_transfer_id', body.transfer.id).eq('status', 'requested');
        }
        break;
      }
      case 'TRANSFER_FAILED':
      case 'TRANSFER_CANCELLED': {
        if (body.transfer?.id) {
          console.warn(`asaas-webhook: ${body.event} ${body.transfer.id} — ${body.transfer.failReason ?? 's/ motivo'}`);
          await ctx.supabaseAdmin.rpc('mark_asaas_transfer_manual_review', {
            p_transfer_id: body.transfer.externalReference ?? body.transfer.id,
            p_reason: body.transfer.failReason ?? `Transferência ${body.event}.`,
          });
          await ctx.supabaseAdmin.from('provider_asaas_withdrawals')
            .update({status: 'failed'})
            .eq('asaas_transfer_id', body.transfer.id).eq('status', 'requested');
        }
        break;
      }
      case 'ACCOUNT_STATUS_GENERAL_APPROVAL_APPROVED': {
        if (body.account?.id) {
          await ctx.supabaseAdmin.from('provider_asaas_accounts')
            .update({status: 'verified', verified_at: new Date().toISOString(), rejection_reason: null})
            .eq('asaas_account_id', body.account.id);
        }
        break;
      }
      case 'ACCOUNT_STATUS_GENERAL_APPROVAL_REJECTED': {
        if (body.account?.id) {
          await ctx.supabaseAdmin.from('provider_asaas_accounts')
            .update({status: 'rejected', rejection_reason: 'Cadastro recusado pelo Asaas — revise os documentos.'})
            .eq('asaas_account_id', body.account.id);
        }
        break;
      }
      default:
        break;
    }

    return Response.json({received: true});
  }),
};
