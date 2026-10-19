/**
 * Contrato restrito ao que as funções do fluxo Asaas tocam; o resto do schema
 * fica de fora de propósito, como em product-database.ts.
 *
 * Por que isto existe: o client sem contrato fica inutilizável assim que outra
 * função tipada entra no mesmo `deno check`. O tipo da primeira passa a valer
 * para todo o programa, e aí qualquer tabela fora dele resolve para `never` —
 * eram 58 erros no comando que o CI executa, nenhum deles visível quando cada
 * arquivo era verificado sozinho.
 *
 * Um contrato por domínio, e não por função: a mesma tabela declarada em dois
 * lugares divergiria em silêncio.
 */
type Table<Row> = {Row: Row; Insert: Partial<Row>; Update: Partial<Row>; Relationships: []};

type ServicePaymentCharge = {
  id: string;
  request_id: string;
  provider_id: string;
  kind: string;
  amount_cents: number;
  status: string;
  payment_provider: string | null;
  asaas_payment_id: string | null;
  pix_ticket_url: string | null;
  pix_copy_paste: string | null;
  asaas_checkout_claimed_at: string | null;
  asaas_sandbox: boolean;
};

type ServiceProviderTransfer = {
  id: string;
  provider_id: string;
  provider_net_cents: number;
  status: string;
  asaas_transfer_id: string | null;
};

/** Espelha o type Operation consumido por decide-asaas-dispute. */
type AsaasDisputeOperation = {
  id: string;
  decision: 'driver_refunded' | 'provider_released';
  status: string;
  amount_cents: number;
  asaas_payment_id: string | null;
  wallet_id: string | null;
  sandbox: boolean;
  external_id: string | null;
  decision_note: string;
  updated_at: string;
};

export type AsaasDatabase = {
  public: {
    Tables: {
      service_payment_charges: Table<ServicePaymentCharge>;
      service_provider_transfers: Table<ServiceProviderTransfer>;
      asaas_dispute_operations: Table<AsaasDisputeOperation>;
      provider_asaas_accounts: Table<{
        provider_id: string;
        asaas_account_id: string;
        wallet_id: string | null;
        status: string;
        verified_at: string | null;
        rejection_reason: string | null;
      }>;
      provider_asaas_withdrawals: Table<{
        id: string;
        asaas_transfer_id: string | null;
        status: string;
      }>;
      profiles: Table<{
        id: string;
        full_name: string | null;
        document_hash: string | null;
        phone: string | null;
        asaas_customer_id: string | null;
      }>;
    };
    Views: Record<string, never>;
    Functions: {
      // Emissão do PIX
      claim_asaas_charge_checkout: {
        Args: {p_charge_id: string; p_requester_id: string; p_sandbox: boolean};
        Returns: boolean;
      };
      mark_service_charge_asaas_checkout: {
        Args: {
          p_charge_id: string;
          p_asaas_payment_id: string;
          p_pix_ticket_url: string | null;
          p_pix_copy_paste: string;
          p_expires_at: string | null;
          p_asaas_sandbox: boolean;
        };
        Returns: undefined;
      };
      // Confirmação e conciliação
      confirm_asaas_charge_payment: {
        Args: {p_asaas_payment_id: string; p_end_to_end_id: string | null};
        Returns: undefined;
      };
      mark_asaas_transfer_manual_review: {
        Args: {p_transfer_id: string; p_reason: string};
        Returns: undefined;
      };
      // Repasse ao prestador
      begin_asaas_payment_release: {
        Args: {p_request_id: string};
        Returns: Array<{transfer_id: string}>;
      };
      claim_asaas_provider_transfer: {
        Args: {p_transfer_id: string};
        Returns: Array<{provider_net_cents: number; wallet_id: string}>;
      };
      complete_asaas_payment_release_with_review: {
        Args: {
          p_transfer_id: string;
          p_asaas_transfer_id: string;
          p_rating: number;
          p_comment: string | null;
        };
        Returns: undefined;
      };
      // Disputas
      is_service_dispute_admin: {Args: Record<string, never>; Returns: boolean};
      begin_asaas_dispute_settlement: {
        Args: {p_request_id: string; p_decision: string; p_note: string};
        Returns: AsaasDisputeOperation[];
      };
      claim_asaas_dispute_operation: {
        Args: {p_operation_id: string};
        Returns: AsaasDisputeOperation[];
      };
      decide_service_dispute: {
        Args: {p_request_id: string; p_decision: string; p_decision_note: string};
        Returns: undefined;
      };
      // Inbox do webhook de notificação
      record_asaas_webhook_event: {
        Args: {p_dedupe_key: string; p_event_type: string; p_payload: unknown};
        Returns: Array<{event_id: string; already_processed: boolean}>;
      };
      mark_asaas_webhook_event_processed: {Args: {p_event_id: string}; Returns: undefined};
      mark_asaas_webhook_event_failed: {
        Args: {p_event_id: string; p_error: string};
        Returns: undefined;
      };
    };
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
};
