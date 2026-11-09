import { reconcilePayment } from "../_shared/payment-reconciliation.ts";
import { reconcileWithdrawal } from "../_shared/withdrawal-reconciliation.ts";
import { withSupabase } from "npm:@supabase/server@1.4.1";
import type { AsaasDatabase } from "../_shared/asaas-database.ts";
import { reconcileDispatchTransfer } from "../_shared/dispatch-transfer.ts";

export default {
  fetch: withSupabase<AsaasDatabase>(
    { auth: "secret" },
    async (request, ctx) => {
      if (request.method !== "POST") return new Response(null, { status: 405 });
      const overdue = await ctx.supabaseAdmin.rpc("process_overdue_dispatch_arrivals");
      if (overdue.error) console.error("Liberação automática pendente", overdue.error.message);
      const charges = await ctx.supabaseAdmin
        .from("service_payment_charges")
        .select("id,asaas_payment_id")
        .in("status", ["awaiting_payment", "paid"])
        .is("settled_at", null)
        .not("asaas_payment_id", "is", null)
        .order("updated_at")
        .limit(10);
      if (charges.error)
        return Response.json(
          { message: "Fila de cobranças indisponível." },
          { status: 503 }
        );
      for (const charge of charges.data ?? []) {
        try {
          await ctx.supabaseAdmin
            .from("service_payment_charges")
            .update({ updated_at: new Date().toISOString() })
            .eq("id", charge.id);
          await reconcilePayment(ctx.supabaseAdmin, charge.asaas_payment_id!);
        } catch {
          /* Still pending; notification or a later reconciliation completes it. */
        }
      }
      const { data: rows, error } = await ctx.supabaseAdmin
        .from("service_provider_transfers")
        .select("id")
        .in("status", ["pending", "processing", "manual_review"])
        .order("updated_at")
        .limit(10);
      if (error)
        return Response.json(
          { message: "Fila indisponível." },
          { status: 503 }
        );
      const results: Record<string, number> = {
        completed: 0,
        processing: 0,
        failed: 0,
        manual_review: 0,
      };
      for (const row of rows ?? []) {
        try {
          await ctx.supabaseAdmin
            .from("service_provider_transfers")
            .update({ updated_at: new Date().toISOString() })
            .eq("id", row.id);
          const result = await reconcileDispatchTransfer(
            ctx.supabaseAdmin,
            row.id
          );
          results[result.state]++;
        } catch {
          results.manual_review++;
        }
      }
      const withdrawals = await ctx.supabaseAdmin
        .from("provider_asaas_withdrawals")
        .select("id")
        .in("status", ["requested", "manual_review"])
        .order("updated_at")
        .limit(10);
      if (withdrawals.error)
        return Response.json(
          { message: "Fila de saques indisponível." },
          { status: 503 }
        );
      for (const row of withdrawals.data ?? []) {
        try {
          await ctx.supabaseAdmin
            .from("provider_asaas_withdrawals")
            .update({ updated_at: new Date().toISOString() })
            .eq("id", row.id);
          await reconcileWithdrawal(ctx.supabaseAdmin, row.id);
        } catch {
          results.manual_review++;
        }
      }
      return Response.json(results);
    }
  ),
};
