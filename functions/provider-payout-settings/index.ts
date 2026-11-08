import { withSupabase } from "npm:@supabase/server@1.4.1";
import type { AsaasDatabase } from "../_shared/asaas-database.ts";
import { hmacDocument } from "../_shared/auth.ts";

const mask = (key: string | null) => (key ? `•••• ${key.slice(-4)}` : null);
export default {
  fetch: withSupabase<AsaasDatabase>({ auth: "user" }, async (request, ctx) => {
    if (request.method !== "POST") return new Response(null, { status: 405 });
    const {
      data: { user },
    } = await ctx.supabase.auth.getUser();
    if (!user?.email)
      return Response.json({ message: "Entre novamente." }, { status: 401 });
    const { data: account } = await ctx.supabaseAdmin
      .from("provider_asaas_accounts")
      .select("provider_id,payout_pix_key,payout_pix_type")
      .eq("provider_id", user.id)
      .maybeSingle();
    if (!account)
      return Response.json(
        { message: "Complete primeiro o cadastro financeiro." },
        { status: 409 }
      );
    let input;
    try {
      input = await request.json();
    } catch {
      return Response.json({ message: "Dados inválidos." }, { status: 400 });
    }
    if (input.action === "read")
      return Response.json({
        maskedKey: mask(account.payout_pix_key),
        type: account.payout_pix_type,
      });
    if (input.action !== "save")
      return Response.json({ message: "Ação inválida." }, { status: 400 });
    const type = String(input.type ?? "");
    const key = String(input.key ?? "").replace(/\D/g, "");
    // Sem prova de titularidade para chaves mascaradas, falha de forma explícita.
    if (!["CPF", "CNPJ"].includes(type))
      return Response.json(
        {
          message:
            "Nesta versão, use a chave CPF/CNPJ do titular cadastrado. Outros tipos dependem de verificação de titularidade.",
        },
        { status: 400 }
      );
    if (key.length !== (type === "CPF" ? 11 : 14))
      return Response.json({ message: "Revise a chave Pix." }, { status: 400 });
    const { data: profile } = await ctx.supabaseAdmin
      .from("profiles")
      .select("document_hash")
      .eq("id", user.id)
      .single();
    if (
      !profile?.document_hash ||
      (await hmacDocument(key)) !== profile.document_hash
    )
      return Response.json(
        {
          message:
            "A chave deve ser o CPF/CNPJ do titular do cadastro financeiro.",
        },
        { status: 400 }
      );
    if (typeof input.password !== "string" || !input.password)
      return Response.json(
        { message: "Confirme sua senha para alterar o destino." },
        { status: 400 }
      );
    const verification = await ctx.supabase.auth.signInWithPassword({
      email: user.email,
      password: input.password,
    });
    if (verification.error || verification.data.user?.id !== user.id)
      return Response.json({ message: "Senha inválida." }, { status: 403 });
    const { error } = await ctx.supabaseAdmin
      .from("provider_asaas_accounts")
      .update({ payout_pix_key: key, payout_pix_type: type })
      .eq("provider_id", user.id);
    return error
      ? Response.json({ message: "Não foi possível salvar." }, { status: 503 })
      : Response.json({ saved: true, maskedKey: mask(key), type });
  }),
};
