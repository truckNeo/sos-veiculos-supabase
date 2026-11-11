import {withSupabase} from 'npm:@supabase/server';

const EMAIL_REDIRECT_URL = 'https://www.truckneo.com.br/confirmar-conta';

export default {
  fetch: withSupabase({auth: 'publishable'}, async (request, ctx) => {
    try {
      const {email} = await request.json() as {email?: unknown};
      const normalized = typeof email === 'string' ? email.trim().toLowerCase() : '';
      if (!normalized.includes('@')) {
        return Response.json({message: 'Informe um e-mail válido.'}, {status: 400});
      }

      const {error} = await ctx.supabase.auth.resend({
        type: 'signup',
        email: normalized,
        options: {emailRedirectTo: EMAIL_REDIRECT_URL},
      });
      if (error?.code === 'over_email_send_rate_limit' || error?.status === 429) {
        return Response.json(
          {message: 'Aguarde alguns instantes antes de pedir um novo e-mail.'},
          {status: 429},
        );
      }
      if (error) {
        console.warn('resend-confirmation rejected', error.code ?? error.message);
      }

      // Resposta idêntica para e-mail inexistente ou já confirmado, sem revelar contas.
      return Response.json({accepted: true});
    } catch (error) {
      console.error('resend-confirmation failed', error);
      return Response.json(
        {message: 'Não foi possível reenviar o e-mail agora. Tente novamente em instantes.'},
        {status: 500},
      );
    }
  }),
};
