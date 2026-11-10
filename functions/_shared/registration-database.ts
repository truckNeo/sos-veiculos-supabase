type Table<Row> = {
  Row: Row;
  Insert: Partial<Row>;
  Update: Partial<Row>;
  Relationships: [];
};
export type RegistrationDatabase = {
  public: {
    Tables: {
      profiles: Table<{
        id: string;
        role: string;
        account_kind: string;
        full_name: string;
        phone: string;
        phone_lookup: string;
        document_hash: string;
        document_last4: string;
      }>;
      provider_profiles: Table<{
        provider_id: string;
        business_name: string;
        legal_name: string;
        postal_code: string;
        address_street: string;
        address_number: string;
        address_complement: string | null;
        address_neighborhood: string;
        address_city: string;
        address_state: string;
        service_radius_km: number;
        is_available: boolean;
      }>;
      provider_services: Table<{ provider_id: string; problem_type: string }>;
      provider_vehicles: Table<{
        provider_id: string;
        vehicle_type: string;
        model: string;
        color: string;
        plate: string;
      }>;
      organizations: Table<{
        owner_id: string;
        legal_name: string;
        cnpj_hash: string;
        cnpj_last4: string;
      }>;
      payment_customer_profiles: Table<{
        user_id: string;
        document_ciphertext: string;
        document_iv: string;
      }>;
    };
    Views: Record<string, never>;
    Functions: Record<string, never>;
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
};
