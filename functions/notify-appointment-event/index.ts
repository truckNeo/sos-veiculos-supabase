import {withSupabase} from 'npm:@supabase/server';
import type {ProductDatabase} from '../_shared/product-database.ts';

// Chamada pelo app logo após uma ação de agendamento: envia o push à outra parte
// na hora, sem esperar o agendador de lembretes. A reserva é atômica no banco,
// então o agendador não repete o envio enquanto este está em andamento.
export default {
  fetch: withSupabase<ProductDatabase>({auth: 'user'}, async (request, ctx) => {
    if (request.method !== 'POST') return new Response(null, {status: 405});
    const {appointmentId} = await request.json() as {appointmentId?: string};
    if (!appointmentId) return Response.json({message: 'Agendamento obrigatório.'}, {status: 400});

    const {data: claimed, error} = await ctx.supabaseAdmin.rpc('claim_appointment_notification', {
      p_appointment_id: appointmentId,
      p_actor: ctx.user.id,
    });
    if (error) return Response.json({message: 'Agendamento indisponível.'}, {status: 404});

    let sent = 0;
    let failed = 0;
    let skipped = 0;
    for (const notification of claimed ?? []) {
      try {
        const {data: preference, error: preferenceError} = await ctx.supabaseAdmin
          .from('app_notification_preferences').select('appointments')
          .eq('user_id', notification.user_id).maybeSingle();
        if (preferenceError) {failed++; continue;}
        const {data: current, error: validationError} = await ctx.supabaseAdmin
          .rpc('product_notification_is_current', {p_id: notification.id});
        if (validationError) {failed++; continue;}
        const enabled = current === true && preference?.appointments !== false;
        if (enabled) {
          const {data: result, error: sendError} = await ctx.supabaseAdmin.functions.invoke('send-push-notification', {
            body: {
              userIds: [notification.user_id], title: notification.title, message: notification.body,
              data: {type: notification.category, resourceId: notification.resource_id, notificationId: notification.id},
            },
          });
          if (sendError || !result || Number(result.sent ?? 0) < 1 || result.sent < result.attempted) {failed++; continue;}
        }
        const {error: updateError} = await ctx.supabaseAdmin.from('product_notifications')
          .update({push_sent_at: new Date().toISOString(), push_lease_until: null})
          .eq('id', notification.id).eq('push_claim', notification.push_claim!);
        if (updateError) failed++; else if (enabled) sent++; else skipped++;
      } catch {failed++;}
    }
    return Response.json({sent, failed, skipped});
  }),
};
