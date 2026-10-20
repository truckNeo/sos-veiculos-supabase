import {withSupabase} from 'npm:@supabase/server@1.4.1';
import type {AsaasDatabase} from '../_shared/asaas-database.ts';
import {asaasFetch, isAsaasSandbox} from '../_shared/asaas.ts';

type Transfer = {id: string; status: string; asaas_transfer_id: string | null};

export default {
  fetch: withSupabase<AsaasDatabase>({auth: 'user'}, async (request, ctx) => {
    if (request.method !== 'POST') return Response.json({message: 'Método inválido.'}, {status: 405});
    let body: {requestId?: string; rating?: number; comment?: string | null};
    try { body = await request.json(); } catch { return Response.json({message: 'Dados inválidos.'}, {status: 400}); }
    const {requestId, rating, comment} = body;
    if (!requestId || !Number.isInteger(rating) || !rating || rating < 1 || rating > 5 || (comment != null && typeof comment !== 'string')) {
      return Response.json({message: 'Confirme o serviço e informe uma avaliação de 1 a 5 estrelas.'}, {status: 400});
    }
    const {data: charges, error: chargesError} = await ctx.supabase.from('service_payment_charges').select('asaas_sandbox').eq('request_id', requestId).eq('status', 'paid');
    if (chargesError || !charges?.length || charges.some((charge: {asaas_sandbox: boolean}) => charge.asaas_sandbox !== isAsaasSandbox())) {
      return Response.json({message: 'O ambiente Asaas não corresponde às cobranças deste atendimento.'}, {status: 409});
    }
    const {data: started, error: startError} = await ctx.supabase.rpc('begin_asaas_payment_release', {p_request_id: requestId});
    const release = started?.[0] as {transfer_id?: string} | undefined;
    if (startError || !release?.transfer_id) return Response.json({message: 'Não foi possível iniciar a liberação. Verifique o atendimento e o cadastro financeiro do prestador.'}, {status: 409});
    const {data: stored, error: storedError} = await ctx.supabaseAdmin.from('service_provider_transfers').select('id,status,asaas_transfer_id').eq('id', release.transfer_id).single();
    if (storedError || !stored) return Response.json({message: 'Não foi possível consultar o repasse.'}, {status: 503});
    const transfer = stored as Transfer;
    let submitted = false;
    try {
      let gateway: {id?: string; status?: string};
      if (transfer.asaas_transfer_id) {
        const response = await asaasFetch(`/transfers/${encodeURIComponent(transfer.asaas_transfer_id)}`);
        if (!response.ok) throw new Error('Falha ao consultar repasse.');
        gateway = await response.json();
      } else {
        const {data: claimed, error: claimError} = await ctx.supabaseAdmin.rpc('claim_asaas_provider_transfer', {p_transfer_id: release.transfer_id});
        const claimedTransfer = claimed?.[0] as {provider_net_cents?: number; wallet_id?: string} | undefined;
        if (claimError || !claimedTransfer?.wallet_id || !claimedTransfer.provider_net_cents) {
          return Response.json({message: 'O repasse está em processamento ou revisão financeira. Nenhum novo envio será feito.'}, {status: 409});
        }
        submitted = true;
        const response = await asaasFetch('/transfers', {body: {value: claimedTransfer.provider_net_cents / 100, walletId: claimedTransfer.wallet_id, externalReference: release.transfer_id}});
        if (!response.ok) throw new Error('Gateway recusou o repasse.');
        gateway = await response.json();
        if (!gateway.id) throw new Error('Repasse sem identificador.');
        const {error: saveError} = await ctx.supabaseAdmin.from('service_provider_transfers').update({asaas_transfer_id: gateway.id}).eq('id', release.transfer_id);
        if (saveError) throw new Error('Repasse aceito requer conciliação.');
      }
      if (gateway.status !== 'DONE') {
        return Response.json({message: 'O repasse foi solicitado ao Asaas e aguarda confirmação. Tente confirmar novamente para atualizar o resultado.'}, {status: 409});
      }
      // Ao reconsultar um repasse já enviado, o id do gateway não era
      // conferido: uma resposta sem id concluiria a liberação sem referência
      // para conciliar. O id guardado é a mesma transferência, então serve de
      // fallback; sem nenhum dos dois, a liberação não pode ser concluída.
      const confirmedTransferId = gateway.id ?? transfer.asaas_transfer_id;
      if (!confirmedTransferId) throw new Error('Repasse confirmado sem identificador.');
      const {error: completeError} = await ctx.supabaseAdmin.rpc('complete_asaas_payment_release_with_review', {
        p_transfer_id: release.transfer_id, p_asaas_transfer_id: confirmedTransferId, p_rating: rating, p_comment: comment?.trim() || null,
      });
      if (completeError) return Response.json({message: 'O repasse foi confirmado, mas precisa de conciliação no sistema.'}, {status: 500});
      return Response.json({released: true});
    } catch {
      if (submitted) await ctx.supabaseAdmin.rpc('mark_asaas_transfer_manual_review', {p_transfer_id: release.transfer_id, p_reason: 'Resultado financeiro incerto; consultar o Asaas antes de qualquer novo envio.'});
      return Response.json({message: 'A liberação está em revisão financeira. Nenhum novo repasse será feito automaticamente.'}, {status: 503});
    }
  }),
};
