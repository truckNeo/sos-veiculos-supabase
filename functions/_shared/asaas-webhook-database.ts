/**
 * Contrato restrito ao que o webhook de notificação do Asaas toca; o resto do
 * schema fica de fora de propósito, como em product-database.ts.
 *
 * Sem este tipo o client fica sem contrato, e basta outra função tipada entrar
 * no mesmo `deno check` para que toda chamada daqui seja recusada — foi o que
 * aconteceu quando este arquivo era verificado junto com as funções de
 * produto.
 */
type Table<Row> = {Row: Row; Insert: Partial<Row>; Update: Partial<Row>; Relationships: []};

export type AsaasWebhookDatabase = {
  public: {
    Tables: {
      service_provider_transfers: Table<{id: string; asaas_transfer_id: string | null; status: string}>;
      provider_asaas_withdrawals: Table<{id: string; asaas_transfer_id: string | null; status: string}>;
      provider_asaas_accounts: Table<{
        asaas_account_id: string;
        status: string;
        verified_at: string | null;
        rejection_reason: string | null;
      }>;
    };
    Views: Record<string, never>;
    Functions: {
      confirm_asaas_charge_payment: {
        Args: {p_asaas_payment_id: string; p_end_to_end_id: string | null};
        Returns: undefined;
      };
      mark_asaas_transfer_manual_review: {
        Args: {p_transfer_id: string; p_reason: string};
        Returns: undefined;
      };
      record_asaas_webhook_event: {
        Args: {p_dedupe_key: string; p_event_type: string; p_payload: unknown};
        Returns: Array<{event_id: string; already_processed: boolean}>;
      };
      mark_asaas_webhook_event_processed: {Args: {p_event_id: string}; Returns: undefined};
      mark_asaas_webhook_event_failed: {Args: {p_event_id: string; p_error: string}; Returns: undefined};
    };
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
};
