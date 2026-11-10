import { withSupabase } from "npm:@supabase/server@1.4.1";
import type { AsaasDatabase } from "../_shared/asaas-database.ts";
import { reconcileDispatchTransfer } from "../_shared/dispatch-transfer.ts";

// Compatível com clientes anteriores: avaliação nunca dispara um novo repasse.
export default {
  fetch: withSupabase<AsaasDatabase>({ auth: "user" }, async (request, ctx) => {
    if (request.method !== "POST") return new Response(null, { status: 405 });
    let body: { requestId?: string; rating?: number; comment?: string | null };
    try {
      body = await request.json();
    } catch {
      return Response.json({ message: "Dados inválidos." }, { status: 400 });
    }
    if (!body.requestId)
      return Response.json(
        { message: "Atendimento obrigatório." },
        { status: 400 }
      );
    if (body.rating !== undefined) {
      const { error } = await ctx.supabase.rpc("complete_service_with_review", {
        p_request_id: body.requestId,
        p_rating: body.rating,
        p_comment: body.comment ?? null,
      });
      return error
        ? Response.json(
            {
              message:
                "Não foi possível registrar a avaliação. Confira o estado do atendimento.",
            },
            { status: 409 }
          )
        : Response.json({ released: true, reviewSaved: true });
    }
    const { error } = await ctx.supabase.rpc("confirm_provider_arrival", {
      p_request_id: body.requestId,
    });
    if (error)
      return Response.json({ message: error.message }, { status: 409 });
    const { data: transfer } = await ctx.supabase
      .from("service_provider_transfers")
      .select("id")
      .eq("request_id", body.requestId)
      .single();
    if (!transfer)
      return Response.json(
        { arrivalConfirmed: true, state: "processing" },
        { status: 202 }
      );
    try {
      const result = await reconcileDispatchTransfer(
        ctx.supabaseAdmin,
        transfer.id
      );
      return Response.json(
        { arrivalConfirmed: true, ...result },
        { status: result.state === "completed" ? 200 : 202 }
      );
    } catch {
      return Response.json(
        { arrivalConfirmed: true, state: "processing" },
        { status: 202 }
      );
    }
  }),
};
