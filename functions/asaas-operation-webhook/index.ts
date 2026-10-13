import {withSupabase} from 'npm:@supabase/server';
import {asaasFetch} from '../_shared/asaas.ts';

const secureEqual = (a: string, b: string) => {
  if (!a.length || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
};
const refuse = (refuseReason: string) => Response.json({status: 'REFUSED', refuseReason});

export default {
  fetch: withSupabase({auth: 'none'}, async (request, ctx) => {
    const token = (Deno.env.get('ASAAS_OPERATION_WEBHOOK_TOKEN') ?? '').trim();
    if (!token) return Response.json({status: 'REFUSED', refuseReason: 'Webhook não configurado.'}, {status: 503});
    if (!secureEqual((request.headers.get('asaas-access-token') ?? '').trim(), token)) return Response.json({status: 'REFUSED', refuseReason: 'Token inválido.'}, {status: 401});
    let payload: {type?: string; transfer?: {id?: string; externalReference?: string; value?: number}};
    try {payload = await request.json();} catch {return refuse('Payload inválido.');}
    const transfer = payload.transfer;
    if (payload.type !== 'TRANSFER' || !transfer?.id || !transfer.externalReference || !/^[0-9a-f-]{36}$/i.test(transfer.externalReference)) return refuse('Operação sem repasse registrado.');
    const {data: expected, error} = await ctx.supabaseAdmin.from('service_provider_transfers')
      .select('provider_id,provider_net_cents,status').eq('id', transfer.externalReference).maybeSingle();
    if (error || !expected || !['processing','manual_review'].includes(expected.status)) return refuse('Repasse não autorizado no sistema.');
    const {data: account, error: accountError} = await ctx.supabaseAdmin.from('provider_asaas_accounts')
      .select('wallet_id,status').eq('provider_id', expected.provider_id).maybeSingle();
    if (accountError || account?.status !== 'verified' || !account.wallet_id) return refuse('Subconta não verificada.');
    // Confere o destino na API autenticada, e não apenas no payload recebido.
    try {
      const response = await asaasFetch(`/transfers/${encodeURIComponent(transfer.id)}`);
      if (!response.ok) return refuse('Não foi possível conferir o repasse.');
      const actual = await response.json() as {walletId?: string; value?: number; externalReference?: string};
      const maxValue = Number(Deno.env.get('ASAAS_OPERATION_WEBHOOK_MAX_VALUE') ?? '5000');
      if (!Number.isFinite(maxValue) || maxValue <= 0 || typeof actual.value !== 'number' || !Number.isFinite(actual.value)
        || Math.round(actual.value * 100) !== expected.provider_net_cents || actual.value > maxValue
        || actual.walletId !== account.wallet_id || actual.externalReference !== transfer.externalReference) return refuse('Valor, destino ou referência divergente do repasse autorizado.');
      return Response.json({status: 'APPROVED'});
    } catch {return refuse('Falha ao conferir o repasse.');}
  }),
};
