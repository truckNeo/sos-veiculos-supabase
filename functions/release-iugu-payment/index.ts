import {withSupabase} from 'npm:@supabase/server';

import {isIuguMockMode, parseIuguError, requireIuguProduction, signedIuguFetch} from '../_shared/iugu.ts';

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    const {requestId, rating, comment} = await request.json() as {requestId?: string; rating?: number; comment?: string};
    if (!requestId || !Number.isInteger(rating) || !rating || rating < 1 || rating > 5) {
      return Response.json({message: 'Confirme o serviço e informe uma avaliação de 1 a 5 estrelas.'}, {status: 400});
    }
    const {data: started, error: startError} = await ctx.supabase.rpc('begin_iugu_payment_release', {p_request_id: requestId});
    const release = started?.[0] as {transfer_id?: string} | undefined;
    if (startError || !release?.transfer_id) return Response.json({message: startError?.message ?? 'Não foi possível iniciar a liberação.'}, {status: 409});
    const {data: claimed, error: claimError} = await ctx.supabaseAdmin.rpc('claim_iugu_provider_transfer', {p_transfer_id: release.transfer_id});
    const transfer = claimed?.[0] as {provider_net_cents?: number; iugu_account_id?: string} | undefined;
    if (claimError || !transfer?.iugu_account_id || !transfer.provider_net_cents) return Response.json({message: claimError?.message ?? 'A transferência já está sendo revisada.'}, {status: 409});
    try {
      if (isIuguMockMode()) {
        const {error: completeError} = await ctx.supabaseAdmin.rpc('complete_iugu_payment_release_with_review', {
          p_transfer_id: release.transfer_id, p_iugu_transfer_id: `TRANSFER_MOCK_${release.transfer_id.replaceAll('-', '')}`,
          p_rating: rating, p_comment: comment?.trim() || null,
        });
        return completeError ? Response.json({message: 'Não foi possível concluir o repasse de teste.'}, {status: 500}) : Response.json({released: true, mock: true});
      }
      const {masterToken, privateKey} = requireIuguProduction();
      const response = await signedIuguFetch('/v1/transfers', {
        receiver_id: transfer.iugu_account_id,
        amount_cents: transfer.provider_net_cents,
        custom_variables: [{name: 'sos_veiculos_transfer_id', value: release.transfer_id}],
      }, masterToken, privateKey);
      if (!response.ok) {
        await ctx.supabaseAdmin.rpc('mark_iugu_transfer_manual_review', {p_transfer_id: release.transfer_id, p_reason: (await parseIuguError(response)).slice(0, 1000)});
        return Response.json({message: 'A liberação está em revisão financeira. Nenhum novo repasse será feito automaticamente.'}, {status: 502});
      }
      const iuguTransfer = await response.json() as {id?: string};
      const {error: completeError} = await ctx.supabaseAdmin.rpc('complete_iugu_payment_release_with_review', {
        p_transfer_id: release.transfer_id, p_iugu_transfer_id: iuguTransfer.id ?? null, p_rating: rating, p_comment: comment?.trim() || null,
      });
      if (completeError) return Response.json({message: 'O repasse foi aceito, mas precisa de conciliação manual.'}, {status: 500});
      return Response.json({released: true});
    } catch (error) {
      await ctx.supabaseAdmin.rpc('mark_iugu_transfer_manual_review', {p_transfer_id: release.transfer_id, p_reason: error instanceof Error ? error.message : 'Falha desconhecida.'});
      return Response.json({message: 'A liberação está em revisão financeira.'}, {status: 503});
    }
  }),
};
