import {withSupabase} from 'npm:@supabase/server';

import {
  hmacDocument,
  normalizeDigits,
} from '../_shared/auth.ts';

export default {
  fetch: withSupabase({auth: 'publishable'}, async (request, ctx) => {
    const {identifier, password} = await request.json();
    if (typeof identifier !== 'string' || typeof password !== 'string' || !password) {
      return Response.json({message: 'Informe seu CPF ou CNPJ e a senha.'}, {status: 400});
    }
    const digits = normalizeDigits(identifier);
    if (digits.length !== 11 && digits.length !== 14) {
      return Response.json({message: 'Informe um CPF com 11 dígitos ou um CNPJ com 14 dígitos.'}, {status: 400});
    }

    const profileQuery = ctx.supabaseAdmin.from('profiles').select('id').limit(1)
      .eq('document_hash', await hmacDocument(digits));

    const {data: profile, error: profileError} = await profileQuery.maybeSingle();
    if (profileError) {
      throw profileError;
    }
    if (!profile) {
      return Response.json({message: 'Credenciais inválidas.'}, {status: 401});
    }

    const {data: userData, error: userError} = await ctx.supabaseAdmin.auth.admin.getUserById(profile.id);
    if (userError || !userData.user?.email) {
      throw userError ?? new Error('Usuário não encontrado.');
    }

    const {data: sessionData, error: signInError} = await ctx.supabase.auth.signInWithPassword({
      email: userData.user.email,
      password,
    });
    if (signInError?.code === 'email_not_confirmed') {
      return Response.json({
        code: 'email_not_confirmed',
        email: userData.user.email,
        message: 'Confirme seu e-mail para entrar. Reenvie o link de confirmação se precisar.',
      }, {status: 403});
    }
    if (signInError || !sessionData.session) {
      return Response.json({message: signInError?.message ?? 'Credenciais inválidas.'}, {status: 401});
    }

    return Response.json({session: sessionData.session});
  }),
};
