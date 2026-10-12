import {withSupabase} from 'npm:@supabase/server@1.4.1';

/**
 * Drena o outbox de push de dispatches, para todos os chamados.
 *
 * Antes isso dependia de `notify-service-request-dispatches`, chamada pelo
 * app do motorista a cada 15 segundos e só para o chamado dele. Com o app
 * fechado, prestadores elegíveis simplesmente não eram notificados. Esta
 * função é chamada pelo scheduler do backend e não depende de ninguém estar
 * com o app aberto.
 *
 * Entrega at-least-once: uma falha depois do FCM pode repetir o push.
 * A função de push por chamado continua existindo para disparo imediato.
 */

const MAX_BATCH = 200;
const MAX_ATTEMPTS = 5;

type QueuedRow = {
  id: string;
  attempts: number;
  service_request_dispatches: {provider_id: string; request_id: string; problem_type: string | null};
};

export default {
  fetch: withSupabase({auth: 'secret'}, async (request, ctx) => {
    if (request.method !== 'POST') return new Response(null, {status: 405});

    const {data: queued, error: queuedError} = await ctx.supabaseAdmin
      .from('service_request_dispatch_push_outbox')
      .select('id, attempts, service_request_dispatches!inner(provider_id, request_id, problem_type)')
      .eq('status', 'queued')
      .lt('attempts', MAX_ATTEMPTS)
      .order('created_at', {ascending: true})
      .limit(MAX_BATCH);

    if (queuedError) return Response.json({message: queuedError.message}, {status: 500});
    if (!queued?.length) return Response.json({requests: 0, sent: 0, failed: 0});

    // Um push por chamado, com todos os prestadores daquele chamado.
    const byRequest = new Map<string, {rows: QueuedRow[]; problemType: string | null}>();
    for (const row of queued as unknown as QueuedRow[]) {
      const dispatch = row.service_request_dispatches;
      const entry = byRequest.get(dispatch.request_id) ?? {
        rows: [],
        problemType: dispatch.problem_type,
      };
      entry.rows.push(row);
      byRequest.set(dispatch.request_id, entry);
    }

    let sent = 0;
    let failed = 0;

    for (const [requestId, {rows, problemType}] of byRequest) {
      const providerIds = [...new Set(rows.map(r => r.service_request_dispatches.provider_id))];
      const {data, error} = await ctx.supabaseAdmin.functions.invoke('send-push-notification', {
        body: {
          userIds: providerIds,
          title: 'Novo chamado na sua área',
          message: `Solicitação de ${problemType ?? 'serviço'}. Toque para ver os detalhes.`,
          data: {type: 'service_request_dispatch', requestId},
        },
      });

      // Cada linha carrega a própria contagem: um lote que falha sempre para
      // de ser tentado em MAX_ATTEMPTS, em vez de ficar girando para sempre.
      for (const row of rows) {
        await ctx.supabaseAdmin
          .from('service_request_dispatch_push_outbox')
          .update({
            status: error ? 'queued' : 'sent',
            attempts: row.attempts + 1,
            last_error: error?.message ?? null,
            sent_at: error ? null : new Date().toISOString(),
          })
          .eq('id', row.id);
      }

      if (error) {
        failed += rows.length;
      } else {
        sent += (data as {sent?: number} | null)?.sent ?? providerIds.length;
      }
    }

    // Linhas que estouraram o limite saem da fila como 'failed', para
    // aparecerem em investigação em vez de sumirem.
    await ctx.supabaseAdmin
      .from('service_request_dispatch_push_outbox')
      .update({status: 'failed'})
      .eq('status', 'queued')
      .gte('attempts', MAX_ATTEMPTS);

    return Response.json({requests: byRequest.size, sent, failed});
  }),
};
