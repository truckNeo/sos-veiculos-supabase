import {withSupabase} from 'npm:@supabase/server';

/**
 * Webhook de validação de operações do Asaas ("Mecanismo para validação de saque
 * via webhooks"). O Asaas envia um POST ~5s após cada operação sensível (a partir
 * da conta que dispara — no nosso caso a conta mestre / plataforma) e só executa
 * a operação se este endpoint responder {"status":"APPROVED"}.
 *
 * Substitui o token de ação crítica (SMS/APP) por uma decisão automática da nossa
 * aplicação — é o equivalente ao `signedIuguFetch` (assinatura RSA) do fluxo Iugu.
 *
 * Configuração no painel Asaas: Integrações → Mecanismos de segurança →
 *   URL: https://<project>.supabase.co/functions/v1/asaas-operation-webhook
 *   Token: valor de ASAAS_OPERATION_WEBHOOK_TOKEN (chega no header asaas-access-token)
 *
 * Regras (PoC): aprova apenas TRANSFER, dentro de um teto configurável e para os
 * operationType esperados. Recusa o resto. Quando a integração Asaas real existir,
 * trocar a heurística por conferência contra a tabela de repasses
 * (transfer.externalReference -> nosso registro -> valor/destino esperados).
 */

type AsaasOperationPayload = {
  type: 'TRANSFER' | 'BILL' | 'PIX_QR_CODE' | 'MOBILE_PHONE_RECHARGE' | 'PIX_REFUND';
  transfer?: {
    id?: string;
    status?: string;
    value?: number;
    netValue?: number;
    operationType?: string; // PIX | TED | INTERNAL
    description?: string | null;
    externalReference?: string | null;
    bankAccount?: {pixAddressKey?: string | null; cpfCnpj?: string | null} | null;
  };
};

const secureEqual = (left: string, right: string) => {
  if (left.length !== right.length || left.length === 0) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i += 1) diff |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return diff === 0;
};

const approve = () => Response.json({status: 'APPROVED'});
const refuse = (refuseReason: string) => Response.json({status: 'REFUSED', refuseReason});

export default {
  fetch: withSupabase({auth: 'none'}, async (request, _ctx) => {
    // O token de autenticação do Asaas é opcional. Se ASAAS_OPERATION_WEBHOOK_TOKEN
    // não estiver setado, a validação de header é pulada (o Asaas rotula o campo
    // como "Opcional"). Em produção, SEMPRE configure o token.
    const expected = (Deno.env.get('ASAAS_OPERATION_WEBHOOK_TOKEN') ?? '').trim();
    if (expected) {
      if (!secureEqual((request.headers.get('asaas-access-token') ?? '').trim(), expected)) {
        return Response.json({status: 'REFUSED', refuseReason: 'Token inválido.'}, {status: 401});
      }
    } else {
      console.warn('asaas-operation-webhook: sem ASAAS_OPERATION_WEBHOOK_TOKEN — validação de header DESLIGADA.');
    }

    let payload: AsaasOperationPayload;
    try {
      payload = await request.json() as AsaasOperationPayload;
    } catch {
      return refuse('Payload inválido.');
    }

    // Só automatizamos repasses; qualquer outra operação sensível é recusada
    // (deve ser autorizada manualmente por quem opera a conta).
    if (payload.type !== 'TRANSFER' || !payload.transfer) {
      console.warn(`asaas-operation-webhook: recusando operação não-TRANSFER (${payload.type}).`);
      return refuse(`Operação ${payload.type} não é liberada automaticamente.`);
    }

    const t = payload.transfer;
    const allowedOps = (Deno.env.get('ASAAS_OPERATION_WEBHOOK_ALLOWED_OPS') ?? 'PIX,INTERNAL')
      .split(',').map((s) => s.trim().toUpperCase()).filter(Boolean);
    const maxValue = Number(Deno.env.get('ASAAS_OPERATION_WEBHOOK_MAX_VALUE') ?? '5000');

    if (t.operationType && !allowedOps.includes(t.operationType.toUpperCase())) {
      return refuse(`operationType ${t.operationType} não permitido.`);
    }
    if (typeof t.value === 'number' && t.value > maxValue) {
      return refuse(`Valor ${t.value} acima do teto automático (${maxValue}).`);
    }

    // TODO(integração Asaas): conferir contra a tabela de repasses —
    //   const {data} = await _ctx.supabaseAdmin
    //     .from('asaas_provider_transfers')
    //     .select('expected_value_cents, provider_wallet_id, status')
    //     .eq('asaas_transfer_external_reference', t.externalReference)
    //     .maybeSingle();
    //   e recusar se não bater valor/destino/estado.

    console.log(`asaas-operation-webhook: APPROVED transfer ${t.id} value=${t.value} op=${t.operationType} ref=${t.externalReference}`);
    return approve();
  }),
};
