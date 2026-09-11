/**
 * PoC — Pagamento retido (marketplace) no sandbox do Asaas — PIX de ponta a ponta.
 *
 * DESCOBERTA DA 1ª RODADA: "Split de pagamento" + "Conta Escrow" NÃO produzem o
 * efeito "retido até liberar". O split é executado no momento do recebimento e o
 * valor cai DISPONÍVEL na subconta do mecânico. A Conta Escrow só retém cobranças
 * emitidas pela própria subconta, não créditos de split.
 *
 * Portanto esta PoC usa o modelo que entrega a retenção de verdade:
 *
 *   cobrança PIX SEM split  ->  100% retido na conta da plataforma (conta mestre)
 *   serviço concluído       ->  POST /transfers (parte líquida) para o mecânico:
 *                                 - produção: operationType=PIX para a CHAVE PIX da subconta
 *                                 - sandbox : transferência interna por walletId (a subconta
 *                                             sandbox não registra chave PIX; PIX p/ conta
 *                                             bancária fake FALHA)
 *
 * (Mesmo princípio do código Iugu atual: conta mestre segura, repassa depois.)
 *
 * Fluxo do app SOS Veículos:
 *
 *   1. setup-provider  -> subconta do mecânico + conta bancária + chave PIX (EVP)
 *   2. create-customer -> cliente
 *   3. create-charge   -> "mecânico envia o link": cobrança PIX SEM split
 *   4. link            -> PIX copia-e-cola / URL da fatura para o cliente
 *   5. pay             -> "cliente paga" (simulação sandbox) -> valor retido na plataforma
 *   6. status          -> saldo retido na plataforma; mecânico ainda zerado
 *   7. release         -> "serviço concluído e OK": POST /transfers PIX (líquido p/ o mecânico)
 *   8. balance         -> saldo do mecânico (recebeu o repasse) e da plataforma (ficou a comissão)
 *
 *   all                -> executa 1..8 (só o caminho feliz; sem disputa/reembolso).
 *
 * Comandos extras: whoami, provider-pix-key, escrow-probe (reproduz a descoberta), state, reset.
 *
 * Uso:
 *   cp .env.example .env   # e preencha ASAAS_API_KEY (chave sandbox da conta mestre PJ)
 *   node --env-file=.env asaas-escrow-poc.ts all
 *
 * Requer Node >= 22 (type stripping + fetch + --env-file nativos).
 */

import { readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const STATE_FILE = join(HERE, '.asaas-poc-state.json');

const BASE_URL = (process.env.ASAAS_BASE_URL ?? 'https://api-sandbox.asaas.com/v3').replace(/\/+$/, '');
const API_KEY = process.env.ASAAS_API_KEY ?? '';
const COMMISSION_PERCENT = Number(process.env.POC_COMMISSION_PERCENT ?? '10'); // % que fica com a plataforma
const CHARGE_VALUE = Number(process.env.POC_VALUE ?? '150.00'); // valor total da cobrança (R$)
const ESCROW_DAYS = Number(process.env.POC_ESCROW_DAYS ?? '30'); // usado só em escrow-probe

if (!API_KEY) {
  console.error('Falta ASAAS_API_KEY. Rode com: node --env-file=.env asaas-escrow-poc.ts <comando>');
  process.exit(1);
}
if (!BASE_URL.includes('sandbox')) {
  console.error(`ASAAS_BASE_URL não parece ser sandbox: ${BASE_URL}. Abortando por segurança.`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Estado persistido entre execuções
// ---------------------------------------------------------------------------

type State = {
  provider?: { accountId: string; walletId: string; apiKey: string; cpfCnpj: string; email: string; pixKey?: string };
  customer?: { id: string; cpfCnpj: string };
  charge?: { id: string; value: number; netValue?: number; status: string; invoiceUrl?: string; pixPayload?: string };
  transfer?: { id: string; value: number; status: string };
};

const loadState = (): State => (existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, 'utf8')) : {});
const saveState = (s: State) => writeFileSync(STATE_FILE, JSON.stringify(s, null, 2) + '\n');

// ---------------------------------------------------------------------------
// Cliente HTTP Asaas
// ---------------------------------------------------------------------------

type Json = Record<string, unknown>;

async function asaas<T = any>(
  method: 'GET' | 'POST' | 'PUT' | 'DELETE',
  path: string,
  opts: { body?: Json; key?: string; keyLabel?: string } = {},
): Promise<T> {
  const key = opts.key ?? API_KEY;
  const res = await fetch(`${BASE_URL}${path}`, {
    method,
    headers: {
      access_token: key,
      'Content-Type': 'application/json',
      'User-Agent': 'sos-veiculos-asaas-escrow-poc',
    },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });

  const text = await res.text();
  let parsed: any;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { raw: text };
  }

  const tag = opts.keyLabel ? ` [${opts.keyLabel}]` : '';
  console.log(`  → ${method} ${path}${tag}  ${res.status}`);
  if (opts.body) console.log(`    req: ${JSON.stringify(opts.body)}`);

  if (!res.ok) {
    const errs = parsed?.errors?.map((e: any) => e.description).join(' | ') || parsed?.message || text;
    console.log(`    err: ${errs}`);
    throw new Error(`Asaas ${method} ${path} -> ${res.status}: ${errs}`);
  }
  return parsed as T;
}

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------

const step = (title: string) => console.log(`\n=== ${title} ===`);
const brl = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const show = (label: string, obj: unknown) => console.log(`    ${label}: ${JSON.stringify(obj)}`);
const round2 = (v: number) => Math.round(v * 100) / 100;

/** CPF sintaticamente válido (para o sandbox aceitar subconta / cliente). */
function fakeCpf(): string {
  const n = Array.from({ length: 9 }, () => Math.floor(Math.random() * 10));
  const digit = (base: number[]) => {
    const sum = base.reduce((acc, d, i) => acc + d * (base.length + 1 - i), 0);
    const mod = (sum * 10) % 11;
    return mod === 10 ? 0 : mod;
  };
  const d1 = digit(n);
  const d2 = digit([...n, d1]);
  return [...n, d1, d2].join('');
}

async function getBalance(key: string, label: string) {
  const bal = await asaas<any>('GET', '/finance/balance', { key, keyLabel: label });
  return Number(bal.balance ?? 0);
}

// ---------------------------------------------------------------------------
// Passos
// ---------------------------------------------------------------------------

async function whoami() {
  step('Conta mestre — quem sou eu (GET /myAccount)');
  const me = await asaas<any>('GET', '/myAccount');
  const acc = me.account ?? me;
  show('personType', acc.personType);
  show('cpfCnpj', acc.cpfCnpj);
  show('companyType', acc.companyType);
  show('name / email', { name: acc.name, email: acc.email });
  if (acc.personType && acc.personType !== 'JURIDICA') {
    console.log('  >> conta é PESSOA FÍSICA — não cria subcontas. Use uma conta sandbox PJ.');
  }
}

async function setupProvider(state: State) {
  step('1. Criar subconta do mecânico (POST /accounts)');
  if (state.provider) {
    console.log(`  já existe: accountId=${state.provider.accountId} walletId=${state.provider.walletId}`);
    return;
  }
  const stamp = Date.now();
  const cpf = fakeCpf();
  const email = `mecanico.poc+${stamp}@example.com`;
  const acc = await asaas<any>('POST', '/accounts', {
    body: {
      name: `Mecânico PoC ${stamp}`,
      email,
      loginEmail: email,
      cpfCnpj: cpf,
      birthDate: '1990-01-01',
      mobilePhone: '11987654321',
      incomeValue: 5000,
      address: 'Avenida Paulista',
      addressNumber: '1000',
      complement: 'Sala 1',
      province: 'Bela Vista',
      postalCode: '01310930',
    },
  });
  const apiKey = acc.apiKey ?? acc.accessToken?.apiKey ?? acc.accessToken;
  if (!acc.walletId || !apiKey) {
    show('resposta', acc);
    throw new Error('Resposta de /accounts sem walletId ou apiKey.');
  }
  state.provider = { accountId: acc.id, walletId: acc.walletId, apiKey, cpfCnpj: cpf, email };
  saveState(state);
  console.log(`  OK  accountId=${acc.id}`);
  console.log(`      walletId=${acc.walletId}`);
  console.log(`      apiKey=${String(apiKey).slice(0, 12)}… (salvo em .asaas-poc-state.json)`);
  await providerBank(state);
  await providerDocs(state);
  await sleep(2000);
  if (await approveProvider(state)) await providerPixKey(state);
}

/**
 * Cria a chave PIX (aleatória / EVP) da subconta — destino ideal do repasse.
 * ATENÇÃO: no sandbox a subconta BaaS/White Label costuma barrar aqui com
 * "não está totalmente aprovada para utilizar o Pix" (falta prova de vida, que
 * não é simulável). Nesse caso o release cai no repasse PIX para a conta
 * bancária cadastrada. Best-effort: não interrompe o fluxo.
 */
async function providerPixKey(state: State) {
  if (!state.provider) throw new Error('Rode "setup-provider" antes.');
  if (state.provider.pixKey) {
    console.log(`  chave PIX da subconta já existe: ${state.provider.pixKey}`);
    return;
  }
  console.log('  criando chave PIX (EVP) da subconta (POST /pix/addressKeys)…');
  try {
    const created = await asaas<any>('POST', '/pix/addressKeys', {
      key: state.provider.apiKey,
      keyLabel: 'subconta',
      body: { type: 'EVP' },
    });
    let key = created.key ?? null;
    let st = created.status;
    for (let i = 0; i < 6 && (st !== 'ACTIVE' || !key); i++) {
      await sleep(3000);
      const one = await asaas<any>('GET', `/pix/addressKeys/${created.id}`, {
        key: state.provider.apiKey,
        keyLabel: 'subconta',
      });
      key = one.key ?? key;
      st = one.status;
    }
    if (!key) throw new Error(`chave PIX sem valor utilizável (status=${st})`);
    state.provider.pixKey = key;
    saveState(state);
    console.log(`  OK  chave PIX=${key}  status=${st}`);
  } catch (e) {
    console.log(`  (chave PIX indisponível: ${(e as Error).message})`);
    console.log('  -> limitação do sandbox; o release usa transferência interna por walletId.');
  }
}

/** Cadastra a conta bancária da subconta (satisfaz bankAccountInfo). */
async function providerBank(state: State) {
  if (!state.provider) throw new Error('Rode "setup-provider" antes.');
  console.log('  cadastrando conta bancária da subconta (POST /bankAccounts)…');
  try {
    const r = await asaas<any>('POST', '/bankAccounts', {
      key: state.provider.apiKey,
      keyLabel: 'subconta',
      body: {
        bank: { code: '341' },
        accountName: 'Conta PoC',
        ownerName: `Mecânico PoC`,
        cpfCnpj: state.provider.cpfCnpj,
        agency: '1234',
        account: '56789',
        accountDigit: '0',
        bankAccountType: 'CONTA_CORRENTE',
      },
    });
    show('bankAccount', { id: r.id, bank: r.bank?.code, status: r.status });
  } catch (e) {
    console.log(`  (bankAccounts: ${(e as Error).message})`);
  }
}

/** Tenta enviar o documento de identificação pendente (sandbox). */
async function providerDocs(state: State) {
  if (!state.provider) throw new Error('Rode "setup-provider" antes.');
  console.log('  enviando documento de identificação da subconta…');
  try {
    const list = await asaas<any>('GET', '/myAccount/documents', {
      key: state.provider.apiKey,
      keyLabel: 'subconta',
    });
    for (const group of list.data ?? []) {
      const docId = group.documents?.[0]?.id ?? group.id;
      const png = Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        'base64',
      );
      const fd = new FormData();
      fd.set('type', group.type ?? 'IDENTIFICATION');
      fd.set('documentFile', new Blob([png], { type: 'image/png' }), 'doc.png');
      const res = await fetch(`${BASE_URL}/myAccount/documents/${docId}`, {
        method: 'POST',
        headers: { access_token: state.provider.apiKey, 'User-Agent': 'sos-veiculos-asaas-escrow-poc' },
        body: fd,
      });
      console.log(`    → POST /myAccount/documents/${docId} [subconta]  ${res.status}  ${(await res.text()).slice(0, 200)}`);
    }
  } catch (e) {
    console.log(`  (documents: ${(e as Error).message})`);
  }
}

/**
 * Verifica se a subconta está aprovada (general = APPROVED). Só assim ela pode
 * RECEBER transferências. No sandbox a aprovação é automática SE você tiver ligado
 * "Autoaprovação de subcontas" ANTES de criar a subconta:
 *   Menu do usuário → Minha conta → Configurações → Sandbox → Autoaprovação de subcontas
 */
async function approveProvider(state: State) {
  if (!state.provider) throw new Error('Rode "setup-provider" antes.');
  const tries = Number(process.env.POC_APPROVAL_TRIES ?? '10');
  let st: any = {};
  for (let i = 1; i <= tries; i++) {
    try {
      st = await asaas<any>('GET', '/myAccount/status', { key: state.provider.apiKey, keyLabel: 'subconta' });
    } catch (e) {
      console.log(`  (status cadastral indisponível: ${(e as Error).message})`);
      break;
    }
    if (st.general === 'APPROVED') {
      console.log(`  OK  subconta aprovada (general=APPROVED) — pode receber transferências.`);
      return true;
    }
    console.log(`  tentativa ${i}/${tries}: ${JSON.stringify(st)}`);
    if (i < tries) await sleep(5000);
  }
  console.log('\n  >> subconta ainda NÃO aprovada (general != APPROVED).');
  console.log('     "documentation" só sai de PENDING via link de onboarding OU pela');
  console.log('     autoaprovação do sandbox. No painel sandbox, em Minha conta →');
  console.log('     Configurações → Sandbox, LIGUE as duas opções:');
  console.log('        • BaaS para subcontas');
  console.log('        • Autoaprovação de subcontas');
  console.log('     Depois: node --env-file=.env asaas-escrow-poc.ts reset && … all');
  return false;
}

async function createCustomer(state: State) {
  step('2. Criar cliente (POST /customers)');
  if (state.customer) {
    console.log(`  já existe: ${state.customer.id}`);
    return;
  }
  const cpf = fakeCpf();
  const cust = await asaas<any>('POST', '/customers', {
    body: {
      name: `Cliente PoC ${Date.now()}`,
      cpfCnpj: cpf,
      email: `cliente.poc+${Date.now()}@example.com`,
      mobilePhone: '11912345678',
    },
  });
  state.customer = { id: cust.id, cpfCnpj: cpf };
  saveState(state);
  console.log(`  OK  customerId=${cust.id}`);
}

async function createCharge(state: State) {
  step('3. Mecânico envia o link — cobrança PIX SEM split (POST /payments)');
  if (!state.customer) throw new Error('Rode "create-customer" antes.');
  if (state.charge && state.charge.status !== 'transferred') {
    console.log(`  já existe: paymentId=${state.charge.id} status=${state.charge.status}`);
    return;
  }
  const dueDate = new Date(Date.now() + 3 * 864e5).toISOString().slice(0, 10);
  const pay = await asaas<any>('POST', '/payments', {
    body: {
      customer: state.customer.id,
      billingType: 'PIX',
      value: CHARGE_VALUE,
      dueDate,
      description: 'SOS Veículos — serviço mecânico (PoC retenção)',
      externalReference: `poc-${Date.now()}`,
      // sem split: 100% do líquido fica retido na conta da plataforma até a liberação
    },
  });
  state.charge = { id: pay.id, value: pay.value, netValue: pay.netValue, status: pay.status, invoiceUrl: pay.invoiceUrl };
  saveState(state);
  console.log(`  OK  paymentId=${pay.id} status=${pay.status} value=${brl(pay.value)}`);
  console.log('  (100% será retido na conta da plataforma; o repasse ao mecânico é manual no passo 7)');
}

async function showLink(state: State) {
  step('4. Link de pagamento para o cliente');
  if (!state.charge) throw new Error('Rode "create-charge" antes.');
  console.log(`  Fatura (URL): ${state.charge.invoiceUrl ?? '(sem invoiceUrl)'}`);
  try {
    const qr = await asaas<any>('GET', `/payments/${state.charge.id}/pixQrCode`);
    if (qr.payload) {
      state.charge.pixPayload = qr.payload;
      saveState(state);
      console.log(`  PIX copia-e-cola:\n    ${qr.payload}`);
      console.log(`  expira em: ${qr.expirationDate ?? '(n/d)'}`);
    } else {
      show('pixQrCode', qr);
    }
  } catch (e) {
    console.log(`  (QR PIX indisponível: ${(e as Error).message})`);
    console.log('  -> cadastre uma chave PIX na conta mestre sandbox para gerar o copia-e-cola;');
    console.log('     a URL da fatura acima já funciona para o cliente pagar.');
  }
}

async function pay(state: State) {
  step('5. Cliente paga — simulação sandbox (POST /sandbox/payment/{id}/confirm)');
  if (!state.charge) throw new Error('Rode "create-charge" antes.');
  const res = await asaas<any>('POST', `/sandbox/payment/${state.charge.id}/confirm`, { body: {} });
  state.charge.status = res.status ?? state.charge.status;
  state.charge.netValue = res.netValue ?? state.charge.netValue;
  saveState(state);
  console.log(`  OK  status=${state.charge.status}  netValue=${state.charge.netValue != null ? brl(state.charge.netValue) : 'n/d'}`);
  console.log('  valor caiu no saldo da conta da plataforma (retido).');
}

async function status(state: State) {
  step('6. Inspeção — valor retido na plataforma');
  if (!state.charge) throw new Error('Rode "create-charge" antes.');

  const pay = await asaas<any>('GET', `/payments/${state.charge.id}`, { keyLabel: 'mestre' });
  state.charge.status = pay.status;
  state.charge.netValue = pay.netValue ?? state.charge.netValue;
  saveState(state);
  console.log(`  cobrança: status=${pay.status}  value=${brl(pay.value)}  netValue=${pay.netValue != null ? brl(pay.netValue) : 'n/d'}`);

  const platform = await getBalance(API_KEY, 'mestre');
  console.log(`  saldo plataforma (retido): ${brl(platform)}`);
  if (state.provider) {
    const prov = await getBalance(state.provider.apiKey, 'subconta');
    console.log(`  saldo mecânico: ${brl(prov)}  ${prov === 0 ? '(ainda não recebeu — correto)' : ''}`);
  }

  if (state.charge.netValue != null) {
    const net = round2(state.charge.netValue * (100 - COMMISSION_PERCENT) / 100);
    console.log(`\n  no release: repasse ao mecânico = ${brl(net)}  (${100 - COMMISSION_PERCENT}% do líquido)`);
    console.log(`             comissão retida pela plataforma = ${brl(round2(state.charge.netValue - net))} + tarifas`);
  }
}

async function release(state: State) {
  step('7. Serviço concluído e OK — repassar ao mecânico (POST /transfers)');
  if (!state.provider) throw new Error('Rode "setup-provider" antes.');
  if (!state.charge) throw new Error('Rode "create-charge" antes.');
  if (state.charge.status !== 'RECEIVED' && state.charge.status !== 'CONFIRMED') {
    throw new Error(`Cobrança ainda não paga (status=${state.charge.status}). Rode "pay".`);
  }
  if (state.transfer) {
    console.log(`  já existe: transferId=${state.transfer.id} status=${state.transfer.status}`);
    return;
  }
  if (!state.provider.pixKey) await providerPixKey(state);
  const net = state.charge.netValue;
  if (net == null) throw new Error('Sem netValue da cobrança. Rode "status" primeiro.');
  const providerNet = round2(net * (100 - COMMISSION_PERCENT) / 100);

  let body: Json;
  if (state.provider.pixKey) {
    // Caminho de produção: repasse PIX para a chave da subconta do mecânico.
    console.log(`  repasse PIX para a CHAVE da subconta (${state.provider.pixKey})`);
    body = {
      value: providerNet,
      operationType: 'PIX',
      pixAddressKey: state.provider.pixKey,
      pixAddressKeyType: 'EVP',
      description: `SOS Veículos — repasse serviço ${state.charge.id}`,
      externalReference: state.charge.id,
    };
  } else {
    // Sandbox: a subconta não registra chave PIX (falta prova de vida). O repasse
    // PIX para conta bancária fake FALHA ("Falha ao processar a transferência.").
    // Então usamos a transferência interna Asaas→Asaas por walletId — instantânea,
    // sem tarifa, e é o mecanismo correto quando o mecânico é subconta.
    console.log(`  repasse interno Asaas→Asaas por walletId (${state.provider.walletId})`);
    body = { value: providerNet, walletId: state.provider.walletId };
  }
  const tr = await asaas<any>('POST', '/transfers', { body });
  state.transfer = { id: tr.id, value: tr.value ?? providerNet, status: tr.status };
  state.charge.status = 'transferred';
  saveState(state);
  show('transfer', { id: tr.id, value: tr.value, status: tr.status, authorized: tr.authorized });
  console.log(`  repasse de ${brl(providerNet)} criado (status=${tr.status}).`);
  if (tr.authorized === false) {
    console.log('\n  >> transfer com authorized=false: a conta da plataforma tem "autorização');
    console.log('     de ações críticas" ligada. Para concluir, escolha UMA opção:');
    console.log('       a) Painel sandbox → Transferências → abrir esta transferência →');
    console.log(`          autorizar com o token 000000  (id ${tr.id});`);
    console.log('       b) Configurar o webhook de validação de operações (Configurações →');
    console.log('          Segurança) devolvendo {"status":"APPROVED"} — é assim que se');
    console.log('          automatiza em produção;');
    console.log('       c) Pedir ao suporte Asaas para desligar ações críticas na conta sandbox.');
    console.log('     Depois: node --env-file=.env asaas-escrow-poc.ts balance');
  }
}

async function balance(state: State) {
  step('8. Saldos finais');
  if (state.transfer) {
    try {
      const tr = await asaas<any>('GET', `/transfers/${state.transfer.id}`, { keyLabel: 'mestre' });
      state.transfer.status = tr.status;
      saveState(state);
      show('transfer', { id: tr.id, value: tr.value, status: tr.status, authorized: tr.authorized, operationType: tr.operationType, effectiveDate: tr.effectiveDate, failReason: tr.failReason });
      if (tr.status === 'PENDING') {
        console.log(`  (ainda PENDING${tr.authorized === false ? ' / não autorizada — ver instruções do "release"' : ' — aguardando liquidação'})`);
      } else if (tr.status === 'DONE') {
        console.log(`  ✓ repasse liquidado${tr.transactionReceiptUrl ? ` — comprovante: ${tr.transactionReceiptUrl}` : ''}`);
      } else if (tr.status === 'FAILED' || tr.status === 'CANCELLED') {
        console.log(`  ✗ repasse ${tr.status}: ${tr.failReason ?? 's/ motivo'} — valor devolvido à plataforma.`);
      }
    } catch (e) {
      console.log(`  (não foi possível reconsultar a transferência: ${(e as Error).message})`);
    }
  }
  const platform = await getBalance(API_KEY, 'mestre');
  console.log(`  plataforma (comissão + tarifas retidas): ${brl(platform)}`);
  if (state.provider) {
    const prov = await getBalance(state.provider.apiKey, 'subconta');
    console.log(`  mecânico (repasse recebido): ${brl(prov)}  ${prov > 0 ? '✓' : '(aguardando autorização da transferência)'}`);
  }
}

/** Reproduz a descoberta: split + Conta Escrow NÃO retêm o valor. Só para registro. */
async function escrowProbe(state: State) {
  step('escrow-probe — split + Conta Escrow (resultado conhecido: NÃO retém)');
  if (!state.provider) await setupProvider(state);
  if (!state.customer) await createCustomer(state);

  console.log('\n  ligando Conta Escrow na subconta…');
  await asaas('POST', `/accounts/${state.provider!.accountId}/escrow`, {
    body: { enabled: true, daysToExpire: ESCROW_DAYS, isFeePayer: false },
  });

  console.log('\n  criando cobrança COM split 90/10…');
  const dueDate = new Date(Date.now() + 3 * 864e5).toISOString().slice(0, 10);
  const pay = await asaas<any>('POST', '/payments', {
    body: {
      customer: state.customer!.id,
      billingType: 'PIX',
      value: CHARGE_VALUE,
      dueDate,
      description: 'escrow-probe',
      split: [{ walletId: state.provider!.walletId, percentualValue: 100 - COMMISSION_PERCENT }],
    },
  });
  await asaas('POST', `/sandbox/payment/${pay.id}/confirm`, { body: {} });
  await sleep(3000);

  const after = await asaas<any>('GET', `/payments/${pay.id}`, { keyLabel: 'mestre' });
  show('split', after.split);
  try {
    const esc = await asaas('GET', `/payments/${pay.id}/escrow`, { key: state.provider!.apiKey, keyLabel: 'subconta' });
    show('escrow', esc);
  } catch (e) {
    console.log(`    escrow: ${(e as Error).message}  <- 404 = split não entra no escrow`);
  }
  const prov = await getBalance(state.provider!.apiKey, 'subconta');
  console.log(`\n  saldo do mecânico logo após o pagamento: ${brl(prov)}  (DISPONÍVEL, não retido)`);
  console.log('  conclusão: o split repassa na hora; a Conta Escrow não segura crédito de split.');
}

/** Linha do tempo do último fluxo: pagamento → retenção → liberação → mecânico. */
async function trace(state: State) {
  step('Linha do tempo do fluxo');
  if (!state.charge) throw new Error('Sem cobrança no estado. Rode "all" primeiro.');

  const pay = await asaas<any>('GET', `/payments/${state.charge.id}`, { keyLabel: 'mestre' });
  console.log('\n① COBRANÇA (link enviado ao cliente)');
  console.log(`   id ${pay.id}  ${pay.invoiceUrl ?? ''}`);
  console.log(`   status ${pay.status}  valor ${brl(pay.value)}  billingType ${pay.billingType}`);

  console.log('\n② PAGAMENTO DO CLIENTE');
  const paid = ['RECEIVED', 'CONFIRMED', 'RECEIVED_IN_CASH'].includes(pay.status);
  console.log(`   ${paid ? '✓ pago' : '… aguardando'} — status ${pay.status}`);
  console.log(`   pago em ${pay.paymentDate ?? pay.clientPaymentDate ?? '—'}  confirmado ${pay.confirmedDate ?? '—'}`);
  console.log(`   valor bruto ${brl(pay.value)}  líquido ${pay.netValue != null ? brl(pay.netValue) : '—'}  (taxa Asaas ${pay.netValue != null ? brl(pay.value - pay.netValue) : '—'})`);

  console.log('\n③ RETENÇÃO NA PLATAFORMA (conta mestre)');
  const platform = await getBalance(API_KEY, 'mestre');
  console.log(`   saldo da plataforma agora: ${brl(platform)}`);
  console.log(`   (o líquido da cobrança fica aqui até a liberação; nada de split)`);

  console.log('\n④ LIBERAÇÃO PARA O MECÂNICO (POST /transfers)');
  if (!state.transfer) {
    console.log('   … ainda não liberado (rode "release")');
  } else {
    const tr = await asaas<any>('GET', `/transfers/${state.transfer.id}`, { keyLabel: 'mestre' });
    console.log(`   id ${tr.id}  valor ${brl(tr.value)}  operationType ${tr.operationType}`);
    console.log(`   autorizada pelo webhook? ${tr.authorized === true ? '✓ sim' : tr.authorized === false ? '✗ não (authorized=false)' : '—'}`);
    console.log(`   status ${tr.status}${tr.status === 'DONE' ? '  ✓' : tr.failReason ? `  (${tr.failReason})` : ''}`);
    if (tr.transactionReceiptUrl) console.log(`   comprovante ${tr.transactionReceiptUrl}`);
  }

  console.log('\n⑤ MECÂNICO RECEBEU (subconta)');
  if (state.provider) {
    const prov = await getBalance(state.provider.apiKey, 'subconta');
    console.log(`   saldo da subconta: ${brl(prov)} ${prov > 0 ? '✓' : ''}`);
    const expected = state.charge.netValue != null
      ? round2(state.charge.netValue * (100 - COMMISSION_PERCENT) / 100) : null;
    if (expected != null) console.log(`   esperado (${100 - COMMISSION_PERCENT}% do líquido): ${brl(expected)}`);
  }

  console.log('\n   Comissão da plataforma = líquido − repasse. Ver também:');
  console.log(`   • Painel Asaas → Cobranças / Transferências / Extrato`);
  console.log(`   • Supabase → Edge Functions → asaas-webhook (logs: PAYMENT_RECEIVED, TRANSFER_DONE)`);
}

async function runAll(state: State) {
  await setupProvider(state);
  await createCustomer(state);
  await createCharge(state);
  await showLink(state);
  console.log('\n  … 2s antes de simular o pagamento …');
  await sleep(2000);
  await pay(state);
  console.log('\n  … 3s para processar …');
  await sleep(3000);
  await status(state);
  console.log('\n  … simulando "serviço concluído e conferido pelo cliente" …');
  if (!(await approveProvider(state))) {
    console.log('\n  Cobrança paga e retida na plataforma; repasse (release) travado até a');
    console.log('  subconta ser aprovada. Rode "release" depois que ela aprovar.');
    return;
  }
  await providerPixKey(state);
  await release(state);
  console.log('\n  … 3s …');
  await sleep(3000);
  await balance(state);
  step('Fim — caminho feliz concluído (retido → liberado)');
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const COMMANDS: Record<string, (s: State) => Promise<void>> = {
  whoami: () => whoami(),
  'setup-provider': setupProvider,
  'approve-provider': approveProvider,
  'provider-bank': providerBank,
  'provider-docs': providerDocs,
  'provider-pix-key': providerPixKey,
  'provider-onboarding': async (s) => {
    if (!s.provider) throw new Error('Rode "setup-provider" antes.');
    step('Diagnóstico de onboarding da subconta');
    const k = s.provider.apiKey;
    for (const p of ['/myAccount/status', '/myAccount/documents', '/myAccount/commercialInfo', '/bankAccounts']) {
      try {
        show(p, await asaas('GET', p, { key: k, keyLabel: 'subconta' }));
      } catch (e) {
        console.log(`    ${p}: ${(e as Error).message}`);
      }
    }
  },
  'create-customer': createCustomer,
  'create-charge': createCharge,
  link: showLink,
  pay,
  status,
  release,
  balance,
  trace,
  all: runAll,
  'escrow-probe': escrowProbe,
  'webhook-selftest': async () => {
    step('webhook-selftest — simula o POST do Asaas no seu webhook de validação');
    const url = process.env.ASAAS_WEBHOOK_URL;
    const token = process.env.ASAAS_OPERATION_WEBHOOK_TOKEN;
    if (!url || !token) {
      throw new Error('Defina ASAAS_WEBHOOK_URL e ASAAS_OPERATION_WEBHOOK_TOKEN no .env.');
    }
    const body = {
      type: 'TRANSFER',
      transfer: {
        object: 'transfer', id: 'selftest-' + Date.now(), status: 'PENDING',
        value: CHARGE_VALUE * (100 - COMMISSION_PERCENT) / 100, netValue: 0,
        operationType: 'PIX', description: 'selftest', externalReference: 'poc-selftest',
      },
    };
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'asaas-access-token': token },
      body: JSON.stringify(body),
    });
    console.log(`  → POST ${url}  ${res.status}`);
    console.log(`  resposta: ${await res.text()}`);
    console.log('  esperado: 200 {"status":"APPROVED"}');
  },
  state: async (s) => console.log(JSON.stringify(s, null, 2)),
  reset: async () => {
    if (existsSync(STATE_FILE)) rmSync(STATE_FILE);
    console.log('Estado local apagado. (Contas/cobranças no sandbox NÃO são removidas.)');
  },
};

const cmd = process.argv[2];
if (!cmd || !COMMANDS[cmd]) {
  console.log('Comandos:', Object.keys(COMMANDS).join(', '));
  console.log('Ex.: node --env-file=.env asaas-escrow-poc.ts all');
  process.exit(cmd ? 1 : 0);
}

console.log(`Asaas PoC — base=${BASE_URL}`);
COMMANDS[cmd](loadState()).catch((e) => {
  console.error(`\nFALHOU: ${e.message}`);
  process.exit(1);
});
