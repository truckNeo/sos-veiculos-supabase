export const normalizeDigits = (value: string) => value.replace(/\D/g, '');

export const normalizeBrazilianPhone = (value: string) => {
  const digits = normalizeDigits(value);
  const localNumber = digits.startsWith('55') && digits.length >= 12
    ? digits.slice(2)
    : digits;

  if (localNumber.length !== 10 && localNumber.length !== 11) {
    return null;
  }

  return `+55${localNumber}`;
};

export const hmacDocument = async (document: string) => {
  const secret = Deno.env.get('DOCUMENT_HASH_SECRET');
  if (!secret) {
    throw new Error('DOCUMENT_HASH_SECRET não configurado.');
  }

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    {name: 'HMAC', hash: 'SHA-256'},
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign(
    'HMAC', key, new TextEncoder().encode(document));

  return [...new Uint8Array(signature)]
    .map(byte => byte.toString(16).padStart(2, '0'))
    .join('');
};
