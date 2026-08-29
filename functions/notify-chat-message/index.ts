import {withSupabase} from 'npm:@supabase/server';

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    const {requestId} = await request.json() as {requestId?: string};
    if (!requestId) return Response.json({message: 'Chamado obrigatório.'}, {status: 400});

    const userId = ctx.user?.id;
    if (!userId) return Response.json({message: 'Sessão inválida.'}, {status: 401});

    const {data: serviceRequest, error: requestError} = await ctx.supabaseAdmin
      .from('service_requests')
      .select('id, requester_id, selected_provider_id')
      .eq('id', requestId)
      .maybeSingle();

    if (requestError || !serviceRequest) {
      return Response.json({message: 'Chamado não encontrado.'}, {status: 404});
    }

    const recipientId = userId === serviceRequest.requester_id
      ? serviceRequest.selected_provider_id
      : serviceRequest.requester_id;

    if (!recipientId) {
      return Response.json({sent: 0});
    }

    const senderRole = userId === serviceRequest.requester_id ? 'Motorista' : 'Prestador';

    const {error} = await ctx.supabaseAdmin.functions.invoke('send-push-notification', {
      body: {
        userIds: [recipientId],
        title: 'Nova mensagem no atendimento',
        message: `${senderRole} enviou uma mensagem. Toque para abrir a conversa.`,
        data: {type: 'chat_message', requestId},
      },
    });

    if (error) return Response.json({message: error.message}, {status: 502});
    return Response.json({sent: 1});
  }),
};
