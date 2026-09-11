import {withSupabase} from 'npm:@supabase/server';

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    const {inviteId} = await request.json() as {inviteId?: string};
    if (!inviteId) return Response.json({message: 'Convite obrigatório.'}, {status: 400});

    const {data: invite, error: inviteError} = await ctx.supabaseAdmin
      .from('favorite_mechanic_invites')
      .select('id, driver_id, provider_id')
      .eq('id', inviteId)
      .maybeSingle();
    if (inviteError || !invite || invite.driver_id !== ctx.user.id) {
      return Response.json({message: 'Convite não encontrado ou sem permissão.'}, {status: 404});
    }

    const {data: notification, error: notificationError} = await ctx.supabaseAdmin
      .from('app_notifications')
      .select('id, title, body, data, push_sent_at')
      .eq('entity_id', invite.id)
      .eq('recipient_id', invite.provider_id)
      .eq('type', 'favorite_mechanic_invite')
      .maybeSingle();
    if (notificationError || !notification) return Response.json({message: notificationError?.message ?? 'Notificação não encontrada.'}, {status: 404});
    if (notification.push_sent_at) return Response.json({sent: true, duplicate: true});

    await ctx.supabaseAdmin.from('app_notifications').update({push_attempted_at: new Date().toISOString(), push_error: null}).eq('id', notification.id);
    const {data, error} = await ctx.supabaseAdmin.functions.invoke('send-push-notification', {
      body: {userIds: [invite.provider_id], title: notification.title, message: notification.body, data: {...(notification.data as Record<string, string>), type: 'favorite_mechanic_invite', inviteId: invite.id}},
    });
    if (error) {
      await ctx.supabaseAdmin.from('app_notifications').update({push_error: error.message}).eq('id', notification.id);
      return Response.json({message: error.message}, {status: 502});
    }
    const sent = Number(data?.sent ?? 0) > 0;
    await ctx.supabaseAdmin.from('app_notifications').update({push_sent_at: sent ? new Date().toISOString() : null, push_error: sent ? null : 'Nenhum dispositivo ativo encontrado.'}).eq('id', notification.id);
    return Response.json({sent});
  }),
};
