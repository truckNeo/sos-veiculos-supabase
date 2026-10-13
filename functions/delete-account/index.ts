import {withSupabase} from 'npm:@supabase/server@1.4.1';

/**
 * Exclusão de conta pedida pelo próprio usuário.
 *
 * A RPC anonimiza os dados pessoais; aqui o acesso é encerrado de vez.
 * O usuário do auth não é apagado porque profiles é referenciado com
 * `on delete restrict` por atendimentos, veículos e organizações, que têm
 * retenção fiscal. Banir resolve o que importa: ninguém mais entra com
 * aquela credencial.
 */
export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    if (request.method !== 'POST') return new Response(null, {status: 405});

    const {data: {user}} = await ctx.supabase.auth.getUser();
    if (!user) return Response.json({message: 'Sessão inválida.'}, {status: 401});

    const {error: rpcError} = await ctx.supabase.rpc('request_account_deletion');
    if (rpcError) {
      // Regra de negócio (atendimento em andamento) volta como 409 para a UI
      // poder explicar o motivo em vez de mostrar erro genérico.
      return Response.json({message: rpcError.message}, {status: 409});
    }

    const {error: banError} = await ctx.supabaseAdmin.auth.admin.updateUserById(user.id, {
      ban_duration: '876000h',
    });
    if (banError) {
      // Os dados já foram anonimizados: reportar para investigação, sem
      // fingir que deu tudo certo.
      console.error('delete-account: falha ao bloquear o acesso', banError.message);
      return Response.json(
        {message: 'Dados removidos, mas o acesso não pôde ser bloqueado. Procure o suporte.'},
        {status: 500},
      );
    }

    return Response.json({deleted: true});
  }),
};
