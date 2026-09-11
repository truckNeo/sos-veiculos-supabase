// Helpers do Asaas. ASAAS_ENV controla sandbox vs. produção — mantemos o
// sandbox disponível indefinidamente (não é um "modo mock" à parte: o
// sandbox do Asaas processa PIX/split/transferências de verdade dentro do
// ambiente de testes, então usamos a própria API, só que apontando pra lá).

export const asaasEnv = (): 'sandbox' | 'production' =>
  Deno.env.get('ASAAS_ENV') === 'production' ? 'production' : 'sandbox';

export const isAsaasSandbox = () => asaasEnv() === 'sandbox';

export const asaasBaseUrl = () =>
  isAsaasSandbox() ? 'https://api-sandbox.asaas.com/v3' : 'https://api.asaas.com/v3';

/** Chave da conta mestre (plataforma) para o ambiente atual. */
export const asaasMasterToken = (): string => {
  const key = isAsaasSandbox()
    ? Deno.env.get('ASAAS_SANDBOX_API_KEY')
    : Deno.env.get('ASAAS_PRODUCTION_API_KEY');
  if (!key) throw new Error(`Asaas (${asaasEnv()}) não configurado nesta função.`);
  return key;
};

export type AsaasFetchOptions = {
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE';
  body?: Record<string, unknown>;
  /** access_token a usar; default é a chave da conta mestre do ambiente atual. */
  key?: string;
};

export const asaasFetch = (path: string, opts: AsaasFetchOptions = {}) =>
  fetch(`${asaasBaseUrl()}${path}`, {
    method: opts.method ?? (opts.body ? 'POST' : 'GET'),
    headers: {
      access_token: opts.key ?? asaasMasterToken(),
      'Content-Type': 'application/json',
      'User-Agent': 'sos-veiculos-asaas',
    },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });

export const parseAsaasError = async (response: Response) => {
  const text = await response.text();
  try {
    const parsed = JSON.parse(text) as {errors?: Array<{description?: string}>; message?: string};
    return parsed.errors?.map(e => e.description).filter(Boolean).join(' | ') || parsed.message || text;
  } catch {
    return text;
  }
};

// --- Cifra da chave de API da subconta (necessária pra sacar em nome dela) ---
// AES-GCM com chave fixa em ASAAS_PROVIDER_TOKEN_ENCRYPTION_KEY (32 bytes, base64).

const importEncryptionKey = async () => {
  const raw = Deno.env.get('ASAAS_PROVIDER_TOKEN_ENCRYPTION_KEY');
  if (!raw) throw new Error('ASAAS_PROVIDER_TOKEN_ENCRYPTION_KEY não configurado.');
  const bytes = Uint8Array.from(atob(raw), c => c.charCodeAt(0));
  return crypto.subtle.importKey('raw', bytes, {name: 'AES-GCM'}, false, ['encrypt', 'decrypt']);
};

const toBase64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const fromBase64 = (value: string) => Uint8Array.from(atob(value), c => c.charCodeAt(0));

export const encryptProviderApiKey = async (plainApiKey: string) => {
  const key = await importEncryptionKey();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({name: 'AES-GCM', iv}, key, new TextEncoder().encode(plainApiKey));
  return {ciphertext: toBase64(new Uint8Array(encrypted)), iv: toBase64(iv)};
};

export const decryptProviderApiKey = async (ciphertextB64: string, ivB64: string) => {
  const key = await importEncryptionKey();
  const decrypted = await crypto.subtle.decrypt(
    {name: 'AES-GCM', iv: fromBase64(ivB64)}, key, fromBase64(ciphertextB64),
  );
  return new TextDecoder().decode(decrypted);
};
