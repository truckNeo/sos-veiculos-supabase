import {withSupabase} from 'npm:@supabase/server';
import {asaasFetch, isAsaasSandbox} from '../_shared/asaas.ts';

type Operation = {
  id: string; decision: 'driver_refunded' | 'provider_released'; status: string;
  amount_cents: number; asaas_payment_id: string | null; wallet_id: string | null;
  sandbox: boolean; external_id: string | null; decision_note: string;
};
type GatewayResult = {id?: string; status?: string; value?: number; walletId?: string};

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    if (request.method !== 'POST') return Response.json({message: 'Método inválido.'}, {status: 405});
    let body: {requestId?: string; decision?: string; note?: string};
    try { body = await request.json(); } catch { return Response.json({message: 'Dados inválidos.'}, {status: 400}); }
    const {requestId, decision, note} = body;
    if (!requestId || !['driver_refunded', 'provider_released', 'cancelled'].includes(decision ?? '') || typeof note !== 'string' || note.trim().length < 10 || note.trim().length > 2000) {
      return Response.json({message: 'Informe a decisão e uma justificativa entre 10 e 2000 caracteres.'}, {status: 400});
    }
    // A autorização de administrador é validada no banco antes de qualquer acesso financeiro.
    const {data: isAdmin, error: adminError} = await ctx.supabase.rpc('is_service_dispute_admin');
    if (adminError || isAdmin !== true) return Response.json({message: 'Acesso restrito ao console de disputas.'}, {status: 403});
    if (decision === 'cancelled') {
      const {error} = await ctx.supabase.rpc('decide_service_dispute', {p_request_id: requestId, p_decision: decision, p_decision_note: note.trim()});
      return error ? Response.json({message: 'Não foi possível cancelar. Se há pagamento recebido, escolha reembolso ou repasse.'}, {status: 409}) : Response.json({decided: true});
    }
    const {data, error} = await ctx.supabase.rpc('begin_asaas_dispute_settlement', {p_request_id: requestId, p_decision: decision, p_note: note.trim()});
    if (error || !data?.length) return Response.json({message: 'Não foi possível iniciar a decisão financeira. Verifique a disputa e o saldo retido.'}, {status: 409});
    const operations = data as Operation[];
    // Nunca use as chaves de produção numa cobrança emitida em sandbox (ou vice-versa).
    if (operations.some(op => op.sandbox !== isAsaasSandbox())) return Response.json({message: 'O ambiente Asaas não corresponde às cobranças desta disputa.'}, {status: 409});
    for (const operation of operations) {
      if (operation.status === 'confirmed') continue;
      let submitted = false;
      try {
        // Consulta permite conciliar um timeout sem repetir o POST de estorno/repasse.
        let gateway: GatewayResult | undefined;
        if (operation.decision === 'driver_refunded') {
          const response = await asaasFetch(`/payments/${encodeURIComponent(operation.asaas_payment_id!)}`);
          if (!response.ok) throw new Error('Falha ao consultar cobrança.');
          gateway = await response.json();
        } else if (operation.external_id) {
          const response = await asaasFetch(`/transfers/${encodeURIComponent(operation.external_id)}`);
          if (!response.ok) throw new Error('Falha ao consultar repasse.');
          gateway = await response.json();
        } else if (operation.status !== 'pending') {
          // Uma resposta perdida exige conciliação no painel; não cria outro repasse.
          return Response.json({message: 'Repasse com resultado incerto. Concilie a operação pelo identificador interno antes de continuar.'}, {status: 409});
        }
        const isConfirmed = () => operation.decision === 'driver_refunded'
          ? gateway?.status === 'REFUNDED'
          : gateway?.status === 'DONE';
        if (!isConfirmed() && operation.status === 'pending') {
          const {data: claimed, error: claimError} = await ctx.supabaseAdmin.rpc('claim_asaas_dispute_operation', {p_operation_id: operation.id});
          if (claimError || !claimed?.length) return Response.json({message: 'A decisão já está em processamento. Aguarde e atualize.'}, {status: 409});
          submitted = true;
          const response = operation.decision === 'driver_refunded'
            ? await asaasFetch(`/payments/${encodeURIComponent(operation.asaas_payment_id!)}/refund`, {body: {description: operation.decision_note}})
            : await asaasFetch('/transfers', {body: {value: operation.amount_cents / 100, walletId: operation.wallet_id, externalReference: operation.id}});
          if (!response.ok) throw new Error('Gateway recusou a operação.');
          gateway = await response.json();
          if (!gateway?.id) throw new Error('Gateway não retornou identificador.');
        }
        const {error: saveError} = await ctx.supabaseAdmin.from('asaas_dispute_operations').update({
          status: isConfirmed() ? 'confirmed' : 'processing',
          external_id: gateway?.id ?? operation.external_id,
          updated_at: new Date().toISOString(),
        }).eq('id', operation.id).neq('status', 'confirmed');
        if (saveError) throw new Error('Falha ao registrar resultado financeiro.');
        if (!isConfirmed()) return Response.json({message: 'Operação solicitada ao Asaas. Aguarde a confirmação e repita a mesma decisão para atualizar o resultado.'}, {status: 409});
      } catch {
        if (submitted) {
          await ctx.supabaseAdmin.from('asaas_dispute_operations').update({status: 'manual_review', updated_at: new Date().toISOString()}).eq('id', operation.id).neq('status', 'confirmed');
        }
        return Response.json({message: 'A decisão ainda não foi concluída. Consulte o Asaas para conciliar a operação; nenhum novo envio será feito automaticamente.'}, {status: 502});
      }
    }
    const {error: finishError} = await ctx.supabase.rpc('decide_service_dispute', {p_request_id: requestId, p_decision: decision, p_decision_note: operations[0].decision_note});
    return finishError ? Response.json({message: 'Operação confirmada no Asaas; a disputa ainda precisa de conciliação no sistema.'}, {status: 409}) : Response.json({decided: true});
  }),
};
