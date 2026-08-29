-- PIX-only: complete service with review (no Iugu escrow)
-- Called by the driver after confirming the service is done.
CREATE OR REPLACE FUNCTION complete_service_with_review(
  p_request_id UUID,
  p_rating INTEGER,
  p_comment TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_requester_id UUID := auth.uid();
  v_provider_id UUID;
  v_phase TEXT;
BEGIN
  -- Validate rating
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'Informe uma avaliação de 1 a 5 estrelas.';
  END IF;

  -- Get request and verify ownership
  SELECT selected_provider_id, workflow_phase
  INTO v_provider_id, v_phase
  FROM service_requests
  WHERE id = p_request_id
    AND requester_id = v_requester_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Chamado não encontrado ou sem permissão.';
  END IF;

  IF v_phase != 'awaiting_driver_confirmation' THEN
    RAISE EXCEPTION 'O chamado não está aguardando conferência (fase atual: %).', v_phase;
  END IF;

  IF v_provider_id IS NULL THEN
    RAISE EXCEPTION 'Nenhum prestador selecionado para este chamado.';
  END IF;

  -- Save the review
  INSERT INTO reviews (request_id, provider_id, reviewer_id, rating, comment)
  VALUES (p_request_id, v_provider_id, v_requester_id, p_rating, NULLIF(TRIM(p_comment), ''));

  -- Update provider average rating
  UPDATE provider_profiles
  SET average_rating = (
    SELECT COALESCE(AVG(r.rating), 0)
    FROM reviews r
    WHERE r.provider_id = v_provider_id
  ),
  completed_services = (
    SELECT COUNT(*)
    FROM reviews r
    WHERE r.provider_id = v_provider_id
  )
  WHERE provider_id = v_provider_id;

  -- Mark service as completed
  UPDATE service_requests
  SET workflow_phase = 'completed',
      status = 'completed',
      updated_at = NOW()
  WHERE id = p_request_id;
END;
$$;

GRANT EXECUTE ON FUNCTION complete_service_with_review(UUID, INTEGER, TEXT) TO authenticated;
