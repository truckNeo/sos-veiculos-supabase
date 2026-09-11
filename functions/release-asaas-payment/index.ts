import {withSupabase} from 'npm:@supabase/server';

import {asaasFetch, parseAsaasError} from '../_shared/asaas.ts';

// Repasse conta mestre -> subconta do prestador (POST /transfers por
// walletId, interna e sem tarifa). A autorização (authorized:true) é feita
// pelo webhook de validação de operações (asaas-operation-webhook) — sem
// isso a transferência fica presa em PENDING até alguém autorizar manualmente
// no painel com o token de ação crítica.

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    const {requestId, rating, comment} = await request.json() as {requestId?: string; rating?: number; comment?: string};
    if (!requestId || !Number.isInteger(rating) || !rating || rating < 1 || rating > 5) {
      return Response.json({message: 'Confirme o serviço e informe uma avaliação de 1 a 5 estrelas.'}, {status: 400});
    }
    const {data: started, error: startError} = await ctx.supabase.rpc('begin_asaas_payment_release', {p_request_id: requestId});
    const release = started?.[0] as {transfer_id?: string} | undefined;
    if (startError || !release?.transfer_id) return Response.json({message: startError?.message ?? 'Não foi possível iniciar a liberação.'}, {status: 409});

    const {data: claimed, error: claimError} = await ctx.supabaseAdmin.rpc('claim_asaas_provider_transfer', {p_transfer_id: release.transfer_id});
    const transfer = claimed?.[0] as {provider_net_cents?: number; wallet_id?: string} | undefined;
    if (claimError || !transfer?.wallet_id || !transfer.provider_net_cents) {
      return Response.json({message: claimError?.message ?? 'A transferência já está sendo revisada.'}, {status: 409});
    }
    try {
      const response = await asaasFetch('/transfers', {body: {
        value: transfer.provider_net_cents / 100,
        walletId: transfer.wallet_id,
        externalReference: release.transfer_id,
      }});
      if (!response.ok) {
        await ctx.supabaseAdmin.rpc('mark_asaas_transfer_manual_review', {p_transfer_id: release.transfer_id, p_reason: (await parseAsaasError(response)).slice(0, 1000)});
        return Response.json({message: 'A liberação está em revisão financeira. Nenhum novo repasse será feito automaticamente.'}, {status: 502});
      }
      const asaasTransfer = await response.json() as {id?: string};
      const {error: completeError} = await ctx.supabaseAdmin.rpc('complete_asaas_payment_release_with_review', {
        p_transfer_id: release.transfer_id, p_asaas_transfer_id: asaasTransfer.id ?? null, p_rating: rating, p_comment: comment?.trim() || null,
      });
      if (completeError) return Response.json({message: 'O repasse foi aceito, mas precisa de conciliação manual.'}, {status: 500});
      return Response.json({released: true});
    } catch (error) {
      await ctx.supabaseAdmin.rpc('mark_asaas_transfer_manual_review', {p_transfer_id: release.transfer_id, p_reason: error instanceof Error ? error.message : 'Falha desconhecida.'});
      return Response.json({message: 'A liberação está em revisão financeira.'}, {status: 503});
    }
  }),
};
