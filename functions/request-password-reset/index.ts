import {withSupabase} from 'npm:@supabase/server';

import {
  hmacDocument,
  normalizeBrazilianPhone,
  normalizeDigits,
} from '../_shared/auth.ts';

const EMAIL_REDIRECT_URL = 'https://www.truckneo.com.br/recuperar-senha';

export default {
  fetch: withSupabase({auth: 'publishable'}, async (request, ctx) => {
    try {
      const {identifier} = await request.json() as {identifier?: string};
      const rawIdentifier = identifier?.trim() ?? '';
      const digits = normalizeDigits(rawIdentifier);

      if (!rawIdentifier || !digits) {
        return Response.json({message: 'Informe seu CPF ou telefone.'}, {status: 400});
      }

      let profileQuery = ctx.supabaseAdmin.from('profiles').select('id').limit(1);
      if (digits.length === 11 || digits.length === 14) {
        profileQuery = profileQuery.eq('document_hash', await hmacDocument(digits));
      } else {
        const phone = normalizeBrazilianPhone(rawIdentifier);
        if (!phone) {
          return Response.json({message: 'CPF ou telefone inválido.'}, {status: 400});
        }
        profileQuery = profileQuery.eq('phone_lookup', normalizeDigits(phone));
      }

      const {data: profile, error: profileError} = await profileQuery.maybeSingle();
      if (profileError) {
        throw profileError;
      }

      // Sempre retornamos sucesso para não revelar se o identificador existe.
      if (!profile) {
        return Response.json({accepted: true});
      }

      const {data: userData, error: userError} = await ctx.supabaseAdmin.auth.admin.getUserById(profile.id);
      if (userError || !userData.user?.email) {
        throw userError ?? new Error('E-mail da conta não encontrado.');
      }

      const {error: resetError} = await ctx.supabase.auth.resetPasswordForEmail(
        userData.user.email,
        {redirectTo: EMAIL_REDIRECT_URL},
      );
      if (resetError) {
        throw resetError;
      }

      return Response.json({accepted: true});
    } catch (error) {
      console.error('request-password-reset failed', error);
      return Response.json(
        {message: 'Não foi possível enviar o link agora. Tente novamente em instantes.'},
        {status: 500},
      );
    }
  }),
};
