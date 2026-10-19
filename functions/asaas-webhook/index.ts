import {withSupabase} from 'npm:@supabase/server@1.4.1';
import type {AsaasDatabase} from '../_shared/asaas-database.ts';

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
 *
 * Por causa disso, antes se respondia 200 sempre, e o erro da confirmação era
 * só logado: o evento era dado como entregue e nunca voltava. Pagamento ou
 * repasse podiam ficar sem conciliação por uma falha momentânea de banco.
 *
 * Agora o evento é gravado em asaas_webhook_events antes de ser processado.
 * Com ele persistido, responder erro é seguro e desejável: a reentrega do
 * Asaas é a fila de retry, e o domínio já é idempotente
 * (confirm_asaas_charge_payment não tem efeito em cobrança já paga). As
 * respostas passam a ser:
 *
 *   503 — não conseguimos nem registrar o evento. O Asaas precisa reentregar;
 *         pausar a fila é correto, porque nada seria processável agora.
 *   500 — registrado, mas o processamento falhou. O Asaas reentrega e a
 *         segunda tentativa conclui.
 *   200 — processado, ou reentrega de evento já processado.
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
  fetch: withSupabase<AsaasDatabase>({auth: 'none'}, async (request, ctx) => {
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

    // Sem id do evento, o par tipo+referência é o que separa duas
    // notificações distintas; repetir a mesma combinação é reentrega.
    const reference = body.payment?.id ?? body.transfer?.id ?? body.account?.id ?? 'sem-referencia';
    const dedupeKey = (body.id ?? '').trim() || `${body.event}:${reference}`;

    const recorded = await ctx.supabaseAdmin.rpc('record_asaas_webhook_event', {
      p_dedupe_key: dedupeKey,
      p_event_type: body.event,
      p_payload: body,
    });
    const entry = recorded.data?.[0];
    if (recorded.error || !entry) {
      console.error(`asaas-webhook: evento ${dedupeKey} não registrado — ${recorded.error?.message ?? 'sem retorno'}`);
      return Response.json({message: 'Evento não registrado.'}, {status: 503});
    }
    if (entry.already_processed) {
      console.log(`asaas-webhook: ${dedupeKey} já processado; reentrega ignorada.`);
      return Response.json({received: true, duplicate: true});
    }

    // Toda operação abaixo é checada. Antes só a confirmação era logada, e os
    // updates de transferência, saque e conta falhavam em silêncio.
    const failures: string[] = [];
    const check = (label: string, error: {message?: string} | null | undefined) => {
      if (error) failures.push(`${label}: ${error.message ?? 'erro sem mensagem'}`);
    };

    switch (body.event) {
      case 'PAYMENT_RECEIVED':
      case 'PAYMENT_CONFIRMED': {
        if (body.payment?.id) {
          const {error} = await ctx.supabaseAdmin.rpc('confirm_asaas_charge_payment', {
            p_asaas_payment_id: body.payment.id,
            p_end_to_end_id: body.payment.pixTransaction?.endToEndIdentifier ?? null,
          });
          check('confirm_asaas_charge_payment', error);
        }
        break;
      }
      case 'TRANSFER_DONE': {
        // Registra o id para conciliação, sem concluir o ledger antes da avaliação.
        // Cobre tanto o repasse (conta mestre -> subconta) quanto o saque
        // (subconta -> banco do prestador) — cada tabela só casa um dos dois.
        if (body.transfer?.id) {
          check('service_provider_transfers', (await ctx.supabaseAdmin.from('service_provider_transfers')
            .update({asaas_transfer_id: body.transfer.id})
            .eq('id', body.transfer.externalReference ?? '00000000-0000-0000-0000-000000000000')
            .in('status', ['processing', 'manual_review'])).error);
          check('provider_asaas_withdrawals', (await ctx.supabaseAdmin.from('provider_asaas_withdrawals')
            .update({status: 'paid'})
            .eq('asaas_transfer_id', body.transfer.id).eq('status', 'requested')).error);
        }
        break;
      }
      case 'TRANSFER_FAILED':
      case 'TRANSFER_CANCELLED': {
        if (body.transfer?.id) {
          console.warn(`asaas-webhook: ${body.event} ${body.transfer.id} — ${body.transfer.failReason ?? 's/ motivo'}`);
          check('mark_asaas_transfer_manual_review', (await ctx.supabaseAdmin.rpc('mark_asaas_transfer_manual_review', {
            p_transfer_id: body.transfer.externalReference ?? body.transfer.id,
            p_reason: body.transfer.failReason ?? `Transferência ${body.event}.`,
          })).error);
          check('provider_asaas_withdrawals', (await ctx.supabaseAdmin.from('provider_asaas_withdrawals')
            .update({status: 'failed'})
            .eq('asaas_transfer_id', body.transfer.id).eq('status', 'requested')).error);
        }
        break;
      }
      case 'ACCOUNT_STATUS_GENERAL_APPROVAL_APPROVED': {
        if (body.account?.id) {
          check('provider_asaas_accounts', (await ctx.supabaseAdmin.from('provider_asaas_accounts')
            .update({status: 'verified', verified_at: new Date().toISOString(), rejection_reason: null})
            .eq('asaas_account_id', body.account.id)).error);
        }
        break;
      }
      case 'ACCOUNT_STATUS_GENERAL_APPROVAL_REJECTED': {
        if (body.account?.id) {
          check('provider_asaas_accounts', (await ctx.supabaseAdmin.from('provider_asaas_accounts')
            .update({status: 'rejected', rejection_reason: 'Cadastro recusado pelo Asaas — revise os documentos.'})
            .eq('asaas_account_id', body.account.id)).error);
        }
        break;
      }
      default:
        break;
    }

    if (failures.length > 0) {
      const reason = failures.join(' | ');
      console.error(`asaas-webhook: ${dedupeKey} falhou — ${reason}`);
      await ctx.supabaseAdmin.rpc('mark_asaas_webhook_event_failed', {
        p_event_id: entry.event_id,
        p_error: reason,
      });
      // O evento está salvo: devolver erro pede a reentrega, que conclui.
      return Response.json({message: 'Processamento falhou; reenviar.'}, {status: 500});
    }

    const marked = await ctx.supabaseAdmin.rpc('mark_asaas_webhook_event_processed', {
      p_event_id: entry.event_id,
    });
    if (marked.error) {
      // O efeito já aconteceu, mas o evento continua pendente. Pedir reentrega
      // é seguro porque o domínio ignora repetição, e sem isso o registro
      // ficaria mentindo sobre o que foi concluído.
      console.error(`asaas-webhook: ${dedupeKey} processado sem baixa — ${marked.error.message}`);
      return Response.json({message: 'Baixa do evento falhou; reenviar.'}, {status: 500});
    }

    return Response.json({received: true});
  }),
};
