-- ============================================================================
-- ASM Expense & Reimbursement Platform — Custom Currency Registration
-- Migration: 20261022000017_register_custom_currency.sql
-- ============================================================================

CREATE OR REPLACE FUNCTION register_custom_currency(
    p_code TEXT,
    p_name TEXT,
    p_symbol TEXT,
    p_decimals INT DEFAULT 2
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_clean_code TEXT;
    v_clean_name TEXT;
    v_clean_symbol TEXT;
    v_curr RECORD;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_AUTHENTICATED', 'message', 'Your session has expired. Please sign in again.');
    END IF;

    v_clean_code := upper(trim(COALESCE(p_code, '')));
    v_clean_name := trim(COALESCE(p_name, ''));
    v_clean_symbol := trim(COALESCE(p_symbol, ''));

    IF length(v_clean_code) <> 3 OR v_clean_code !~ '^[A-Z]{3}$' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_CURRENCY_CODE', 'message', 'Currency code must be exactly 3 uppercase letters (ISO 4217).');
    END IF;

    IF length(v_clean_name) < 2 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_CURRENCY_NAME', 'message', 'Currency name must be at least 2 characters.');
    END IF;

    IF length(v_clean_symbol) = 0 THEN
        v_clean_symbol := v_clean_code;
    END IF;

    INSERT INTO currencies (code, name, symbol, decimals, is_base, is_active)
    VALUES (v_clean_code, v_clean_name, v_clean_symbol, COALESCE(p_decimals, 2), false, true)
    ON CONFLICT (code) DO UPDATE
    SET name = EXCLUDED.name,
        symbol = EXCLUDED.symbol,
        is_active = true
    RETURNING * INTO v_curr;

    RETURN jsonb_build_object(
        'success', true,
        'currency', jsonb_build_object(
            'code', v_curr.code,
            'name', v_curr.name,
            'symbol', v_curr.symbol,
            'decimals', v_curr.decimals
        ),
        'message', 'Currency ' || v_clean_code || ' registered successfully.'
    );
END;
$$;

REVOKE ALL ON FUNCTION register_custom_currency(TEXT, TEXT, TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION register_custom_currency(TEXT, TEXT, TEXT, INT) TO authenticated;
