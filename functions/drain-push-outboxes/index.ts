import {withSupabase} from 'npm:@supabase/server@1.4.1';

/**
 * Drena as filas de push do atendimento: dispatches para prestadores e
 * eventos para o motorista.
 *
 * Antes, o disparo de dispatches dependia do app do motorista chamar uma
 * função a cada 15 segundos, e os eventos do motorista não tinham push
 * nenhum. Nos dois casos, app fechado significava ninguém avisado. Esta
 * função é chamada pelo scheduler do backend.
 *
 * Entrega at-least-once: uma falha depois do FCM pode repetir o push.
 */

const MAX_BATCH = 200;
const MAX_ATTEMPTS = 5;

type DispatchRow = {
  id: string;
  attempts: number;
  service_request_dispatches: {provider_id: string; request_id: string; problem_type: string | null};
};

type DriverEventRow = {
  id: string;
  attempts: number;
  request_id: string;
  recipient_id: string;
  kind: string;
};

const DRIVER_COPY: Record<string, {title: string; message: string}> = {
  offer_received: {
    title: 'Nova proposta recebida',
    message: 'Um prestador enviou uma proposta para o seu chamado.',
  },
  provider_en_route: {
    title: 'Prestador a caminho',
    message: 'O prestador saiu para o atendimento.',
  },
  provider_on_site: {
    title: 'Prestador chegou',
    message: 'O prestador informou que chegou ao local.',
  },
  awaiting_driver_confirmation: {
    title: 'Serviço pronto para conferência',
    message: 'Confira o atendimento para concluir.',
  },
  dispute_opened: {
    title: 'Disputa aberta',
    message: 'A equipe vai analisar este atendimento.',
  },
  service_closed: {
    title: 'Atendimento encerrado',
    message: 'Veja o resumo no aplicativo.',
  },
};

export default {
  fetch: withSupabase({auth: 'secret'}, async (request, ctx) => {
    if (request.method !== 'POST') return new Response(null, {status: 405});

    const result = {dispatches: {sent: 0, failed: 0}, driverEvents: {sent: 0, failed: 0}};

    /** Marca o lote e devolve se deu certo, para somar nos contadores. */
    const settle = async (
      table: string,
      rows: Array<{id: string; attempts: number}>,
      error: {message: string} | null,
    ) => {
      for (const row of rows) {
        await ctx.supabaseAdmin
          .from(table)
          .update({
            status: error ? 'queued' : 'sent',
            attempts: row.attempts + 1,
            last_error: error?.message ?? null,
            sent_at: error ? null : new Date().toISOString(),
          })
          .eq('id', row.id);
      }
      // Quem estourou o limite sai da fila como 'failed', para aparecer em
      // investigação em vez de girar para sempre.
      await ctx.supabaseAdmin
        .from(table)
        .update({status: 'failed'})
        .eq('status', 'queued')
        .gte('attempts', MAX_ATTEMPTS);
    };

    // --- Dispatches para prestadores ---
    const {data: dispatches, error: dispatchError} = await ctx.supabaseAdmin
      .from('service_request_dispatch_push_outbox')
      .select('id, attempts, service_request_dispatches!inner(provider_id, request_id, problem_type)')
      .eq('status', 'queued')
      .lt('attempts', MAX_ATTEMPTS)
      .order('created_at', {ascending: true})
      .limit(MAX_BATCH);
    if (dispatchError) return Response.json({message: dispatchError.message}, {status: 500});

    const byRequest = new Map<string, {rows: DispatchRow[]; problemType: string | null}>();
    for (const row of (dispatches ?? []) as unknown as DispatchRow[]) {
      const dispatch = row.service_request_dispatches;
      const entry = byRequest.get(dispatch.request_id) ?? {rows: [], problemType: dispatch.problem_type};
      entry.rows.push(row);
      byRequest.set(dispatch.request_id, entry);
    }
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
      await settle('service_request_dispatch_push_outbox', rows, error);
      if (error) result.dispatches.failed += rows.length;
      else result.dispatches.sent += (data as {sent?: number} | null)?.sent ?? providerIds.length;
    }

    // --- Eventos do atendimento para o motorista ---
    const {data: events, error: eventsError} = await ctx.supabaseAdmin
      .from('driver_event_push_outbox')
      .select('id, attempts, request_id, recipient_id, kind')
      .eq('status', 'queued')
      .lt('attempts', MAX_ATTEMPTS)
      .order('created_at', {ascending: true})
      .limit(MAX_BATCH);
    if (eventsError) return Response.json({message: eventsError.message}, {status: 500});

    // Agrupa por (chamado, tipo) para um push por evento, com todos os
    // destinatários daquele evento.
    const byEvent = new Map<string, DriverEventRow[]>();
    for (const row of (events ?? []) as DriverEventRow[]) {
      const key = `${row.request_id}:${row.kind}`;
      byEvent.set(key, [...(byEvent.get(key) ?? []), row]);
    }
    for (const [key, rows] of byEvent) {
      const [requestId, kind] = key.split(':');
      const copy = DRIVER_COPY[kind];
      if (!copy) {
        await settle('driver_event_push_outbox', rows, {message: `Tipo desconhecido: ${kind}`});
        result.driverEvents.failed += rows.length;
        continue;
      }
      const userIds = [...new Set(rows.map(r => r.recipient_id))];
      const {data, error} = await ctx.supabaseAdmin.functions.invoke('send-push-notification', {
        body: {
          userIds,
          title: copy.title,
          message: copy.message,
          data: {type: 'service_request_update', requestId, kind},
        },
      });
      await settle('driver_event_push_outbox', rows, error);
      if (error) result.driverEvents.failed += rows.length;
      else result.driverEvents.sent += (data as {sent?: number} | null)?.sent ?? userIds.length;
    }

    return Response.json(result);
  }),
};
