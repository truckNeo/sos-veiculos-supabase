import { withSupabase } from "npm:@supabase/server@1.4.1";
import type { AsaasDatabase } from "../_shared/asaas-database.ts";
import { refundAppointmentCharge } from "../_shared/appointment-refund.ts";

// Acionada pelo app logo depois de um cancelamento com taxa paga; se falhar,
// process-appointment-fees conclui. Só participantes do agendamento chamam.
export default {
  fetch: withSupabase<AsaasDatabase>({ auth: "user" }, async (request, ctx) => {
    if (request.method !== "POST") return new Response(null, { status: 405 });
    let body: { appointmentId?: string };
    try {
      body = await request.json();
    } catch {
      return Response.json({ message: "Dados inválidos." }, { status: 400 });
    }
    if (!body.appointmentId)
      return Response.json({ message: "Agendamento obrigatório." }, { status: 400 });
    const visible = await ctx.supabase.rpc("get_service_appointment_detail", {
      p_id: body.appointmentId,
    });
    if (visible.error || !visible.data?.length)
      return Response.json({ message: "Agendamento indisponível." }, { status: 404 });
    const { data: charge } = await ctx.supabaseAdmin
      .from("service_payment_charges")
      .select("id")
      .eq("appointment_id", body.appointmentId)
      .not("refund_requested_at", "is", null)
      .maybeSingle();
    if (!charge) return Response.json({ state: "skipped" }, { status: 202 });
    try {
      const result = await refundAppointmentCharge(ctx.supabaseAdmin, charge.id);
      return Response.json(result, { status: result.state === "refunded" ? 200 : 202 });
    } catch {
      return Response.json({ state: "processing" }, { status: 202 });
    }
  }),
};
