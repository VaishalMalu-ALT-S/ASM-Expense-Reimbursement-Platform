-- ============================================================================
-- MIGRATION 0013: OCR PROVIDER ROUND-ROBIN COUNTER
-- Forward-only. A sequence gives every OCR request the next rotation slot
-- atomically across all Edge Function instances. Only the service role (used
-- by the process-receipt-ocr Edge Function) may advance it.
-- ============================================================================

CREATE SEQUENCE IF NOT EXISTS ocr_provider_rotation_seq AS BIGINT START WITH 1 INCREMENT BY 1;

-- Returns 0 for the first request, then 1, 2, ... modulo the number of providers.
CREATE OR REPLACE FUNCTION next_ocr_provider_slot(p_provider_count INT)
RETURNS INT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT CASE
        WHEN p_provider_count IS NULL OR p_provider_count < 1 THEN 0
        ELSE ((nextval('ocr_provider_rotation_seq') - 1) % p_provider_count)::INT
    END;
$$;

REVOKE ALL ON SEQUENCE ocr_provider_rotation_seq FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION next_ocr_provider_slot(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION next_ocr_provider_slot(INT) TO service_role;
