-- ============================================================================
-- ASM Expense & Reimbursement Platform - Cash Advance Integrity Fixes
-- Migration: 20261019000010_advance_integrity_fixes.sql
--
-- Defects found by end-to-end database verification of 000009:
-- 1. request_cash_advance read currencies.exchange_rate_to_aed (no such
--    column): every USD/EUR request failed with a raw database error.
-- 2. request_cash_advance ignored p_idempotency_key: retries duplicated.
-- 3. record_cash_advance_refund ignored balance reserved by claims still in
--    workflow: refund + later claim approval could exceed the advance.
-- 4. Clients could INSERT cash_advances directly with any approval stage and
--    AED amount, skipping approval tiers.
-- 5. is_hod_of ignored employees.hod_id (used by approval authorization), so
--    an assigned HOD could approve a claim but not open its receipts.
-- ============================================================================

ALTER TABLE cash_advances ADD COLUMN IF NOT EXISTS idempotency_key UUID;
DO $$ BEGIN
    ALTER TABLE cash_advances ADD CONSTRAINT uq_cash_advances_employee_idempotency UNIQUE (employee_id, idempotency_key);
EXCEPTION WHEN duplicate_object OR duplicate_table THEN NULL; END $$;

CREATE SEQUENCE IF NOT EXISTS cash_advance_number_seq;

-- ----------------------------------------------------------------------------
-- 1 + 2. CASH ADVANCE REQUEST
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION request_cash_advance(
    p_amount_minor BIGINT,
    p_currency_code CHAR(3),
    p_purpose TEXT,
    p_start_date DATE,
    p_end_date DATE,
    p_idempotency_key UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_employee RECORD;
    v_existing RECORD;
    v_rate NUMERIC;
    v_aed_amount BIGINT;
    v_advance_id UUID;
    v_advance_num VARCHAR(50);
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHENTICATED', 'message', 'You must be signed in to request a cash advance.');
    END IF;

    IF p_idempotency_key IS NOT NULL THEN
        SELECT id, advance_number, aed_amount_minor, status, current_approval_stage INTO v_existing
        FROM cash_advances WHERE employee_id = v_user_id AND idempotency_key = p_idempotency_key;
        IF FOUND THEN
            RETURN jsonb_build_object('success', true, 'code', 'ADVANCE_ALREADY_REQUESTED', 'replayed', true,
                'advance_id', v_existing.id, 'advance_number', v_existing.advance_number,
                'aed_amount_minor', v_existing.aed_amount_minor, 'status', v_existing.status,
                'current_stage', v_existing.current_approval_stage);
        END IF;
    END IF;

    SELECT * INTO v_employee FROM employees WHERE id = v_user_id;
    IF NOT FOUND OR NOT v_employee.is_active THEN
        RETURN jsonb_build_object('success', false, 'code', 'INACTIVE_EMPLOYEE', 'message', 'Only active employees can request cash advances.');
    END IF;

    IF p_amount_minor IS NULL OR p_amount_minor <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_AMOUNT', 'message', 'Advance amount must be greater than zero.');
    END IF;

    IF p_purpose IS NULL OR length(trim(p_purpose)) = 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'PURPOSE_REQUIRED', 'message', 'A business purpose is required for cash advance requests.');
    END IF;

    IF p_start_date IS NULL OR p_end_date IS NULL OR p_end_date < p_start_date THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_DATES', 'message', 'End date must be on or after start date.');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM currencies WHERE code = p_currency_code AND is_active = true) THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNSUPPORTED_CURRENCY', 'message', 'The requested currency is not supported.');
    END IF;

    v_rate := get_aed_exchange_rate(p_currency_code, CURRENT_DATE);
    IF v_rate IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'FX_RATE_UNAVAILABLE',
            'message', 'No exchange rate to AED is configured for ' || p_currency_code || '. Please contact Finance.');
    END IF;

    v_aed_amount := ROUND(p_amount_minor * v_rate)::BIGINT;
    IF v_aed_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_AED_AMOUNT', 'message', 'Calculated AED equivalent must be positive.');
    END IF;

    v_advance_num := 'ADV-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('cash_advance_number_seq')::text, 6, '0');

    INSERT INTO cash_advances (
        advance_number, employee_id, amount_minor, currency_code,
        exchange_rate, aed_amount_minor, purpose, start_date, end_date,
        status, current_approval_stage, reconciled_amount_minor, returned_amount_minor, idempotency_key
    ) VALUES (
        v_advance_num, v_user_id, p_amount_minor, p_currency_code,
        v_rate, v_aed_amount, trim(p_purpose), p_start_date, p_end_date,
        'UNDER_REVIEW', 'LINE_MANAGER_REVIEW', 0, 0, p_idempotency_key
    )
    ON CONFLICT (employee_id, idempotency_key) DO NOTHING
    RETURNING id INTO v_advance_id;

    IF v_advance_id IS NULL THEN
        SELECT id, advance_number, aed_amount_minor, status, current_approval_stage INTO v_existing
        FROM cash_advances WHERE employee_id = v_user_id AND idempotency_key = p_idempotency_key;
        RETURN jsonb_build_object('success', true, 'code', 'ADVANCE_ALREADY_REQUESTED', 'replayed', true,
            'advance_id', v_existing.id, 'advance_number', v_existing.advance_number,
            'aed_amount_minor', v_existing.aed_amount_minor, 'status', v_existing.status,
            'current_stage', v_existing.current_approval_stage);
    END IF;

    PERFORM record_audit_log(
        'ADVANCE_REQUESTED', 'cash_advances', v_advance_id, NULL,
        jsonb_build_object(
            'advance_number', v_advance_num,
            'amount_minor', p_amount_minor,
            'currency_code', p_currency_code,
            'exchange_rate', v_rate,
            'aed_amount_minor', v_aed_amount,
            'purpose', trim(p_purpose),
            'start_date', p_start_date,
            'end_date', p_end_date,
            'initial_stage', 'LINE_MANAGER_REVIEW'
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'ADVANCE_REQUESTED',
        'replayed', false,
        'advance_id', v_advance_id,
        'advance_number', v_advance_num,
        'exchange_rate', v_rate,
        'aed_amount_minor', v_aed_amount,
        'status', 'UNDER_REVIEW',
        'current_stage', 'LINE_MANAGER_REVIEW'
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 3. LEFTOVER REFUND: only the balance not applied, refunded or reserved
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_cash_advance_refund(
    p_advance_id UUID,
    p_refund_amount_minor BIGINT,
    p_refund_reference VARCHAR,
    p_refund_date DATE DEFAULT CURRENT_DATE,
    p_payment_method VARCHAR DEFAULT 'BANK_TRANSFER',
    p_notes TEXT DEFAULT NULL,
    p_idempotency_key UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_advance RECORD;
    v_existing RECORD;
    v_reserved BIGINT;
    v_available BIGINT;
    v_new_returned_minor BIGINT;
    v_refund_id UUID;
    v_new_status cash_advance_status;
BEGIN
    IF NOT (has_role('FINANCE') OR has_role('ADMIN')) THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only Finance or Admin can record cash advance refunds.');
    END IF;

    IF p_refund_amount_minor IS NULL OR p_refund_amount_minor <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REFUND_AMOUNT', 'message', 'Refund amount must be greater than zero.');
    END IF;

    IF p_refund_reference IS NULL OR length(trim(p_refund_reference)) = 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'REFERENCE_REQUIRED', 'message', 'Refund transaction reference is mandatory.');
    END IF;

    IF p_refund_date IS NOT NULL AND p_refund_date > CURRENT_DATE THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REFUND_DATE', 'message', 'Refund date cannot be in the future.');
    END IF;

    SELECT * INTO v_advance FROM cash_advances WHERE id = p_advance_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'ADVANCE_NOT_FOUND', 'message', 'Cash advance not found.');
    END IF;

    -- Idempotency is checked under the advance lock so concurrent retries serialize.
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id, advance_id INTO v_existing FROM advance_refunds WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            IF v_existing.advance_id <> p_advance_id THEN
                RETURN jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_CONFLICT',
                    'message', 'This request key was already used for a different advance.');
            END IF;
            RETURN jsonb_build_object('success', true, 'code', 'REFUND_REPLAYED', 'replayed', true,
                'refund_id', v_existing.id, 'advance_id', p_advance_id, 'status', v_advance.status,
                'message', 'Refund previously recorded.');
        END IF;
    END IF;

    IF v_advance.status NOT IN ('PAID', 'PARTIALLY_SETTLED') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS',
            'message', 'Only paid or partially settled advances can have unused funds refunded. Current status: ' || v_advance.status::text);
    END IF;

    IF v_advance.employee_id = v_user_id THEN
        RETURN jsonb_build_object('success', false, 'code', 'SELF_REFUND_FORBIDDEN', 'message', 'Finance personnel cannot record refunds for their own cash advances.');
    END IF;

    SELECT COALESCE(SUM(advance_applied_minor), 0) INTO v_reserved
    FROM expense_claims
    WHERE cash_advance_id = p_advance_id
      AND status IN ('SUBMITTED', 'LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW', 'CORRECTION_REQUIRED');

    v_available := v_advance.aed_amount_minor - v_advance.reconciled_amount_minor
                   - COALESCE(v_advance.returned_amount_minor, 0) - v_reserved;

    IF p_refund_amount_minor > v_available THEN
        RETURN jsonb_build_object(
            'success', false, 'code', 'OVER_REFUND_PROHIBITED',
            'available_minor', GREATEST(v_available, 0),
            'reserved_minor', v_reserved,
            'message', 'Refund amount exceeds the refundable balance of AED '
                || to_char(GREATEST(v_available, 0) / 100.0, 'FM999,999,990.00')
                || CASE WHEN v_reserved > 0
                        THEN ' (AED ' || to_char(v_reserved / 100.0, 'FM999,999,990.00') || ' is reserved by claims still under review).'
                        ELSE '.' END
        );
    END IF;

    v_new_returned_minor := COALESCE(v_advance.returned_amount_minor, 0) + p_refund_amount_minor;
    v_new_status := CASE
        WHEN v_advance.reconciled_amount_minor + v_new_returned_minor >= v_advance.aed_amount_minor THEN 'SETTLED'::cash_advance_status
        ELSE 'PARTIALLY_SETTLED'::cash_advance_status
    END;

    INSERT INTO advance_refunds (
        advance_id, refund_amount_minor, refund_reference, refund_date,
        payment_method, processed_by, notes, idempotency_key
    ) VALUES (
        p_advance_id, p_refund_amount_minor, trim(p_refund_reference), COALESCE(p_refund_date, CURRENT_DATE),
        COALESCE(NULLIF(trim(p_payment_method), ''), 'BANK_TRANSFER'), v_user_id, p_notes, p_idempotency_key
    ) RETURNING id INTO v_refund_id;

    UPDATE cash_advances
    SET returned_amount_minor = v_new_returned_minor, status = v_new_status, updated_at = now()
    WHERE id = p_advance_id;

    PERFORM record_audit_log(
        'ADVANCE_REFUNDED', 'cash_advances', p_advance_id, to_jsonb(v_advance),
        jsonb_build_object(
            'refund_id', v_refund_id,
            'refund_amount_minor', p_refund_amount_minor,
            'total_returned_minor', v_new_returned_minor,
            'reserved_minor', v_reserved,
            'new_status', v_new_status,
            'refund_reference', trim(p_refund_reference),
            'processed_by', v_user_id
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'REFUND_RECORDED',
        'replayed', false,
        'refund_id', v_refund_id,
        'advance_id', p_advance_id,
        'refund_amount_minor', p_refund_amount_minor,
        'total_returned_minor', v_new_returned_minor,
        'remaining_balance_minor', v_available - p_refund_amount_minor,
        'status', v_new_status,
        'message', 'Refund recorded. Advance status is now ' || v_new_status::text || '.'
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 4. Cash advances, refunds and advance approvals are written only by RPCs.
-- ----------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE ON cash_advances FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON advance_refunds FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON advance_approval_actions FROM anon, authenticated;

-- ----------------------------------------------------------------------------
-- 5. HOD relationship consistent with approval authorization
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_hod_of(emp_id UUID)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM employees e
        LEFT JOIN departments d ON d.id = e.department_id
        WHERE e.id = emp_id
          AND (e.hod_id = auth.uid() OR d.hod_employee_id = auth.uid())
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;
