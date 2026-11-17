# Suporte: diagnóstico do cadastro financeiro (Asaas)

Guia para quando for criada a tela de suporte do administrador. Descreve a função
`asaas-account-diagnostics`, que já está publicada, e o que a tela precisa fazer em volta dela.

## 1. Para que serve
Quando um prestador está dias com o cadastro "em análise", a tela de status do app só diz
"em análise". A função consulta o Asaas com a chave da subconta dele e responde **qual parte está
pendente e quais documentos faltam ou foram recusados**. Ela só lê: não altera nada e nunca devolve
chaves de API nem links de onboarding.

## 2. Como o status chega ao app (contexto)
- O Asaas **não envia ao nosso webhook** os eventos de conta das subcontas (`ACCOUNT_STATUS_...`).
  Nenhum chegou até hoje.
- A aprovação ou recusa entra no banco por consulta: `process-appointment-fees` (acionada pelo
  pg_cron quando há conta em `verification_requested`) chama `/myAccount/status` com a chave da
  subconta e muda `provider_asaas_accounts.status`. O gatilho
  `provider_asaas_accounts_notify_decision` envia o push ao prestador.
- O botão "Recuperar link de verificação" do app também confere na hora
  (`asaas-provider-onboarding`).
- Código: `supabase/functions/_shared/account-sync.ts`.

## 3. A função
`supabase/functions/asaas-account-diagnostics/index.ts`, publicada com `--no-verify-jwt`.

**Autenticação:** hoje só o segredo do agendador (`x-cron-secret`, valor de `CRON_SECRET`) ou a chave
secreta do projeto. **Não é chamável por usuário logado.** A tela de suporte não pode chamá-la
direto do app: veja a seção 5.

**Pedido:** `POST` com corpo `{}` (todas as contas fora de `verified`) ou `{"providerId": "<uuid>"}`.

**Resposta:**
```json
{
  "accounts": [{
    "providerId": "...",
    "dbStatus": "verification_requested",
    "dbSandbox": true,
    "envSandbox": true,
    "requestedAt": "2026-11-17T00:58:25+00:00",
    "dbRejectionReason": null,
    "hasAsaasAccountId": true,
    "hasApiKey": true,
    "statusHttp": 200,
    "asaasStatus": {
      "commercialInfo": "APPROVED",
      "bankAccountInfo": "APPROVED",
      "documentation": "APPROVED",
      "general": "APPROVED"
    },
    "documentsHttp": 200,
    "documents": [{
      "type": "IDENTIFICATION", "status": "APPROVED", "title": "...",
      "description": "...", "rejectReasons": null, "hasOnboardingLink": false
    }]
  }]
}
```

## 4. Como interpretar
| Situação | Significa | Orientação ao prestador |
|---|---|---|
| `asaasStatus.general = APPROVED` e `dbStatus` ≠ `verified` | O Asaas já aprovou; o banco não atualizou ainda (a sincronização roda a cada poucos minutos) | Aguardar ou tocar em "Recuperar link de verificação" |
| `documentation` ou um documento em `NOT_SENT` / `PENDING` | Falta enviar documento ou selfie | Abrir Carteira, "Completar verificação" e concluir o envio |
| documento em `REJECTED` com `rejectReasons` | O Asaas recusou o documento | Corrigir conforme o motivo e reenviar pelo link |
| `commercialInfo` ou `bankAccountInfo` diferente de `APPROVED` | Dado comercial ou bancário não aceito | Conferir razão social, CNPJ e dados da conta |
| `general = REJECTED` | Cadastro recusado | O gatilho já avisa o prestador; reenviar com dados corrigidos |
| `hasApiKey = false` ou `hasAsaasAccountId = false` | A subconta não foi criada direito | Caso para o suporte técnico |
| `statusHttp` diferente de 200 | O Asaas não respondeu ou a chave não vale | Verificar `dbSandbox` x `envSandbox` (ambiente trocado) |
| `dbSandbox` ≠ `envSandbox` | Conta criada em outro ambiente | Conciliação manual |

Contatar o suporte do Asaas só faz sentido quando tudo está enviado e aprovado do nosso lado e o
status geral continua parado.

## 5. O que a tela de suporte precisa fazer
1. **Restringir ao administrador.** Reaproveitar o padrão do console de disputas:
   `is_service_dispute_admin()` (RPC) no app e a mesma checagem no servidor. Considerar um papel
   próprio de suporte se for abrir para mais gente.
2. **Não expor o segredo do agendador ao app.** Criar uma Edge Function com `auth: "user"` (JWT) que
   confere `is_service_dispute_admin()` e então chama a lógica de diagnóstico. Sugestão: extrair o
   corpo da função atual para `_shared/account-diagnostics.ts` e usá-lo nas duas.
3. **Listar** as contas fora de `verified`, ordenadas por `verification_requested_at`, com há quantos
   dias aguardam e um resumo (status geral e documentos pendentes). Detalhe por prestador com a
   tabela da seção 4.
4. **Ações possíveis:** forçar uma sincronização de status (chamar `syncAsaasAccountStatus`),
   reenviar o aviso ao prestador e copiar uma mensagem de orientação pronta.
5. **Auditoria:** registrar quem consultou e quando.
6. **Privacidade:** nunca exibir a chave da subconta, `onboardingUrl` nem documentos. Mostrar só
   status e motivos.

## 6. Como chamar hoje (sem tela)
Pelo banco, sem tocar nos segredos (o valor fica dentro do Postgres):
```sql
select net.http_post(
  url := (select decrypted_secret from vault.decrypted_secrets where name='project_url') || '/functions/v1/asaas-account-diagnostics',
  headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),
  body := '{"providerId":"<uuid>"}'::jsonb, timeout_milliseconds := 25000) as id;
-- depois de alguns segundos:
select status_code, content::text from net._http_response where id = <id retornado>;
```
