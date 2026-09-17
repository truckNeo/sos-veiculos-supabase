/** Scoped contract for the product migrations; unrelated schemas are deliberately omitted. */
type ProductNotification = {
  id:string;user_id:string;category:'maintenance'|'appointments'|'sharing';title:string;body:string;resource_id:string;
  push_claim:string|null;push_sent_at:string|null;push_lease_until:string|null;push_attempts:number;
};
type Table<Row> = {Row:Row;Insert:Partial<Row>;Update:Partial<Row>;Relationships:[]};
export type ProductDatabase = {
  public:{
    Tables:{
      product_notifications:Table<ProductNotification>;
      app_notification_preferences:Table<{user_id:string;maintenance:boolean;appointments:boolean}>;
    };
    Views:Record<string,never>;
    Functions:{
      enqueue_product_reminders:{Args:Record<string,never>;Returns:undefined};
      claim_product_notifications:{Args:Record<string,never>;Returns:ProductNotification[]};
      product_notification_is_current:{Args:{p_id:string};Returns:boolean};
      authorize_shared_attachment:{Args:{p_attachment_id:string};Returns:string|null};
    };
    Enums:Record<string,never>;
    CompositeTypes:Record<string,never>;
  };
};
