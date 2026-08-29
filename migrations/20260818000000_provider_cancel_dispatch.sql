-- Allow provider to cancel an accepted dispatch before PIX receipt is sent
CREATE OR REPLACE FUNCTION provider_cancel_dispatch(p_request_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider_id UUID := auth.uid();
  v_phase TEXT;
  v_receipt_count INTEGER;
BEGIN
  -- Verify this provider owns the dispatch
  SELECT workflow_phase INTO v_phase
  FROM service_requests
  WHERE id = p_request_id
    AND selected_provider_id = v_provider_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Atendimento não encontrado ou sem permissão.';
  END IF;

  IF v_phase != 'awaiting_dispatch_payment' THEN
    RAISE EXCEPTION 'Cancelamento permitido apenas antes do pagamento ser confirmado.';
  END IF;

  -- Block if receipt was already sent
  SELECT COUNT(*) INTO v_receipt_count
  FROM request_attachments
  WHERE request_id = p_request_id
    AND kind = 'payment_receipt';

  IF v_receipt_count > 0 THEN
    RAISE EXCEPTION 'Não é possível cancelar após o envio do comprovante pelo motorista.';
  END IF;

  -- Reject the accepted offer
  UPDATE provider_offers
  SET status = 'rejected', updated_at = NOW()
  WHERE request_id = p_request_id
    AND provider_id = v_provider_id
    AND status = 'accepted';

  -- Return request to open state
  UPDATE service_requests
  SET
    workflow_phase = 'open',
    status = 'open',
    selected_provider_id = NULL,
    history_access_allowed = FALSE,
    updated_at = NOW()
  WHERE id = p_request_id;
END;
$$;

GRANT EXECUTE ON FUNCTION provider_cancel_dispatch(UUID) TO authenticated;
