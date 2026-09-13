import {withSupabase} from 'npm:@supabase/server@1.4.1';
import type {ProductDatabase} from '../_shared/product-database.ts';

// Authenticated scheduler, once a minute. Leases prevent concurrent claims.
// Delivery is at-least-once: a crash after FCM may repeat a push on retry.
export default {
  fetch: withSupabase<ProductDatabase>({auth: 'secret'}, async (request, ctx) => {
    if (request.method !== 'POST') return new Response(null, {status: 405});
    const {error: enqueueError} = await ctx.supabaseAdmin.rpc('enqueue_product_reminders');
    if (enqueueError) return Response.json({message: 'Falha ao gerar lembretes.'}, {status: 500});
    const {data: notifications, error} = await ctx.supabaseAdmin.rpc('claim_product_notifications');
    if (error) return Response.json({message: 'Falha ao reservar notificações.'}, {status: 500});
    let delivered = 0;
    let failed = 0;
    let skipped = 0;
    for (const notification of notifications ?? []) {
      try {
        const {data: preference, error: preferenceError} = await ctx.supabaseAdmin
          .from('app_notification_preferences').select('maintenance, appointments')
          .eq('user_id', notification.user_id).maybeSingle();
        if (preferenceError) {failed++; continue;}
        const {data: current, error: validationError} = await ctx.supabaseAdmin.rpc('product_notification_is_current', {p_id: notification.id});
        if (validationError) {failed++; continue;}
        const enabled = current === true && (notification.category === 'maintenance' ? preference?.maintenance !== false
          : notification.category === 'appointments' ? preference?.appointments !== false : true);
        if (enabled) {
          const {data: result, error: sendError} = await ctx.supabaseAdmin.functions.invoke('send-push-notification', {
            body: {userIds: [notification.user_id], title: notification.title, message: notification.body,
              data: {type: notification.category, resourceId: notification.resource_id, notificationId: notification.id}},
          });
          if (sendError || !result || (Number(result.sent ?? 0) < 1 || result.sent < result.attempted)) {failed++; continue;}
        }
        const {error: updateError} = await ctx.supabaseAdmin.from('product_notifications')
          .update({push_sent_at: new Date().toISOString(), push_lease_until: null})
          .eq('id', notification.id).eq('push_claim', notification.push_claim!);
        if (updateError) failed++; else if(enabled) delivered++; else skipped++;
      } catch {failed++;}
    }
    const {count: exhausted, error: countError} = await ctx.supabaseAdmin.from('product_notifications').select('id', {count:'exact',head:true}).is('push_sent_at', null).gte('push_attempts',6);
    if(countError)return Response.json({delivered,failed,message:'Falha ao consultar tentativas esgotadas.'},{status:500});
    return Response.json({delivered, failed, skipped, exhausted: exhausted ?? 0});
  }),
};
