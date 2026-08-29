import {withSupabase} from 'npm:@supabase/server';

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    const {requestId} = await request.json() as {requestId?: string};
    if (!requestId) return Response.json({message: 'Chamado obrigatório.'}, {status: 400});

    const {data: serviceRequest, error: requestError} = await ctx.supabase
      .from('service_requests')
      .select('id, problem_type')
      .eq('id', requestId)
      .maybeSingle();
    if (requestError || !serviceRequest) return Response.json({message: 'Chamado não encontrado ou sem permissão.'}, {status: 404});

    const {data: queued, error: queuedError} = await ctx.supabaseAdmin
      .from('service_request_dispatch_push_outbox')
      .select('id, dispatch_id, service_request_dispatches!inner(provider_id, request_id, problem_type)')
      .eq('status', 'queued')
      .eq('service_request_dispatches.request_id', requestId);
    if (queuedError) return Response.json({message: queuedError.message}, {status: 500});
    if (!queued?.length) return Response.json({sent: 0});

    const providerIds = [...new Set(queued.map(item => (item.service_request_dispatches as {provider_id: string}).provider_id))];
    const {data, error} = await ctx.supabaseAdmin.functions.invoke('send-push-notification', {
      body: {
        userIds: providerIds,
        title: 'Novo chamado na sua área',
        message: `Solicitação de ${serviceRequest.problem_type}. Toque para ver os detalhes.`,
        data: {type: 'service_request_dispatch', requestId},
      },
    });
    const outboxIds = queued.map(item => item.id);
    await ctx.supabaseAdmin.from('service_request_dispatch_push_outbox').update({
      status: error ? 'failed' : 'sent',
      attempts: 1,
      last_error: error?.message ?? null,
      sent_at: error ? null : new Date().toISOString(),
    }).in('id', outboxIds);
    if (error) return Response.json({message: error.message}, {status: 502});
    return Response.json({sent: data?.sent ?? 0, queued: queued.length});
  }),
};
