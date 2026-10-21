-- ============================================================================
-- ASM Expense & Reimbursement Platform - Phase 4
-- Migration: 20261019000009_cash_advance_lifecycle_and_cancellation.sql
-- Description: Cash Advance Multi-Tier Hierarchy (Option 2), Leftover Refund (Option A),
--              Payment, and Atomic Claim Cancellation
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. SCHEMA EXTENSIONS FOR CASH ADVANCES
-- ----------------------------------------------------------------------------

-- Add stage tracking and returned amount columns to cash_advances
ALTER TABLE cash_advances ADD COLUMN IF NOT EXISTS current_approval_stage VARCHAR(50) NOT NULL DEFAULT 'LINE_MANAGER_REVIEW';
ALTER TABLE cash_advances ADD COLUMN IF NOT EXISTS returned_amount_minor BIGINT NOT NULL DEFAULT 0;

-- Immutable audit table for Cash Advance multi-tier approval actions
CREATE TABLE IF NOT EXISTS advance_approval_actions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    advance_id UUID NOT NULL REFERENCES cash_advances(id) ON DELETE CASCADE,
    step_order INT NOT NULL,
    actor_id UUID NOT NULL REFERENCES employees(id),
    action approval_action_type NOT NULL,
    previous_stage VARCHAR(50) NOT NULL,
    new_stage VARCHAR(50) NOT NULL,
    comments TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Table for tracking Leftover Cash Advance returns recorded by Finance (Option A)
CREATE TABLE IF NOT EXISTS advance_refunds (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    advance_id UUID NOT NULL REFERENCES cash_advances(id) ON DELETE RESTRICT,
    refund_amount_minor BIGINT NOT NULL CHECK (refund_amount_minor > 0),
    refund_reference VARCHAR(100) NOT NULL,
    refund_date DATE NOT NULL DEFAULT CURRENT_DATE,
    idempotency_key UUID UNIQUE,
    payment_method VARCHAR(50) NOT NULL DEFAULT 'BANK_TRANSFER',
    processed_by UUID NOT NULL REFERENCES employees(id),
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_advance_approval_actions_advance ON advance_approval_actions(advance_id);
CREATE INDEX IF NOT EXISTS idx_advance_refunds_advance ON advance_refunds(advance_id);

-- ----------------------------------------------------------------------------
-- 2. ENFORCE PRE-APPROVAL CANCELLATION IN CLAIM STATE MACHINE
-- Allows DRAFT, SUBMITTED, and under-review claims to be cancelled by owner.
-- APPROVED, REIMBURSEMENT_PROCESSING, PAID, SETTLED remain strictly uncancellable.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_claim_status_transition_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_allowed claim_status[];
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    v_allowed := CASE OLD.status
        WHEN 'DRAFT' THEN ARRAY['LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'CANCELLED']::claim_status[]
        WHEN 'CORRECTION_REQUIRED' THEN ARRAY['LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'CANCELLED']::claim_status[]
        WHEN 'LINE_MANAGER_REVIEW' THEN ARRAY['HOD_REVIEW', 'REJECTED', 'CORRECTION_REQUIRED', 'CANCELLED']::claim_status[]
        WHEN 'HOD_REVIEW' THEN ARRAY['SIVA_REVIEW', 'REJECTED', 'CORRECTION_REQUIRED', 'CANCELLED']::claim_status[]
        WHEN 'SIVA_REVIEW' THEN ARRAY['FINANCE_REVIEW', 'REJECTED', 'CORRECTION_REQUIRED', 'CANCELLED']::claim_status[]
        WHEN 'FINANCE_REVIEW' THEN ARRAY['APPROVED', 'REJECTED', 'CORRECTION_REQUIRED', 'CANCELLED']::claim_status[]
        WHEN 'APPROVED' THEN ARRAY['REIMBURSEMENT_PROCESSING', 'PAID', 'SETTLED']::claim_status[]
        WHEN 'REIMBURSEMENT_PROCESSING' THEN ARRAY['PAID']::claim_status[]
        ELSE ARRAY[]::claim_status[]
    END;

    IF NOT (NEW.status = ANY(v_allowed)) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'INVALID_STATUS_TRANSITION',
            DETAIL = 'Claim cannot move from ' || OLD.status::text || ' to ' || NEW.status::text || '.';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_claim_status_transition ON expense_claims;
CREATE TRIGGER trg_enforce_claim_status_transition
BEFORE UPDATE OF status ON expense_claims
FOR EACH ROW EXECUTE FUNCTION enforce_claim_status_transition_trigger();

-- ----------------------------------------------------------------------------
-- 3. CASH ADVANCE STATE MACHINE ENFORCEMENT
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_cash_advance_status_transition_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_allowed cash_advance_status[];
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    v_allowed := CASE OLD.status
        WHEN 'DRAFT' THEN ARRAY['SUBMITTED', 'UNDER_REVIEW', 'CANCELLED']::cash_advance_status[]
        WHEN 'SUBMITTED' THEN ARRAY['UNDER_REVIEW', 'APPROVED', 'REJECTED', 'CANCELLED']::cash_advance_status[]
        WHEN 'UNDER_REVIEW' THEN ARRAY['APPROVED', 'REJECTED', 'CANCELLED']::cash_advance_status[]
        WHEN 'APPROVED' THEN ARRAY['PAID', 'CANCELLED', 'REJECTED']::cash_advance_status[]
        WHEN 'PAID' THEN ARRAY['PARTIALLY_SETTLED', 'SETTLED']::cash_advance_status[]
        WHEN 'PARTIALLY_SETTLED' THEN ARRAY['SETTLED']::cash_advance_status[]
        ELSE ARRAY[]::cash_advance_status[]
    END;

    IF NOT (NEW.status = ANY(v_allowed)) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'INVALID_ADVANCE_STATUS_TRANSITION',
            DETAIL = 'Cash advance cannot transition from ' || OLD.status::text || ' to ' || NEW.status::text || '.';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_cash_advance_status_transition ON cash_advances;
CREATE TRIGGER trg_enforce_cash_advance_status_transition
BEFORE UPDATE OF status ON cash_advances
FOR EACH ROW EXECUTE FUNCTION enforce_cash_advance_status_transition_trigger();

-- ----------------------------------------------------------------------------
-- 4. CLIENT WRITE PROTECTION ON CASH ADVANCES
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION protect_cash_advance_modifications_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp
AS $$
BEGIN
    IF current_user IN ('authenticated', 'anon') AND NOT has_role('ADMIN') THEN
        IF TG_OP = 'INSERT' THEN
            IF NEW.status NOT IN ('DRAFT', 'SUBMITTED', 'UNDER_REVIEW') THEN
                RAISE EXCEPTION 'Security Violation: New advances cannot be created in status % directly.', NEW.status;
            END IF;
            IF NEW.reconciled_amount_minor != 0 OR NEW.returned_amount_minor != 0 THEN
                RAISE EXCEPTION 'Security Violation: Reconciled and returned amounts must be zero on creation.';
            END IF;
            IF NEW.paid_at IS NOT NULL OR NEW.approved_by IS NOT NULL OR NEW.approved_at IS NOT NULL THEN
                RAISE EXCEPTION 'Security Violation: Approval and payment fields cannot be set on creation.';
            END IF;
        ELSIF TG_OP = 'UPDATE' THEN
            IF OLD.status NOT IN ('DRAFT') THEN
                RAISE EXCEPTION 'Security Violation: Cash advances under review or processed cannot be modified directly.';
            END IF;
            IF NEW.status IN ('APPROVED', 'PAID', 'PARTIALLY_SETTLED', 'SETTLED') THEN
                RAISE EXCEPTION 'Security Violation: Direct client transition to % is prohibited.', NEW.status;
            END IF;
            IF NEW.reconciled_amount_minor IS DISTINCT FROM OLD.reconciled_amount_minor
               OR NEW.returned_amount_minor IS DISTINCT FROM OLD.returned_amount_minor
               OR NEW.paid_at IS DISTINCT FROM OLD.paid_at
               OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
               OR NEW.approved_at IS DISTINCT FROM OLD.approved_at
               OR NEW.current_approval_stage IS DISTINCT FROM OLD.current_approval_stage THEN
                RAISE EXCEPTION 'Security Violation: Reconciliation, approval, and payment fields are server-controlled.';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_cash_advance_modifications ON cash_advances;
CREATE TRIGGER trg_protect_cash_advance_modifications
BEFORE INSERT OR UPDATE ON cash_advances
FOR EACH ROW EXECUTE FUNCTION protect_cash_advance_modifications_trigger();

-- ----------------------------------------------------------------------------
-- 5. SERVER-AUTHORITATIVE CASH ADVANCE REQUEST RPC
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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_employee RECORD;
    v_rate NUMERIC(18, 6) := 1.0;
    v_aed_amount BIGINT;
    v_advance_id UUID;
    v_advance_num VARCHAR(50);
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHENTICATED', 'message', 'You must be signed in to request a cash advance.');
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

    -- Server exchange rate lookup
    IF p_currency_code = 'AED' THEN
        v_rate := 1.0;
    ELSE
        SELECT exchange_rate_to_aed INTO v_rate FROM currencies WHERE code = p_currency_code;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('success', false, 'code', 'UNSUPPORTED_CURRENCY', 'message', 'The requested currency is not supported.');
        END IF;
    END IF;

    v_aed_amount := round(p_amount_minor * v_rate);
    IF v_aed_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_AED_AMOUNT', 'message', 'Calculated AED equivalent must be positive.');
    END IF;

    v_advance_num := 'ADV-' || to_char(now(), 'YYYYMMDD') || '-' || LPAD((floor(random() * 9000 + 1000)::int)::text, 4, '0');

    INSERT INTO cash_advances (
        advance_number, employee_id, amount_minor, currency_code,
        exchange_rate, aed_amount_minor, purpose, start_date, end_date,
        status, current_approval_stage, reconciled_amount_minor, returned_amount_minor
    ) VALUES (
        v_advance_num, v_user_id, p_amount_minor, p_currency_code,
        v_rate, v_aed_amount, trim(p_purpose), p_start_date, p_end_date,
        'UNDER_REVIEW', 'LINE_MANAGER_REVIEW', 0, 0
    ) RETURNING id INTO v_advance_id;

    PERFORM record_audit_log(
        'ADVANCE_REQUESTED', 'cash_advances', v_advance_id, NULL,
        jsonb_build_object(
            'advance_number', v_advance_num,
            'amount_minor', p_amount_minor,
            'currency_code', p_currency_code,
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
        'advance_id', v_advance_id,
        'advance_number', v_advance_num,
        'aed_amount_minor', v_aed_amount,
        'status', 'UNDER_REVIEW',
        'current_stage', 'LINE_MANAGER_REVIEW'
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. MULTI-TIER CASH ADVANCE APPROVAL RPC (Option 2: LM -> HOD -> SIVA -> FINANCE)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION review_cash_advance(
    p_advance_id UUID,
    p_action approval_action_type,
    p_comments TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_advance RECORD;
    v_employee RECORD;
    v_is_authorized BOOLEAN := false;
    v_next_stage VARCHAR(50);
    v_new_status cash_advance_status := 'UNDER_REVIEW';
    v_step_order INT := 1;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHENTICATED', 'message', 'You must be signed in to review cash advances.');
    END IF;

    SELECT * INTO v_advance FROM cash_advances WHERE id = p_advance_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'ADVANCE_NOT_FOUND', 'message', 'Cash advance not found.');
    END IF;

    -- Self-approval forbidden
    IF v_advance.employee_id = v_user_id THEN
        RETURN jsonb_build_object('success', false, 'code', 'SELF_APPROVAL_FORBIDDEN', 'message', 'Self-approval of cash advances is strictly forbidden.');
    END IF;

    -- Can only review if in UNDER_REVIEW status
    IF v_advance.status != 'UNDER_REVIEW' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Advance is not awaiting review. Current status: ' || v_advance.status::text);
    END IF;

    SELECT * INTO v_employee FROM employees WHERE id = v_advance.employee_id;

    -- Determine authorization and next stage based on current_approval_stage
    -- Step 1: LINE_MANAGER_REVIEW
    IF v_advance.current_approval_stage = 'LINE_MANAGER_REVIEW' THEN
        v_step_order := 1;
        IF (v_employee.line_manager_id = v_user_id) OR has_role('ADMIN') THEN
            v_is_authorized := true;
            v_next_stage := 'HOD_REVIEW';
        END IF;

    -- Step 2: HOD_REVIEW
    ELSIF v_advance.current_approval_stage = 'HOD_REVIEW' THEN
        v_step_order := 2;
        IF (v_employee.hod_id = v_user_id) OR has_role('ADMIN') THEN
            v_is_authorized := true;
            v_next_stage := 'SIVA_REVIEW';
        END IF;

    -- Step 3: SIVA_REVIEW (Management)
    ELSIF v_advance.current_approval_stage = 'SIVA_REVIEW' THEN
        v_step_order := 3;
        IF has_role('MANAGEMENT') OR has_role('ADMIN') THEN
            v_is_authorized := true;
            v_next_stage := 'FINANCE_REVIEW';
            v_new_status := 'UNDER_REVIEW';
        END IF;

    -- Step 4: FINANCE_REVIEW (Finance)
    ELSIF v_advance.current_approval_stage = 'FINANCE_REVIEW' THEN
        v_step_order := 4;
        IF has_role('FINANCE') OR has_role('ADMIN') THEN
            v_is_authorized := true;
            v_next_stage := 'APPROVED';
            v_new_status := 'APPROVED'; -- Finance approval complete; ready for disbursement!
        END IF;

    ELSE
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STAGE', 'message', 'Advance is not in an approvable stage: ' || v_advance.current_approval_stage);
    END IF;

    IF NOT v_is_authorized THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You are not authorized to review this cash advance at stage ' || v_advance.current_approval_stage);
    END IF;

    -- Action REJECT
    IF p_action = 'REJECT' THEN
        IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
            RETURN jsonb_build_object('success', false, 'code', 'COMMENT_REQUIRED', 'message', 'Reason comments are mandatory when rejecting a cash advance.');
        END IF;

        UPDATE cash_advances
        SET status = 'REJECTED',
            current_approval_stage = 'REJECTED',
            updated_at = now()
        WHERE id = p_advance_id;

        INSERT INTO advance_approval_actions (advance_id, step_order, actor_id, action, previous_stage, new_stage, comments)
        VALUES (p_advance_id, v_step_order, v_user_id, 'REJECT', v_advance.current_approval_stage, 'REJECTED', p_comments);

        PERFORM record_audit_log('ADVANCE_REJECTED', 'cash_advances', p_advance_id, to_jsonb(v_advance),
            jsonb_build_object('status', 'REJECTED', 'stage', v_advance.current_approval_stage, 'comments', p_comments, 'reviewer_id', v_user_id));

        RETURN jsonb_build_object('success', true, 'status', 'REJECTED');
    END IF;

    -- Action APPROVE: check duplicate approval across stages
    IF p_action = 'APPROVE' THEN
        IF EXISTS (
            SELECT 1 FROM advance_approval_actions
            WHERE advance_id = p_advance_id
              AND actor_id = v_user_id
              AND action = 'APPROVE'
        ) THEN
            RETURN jsonb_build_object('success', false, 'code', 'ALREADY_APPROVED_PREVIOUS_STAGE',
                'message', 'You have already approved this advance at an earlier approval stage.');
        END IF;

        -- Update advance record
        UPDATE cash_advances
        SET current_approval_stage = v_next_stage,
            status = v_new_status,
            approved_by = CASE WHEN v_new_status = 'APPROVED' THEN v_user_id ELSE approved_by END,
            approved_at = CASE WHEN v_new_status = 'APPROVED' THEN now() ELSE approved_at END,
            updated_at = now()
        WHERE id = p_advance_id;

        -- Record immutable approval action
        INSERT INTO advance_approval_actions (advance_id, step_order, actor_id, action, previous_stage, new_stage, comments)
        VALUES (p_advance_id, v_step_order, v_user_id, 'APPROVE', v_advance.current_approval_stage, v_next_stage, p_comments);

        PERFORM record_audit_log('ADVANCE_APPROVED_STAGE', 'cash_advances', p_advance_id, to_jsonb(v_advance),
            jsonb_build_object('previous_stage', v_advance.current_approval_stage, 'new_stage', v_next_stage, 'status', v_new_status, 'approved_by', v_user_id));

        RETURN jsonb_build_object(
            'success', true,
            'status', v_new_status,
            'current_stage', v_next_stage,
            'message', 'Advance approved at step ' || v_step_order::text || '. Advanced to ' || v_next_stage
        );
    END IF;

    RETURN jsonb_build_object('success', false, 'code', 'UNSUPPORTED_ACTION', 'message', 'Action must be APPROVE or REJECT.');
END;
$$;

-- ----------------------------------------------------------------------------
-- 7. CASH ADVANCE DISBURSEMENT RPC (FINANCE ONLY)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_cash_advance_payment(
    p_advance_id UUID,
    p_payment_reference VARCHAR,
    p_payment_method VARCHAR DEFAULT 'BANK_TRANSFER',
    p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_advance RECORD;
BEGIN
    -- Authorization: strictly Finance or Admin
    IF NOT (has_role('FINANCE') OR has_role('ADMIN')) THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only Finance or Admin can disburse advance payments.');
    END IF;

    IF p_payment_reference IS NULL OR length(trim(p_payment_reference)) = 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'REFERENCE_REQUIRED', 'message', 'Payment reference is mandatory for disbursement.');
    END IF;

    -- Concurrency lock
    SELECT * INTO v_advance FROM cash_advances WHERE id = p_advance_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'ADVANCE_NOT_FOUND', 'message', 'Cash advance not found.');
    END IF;

    -- Self-disbursement prohibition
    IF v_advance.employee_id = v_user_id THEN
        RETURN jsonb_build_object('success', false, 'code', 'SELF_PAYMENT_FORBIDDEN', 'message', 'Finance personnel cannot disburse cash advances to themselves.');
    END IF;

    -- State validation: must be APPROVED (having passed all management approval tiers)
    IF v_advance.status = 'PAID' THEN
        RETURN jsonb_build_object('success', false, 'code', 'ALREADY_PAID', 'message', 'This cash advance has already been paid.');
    END IF;

    IF v_advance.status != 'APPROVED' THEN
        RETURN jsonb_build_object('success', false, 'code', 'ADVANCE_NOT_APPROVED',
            'message', 'Only cash advances that have completed all management approval tiers can be disbursed. Current status: ' || v_advance.status::text);
    END IF;

    -- Transition to PAID
    UPDATE cash_advances
    SET status = 'PAID',
        current_approval_stage = 'COMPLETED',
        paid_at = now(),
        updated_at = now()
    WHERE id = p_advance_id;

    PERFORM record_audit_log(
        'ADVANCE_PAID', 'cash_advances', p_advance_id, to_jsonb(v_advance),
        jsonb_build_object(
            'status', 'PAID',
            'paid_amount_minor', v_advance.aed_amount_minor,
            'payment_reference', trim(p_payment_reference),
            'payment_method', p_payment_method,
            'disbursed_by', v_user_id,
            'notes', p_notes
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'ADVANCE_PAID',
        'advance_id', p_advance_id,
        'amount_minor', v_advance.amount_minor,
        'aed_amount_minor', v_advance.aed_amount_minor,
        'status', 'PAID'
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 8. LEFTOVER CASH ADVANCE REFUND RPC (Option A: Finance Records Returned Unused Balance)
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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_advance RECORD;
    v_unreconciled_minor BIGINT;
    v_new_returned_minor BIGINT;
    v_refund_id UUID;
    v_new_status cash_advance_status;
BEGIN
    -- 1. Authorization: Finance or Admin only
    IF NOT (has_role('FINANCE') OR has_role('ADMIN')) THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only Finance or Admin can record cash advance refunds.');
    END IF;

    -- 2. Validate inputs
    IF p_refund_amount_minor IS NULL OR p_refund_amount_minor <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REFUND_AMOUNT', 'message', 'Refund amount must be greater than zero.');
    END IF;

    IF p_refund_reference IS NULL OR length(trim(p_refund_reference)) = 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'REFERENCE_REQUIRED', 'message', 'Refund transaction reference is mandatory.');
    END IF;

    -- 3. Idempotency check
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id INTO v_refund_id FROM advance_refunds WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            SELECT * INTO v_advance FROM cash_advances WHERE id = p_advance_id;
            RETURN jsonb_build_object(
                'success', true, 'code', 'REFUND_REPLAYED', 'replayed', true,
                'refund_id', v_refund_id, 'advance_id', p_advance_id,
                'status', v_advance.status,
                'message', 'Refund previously recorded.'
            );
        END IF;
    END IF;

    -- 4. Concurrency lock on advance
    SELECT * INTO v_advance FROM cash_advances WHERE id = p_advance_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'ADVANCE_NOT_FOUND', 'message', 'Cash advance not found.');
    END IF;

    -- Must be in PAID or PARTIALLY_SETTLED status
    IF v_advance.status NOT IN ('PAID', 'PARTIALLY_SETTLED') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS',
            'message', 'Only paid or partially settled advances can have unused funds refunded. Current status: ' || v_advance.status::text);
    END IF;

    -- Prevent self-refund recording
    IF v_advance.employee_id = v_user_id THEN
        RETURN jsonb_build_object('success', false, 'code', 'SELF_REFUND_FORBIDDEN', 'message', 'Finance personnel cannot record refunds for their own cash advances.');
    END IF;

    -- Calculate remaining unreconciled balance: aed_amount_minor - reconciled_amount_minor - returned_amount_minor
    v_unreconciled_minor := v_advance.aed_amount_minor - v_advance.reconciled_amount_minor - COALESCE(v_advance.returned_amount_minor, 0);

    IF p_refund_amount_minor > v_unreconciled_minor THEN
        RETURN jsonb_build_object(
            'success', false, 'code', 'OVER_REFUND_PROHIBITED',
            'message', 'Refund amount (AED ' || (p_refund_amount_minor / 100)::text || ') exceeds the remaining advance balance (AED ' || (v_unreconciled_minor / 100)::text || ').'
        );
    END IF;

    v_new_returned_minor := COALESCE(v_advance.returned_amount_minor, 0) + p_refund_amount_minor;

    -- If fully accounted for (reconciled + returned = total): SETTLED
    IF (v_advance.reconciled_amount_minor + v_new_returned_minor) >= v_advance.aed_amount_minor THEN
        v_new_status := 'SETTLED';
    ELSE
        v_new_status := 'PARTIALLY_SETTLED';
    END IF;

    -- Insert refund record
    INSERT INTO advance_refunds (
        advance_id, refund_amount_minor, refund_reference, refund_date,
        payment_method, processed_by, notes, idempotency_key
    ) VALUES (
        p_advance_id, p_refund_amount_minor, trim(p_refund_reference), COALESCE(p_refund_date, CURRENT_DATE),
        p_payment_method, v_user_id, p_notes, p_idempotency_key
    ) RETURNING id INTO v_refund_id;

    -- Update advance
    UPDATE cash_advances
    SET returned_amount_minor = v_new_returned_minor,
        status = v_new_status,
        updated_at = now()
    WHERE id = p_advance_id;

    -- Audit log
    PERFORM record_audit_log(
        'ADVANCE_REFUNDED', 'cash_advances', p_advance_id, to_jsonb(v_advance),
        jsonb_build_object(
            'refund_id', v_refund_id,
            'refund_amount_minor', p_refund_amount_minor,
            'total_returned_minor', v_new_returned_minor,
            'new_status', v_new_status,
            'refund_reference', trim(p_refund_reference),
            'processed_by', v_user_id
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'REFUND_RECORDED',
        'refund_id', v_refund_id,
        'advance_id', p_advance_id,
        'refund_amount_minor', p_refund_amount_minor,
        'total_returned_minor', v_new_returned_minor,
        'remaining_balance_minor', v_advance.aed_amount_minor - v_advance.reconciled_amount_minor - v_new_returned_minor,
        'status', v_new_status,
        'message', 'Refund recorded successfully. Advance status is now ' || v_new_status::text
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 9. UPDATE RECALCULATE_CLAIM_TOTALS FOR RETURNED AMOUNTS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recalculate_claim_totals(p_claim_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_claim RECORD;
    v_advance RECORD;
    v_total BIGINT := 0;
    v_reserved BIGINT := 0;
    v_available BIGINT := 0;
    v_applied BIGINT := 0;
BEGIN
    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT COALESCE(SUM(e.aed_amount_minor), 0) INTO v_total
    FROM claim_expenses ce JOIN expenses e ON e.id = ce.expense_id
    WHERE ce.claim_id = p_claim_id AND ce.released_at IS NULL;

    IF v_claim.cash_advance_id IS NOT NULL THEN
        SELECT * INTO v_advance FROM cash_advances WHERE id = v_claim.cash_advance_id FOR UPDATE;
        IF NOT FOUND OR v_advance.employee_id <> v_claim.employee_id THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADVANCE_INVALID',
                DETAIL = 'The selected cash advance is not available for reconciliation.';
        END IF;
        IF v_advance.status NOT IN ('PAID', 'PARTIALLY_SETTLED') THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADVANCE_NOT_ELIGIBLE',
                DETAIL = 'Only a paid cash advance with an outstanding balance can be applied.';
        END IF;

        SELECT COALESCE(SUM(advance_applied_minor), 0) INTO v_reserved
        FROM expense_claims
        WHERE cash_advance_id = v_advance.id AND id <> p_claim_id
          AND status IN ('SUBMITTED', 'LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW', 'CORRECTION_REQUIRED');

        -- Subtract returned_amount_minor as well as reconciled_amount_minor
        v_available := GREATEST(v_advance.aed_amount_minor - v_advance.reconciled_amount_minor - COALESCE(v_advance.returned_amount_minor, 0) - v_reserved, 0);
        IF v_available = 0 THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADVANCE_EXHAUSTED',
                DETAIL = 'The selected cash advance has no remaining balance; it is fully applied, refunded, or reserved.';
        END IF;
        v_applied := LEAST(v_total, v_available);
    END IF;

    UPDATE expense_claims
    SET total_expense_minor = v_total,
        advance_applied_minor = v_applied,
        net_reimbursement_minor = v_total - v_applied,
        updated_at = now()
    WHERE id = p_claim_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- 9B. UPDATE PROCESS_APPROVAL_ACTION FOR ADVANCE SETTLEMENT WITH REFUNDS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_approval_action(
    p_claim_id UUID,
    p_action approval_action_type,
    p_comments TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_claim RECORD;
    v_instance RECORD;
    v_employee RECORD;
    v_next_status claim_status;
    v_next_approver UUID := NULL;
    v_next_role app_role := NULL;
    v_is_authorized BOOLEAN := false;
BEGIN
    -- 1. Row locking for concurrency protection
    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CLAIM_NOT_FOUND', 'message', 'Claim not found.');
    END IF;

    -- 2. Prevent Self-Approval under all circumstances
    IF v_claim.employee_id = v_user_id THEN
        RETURN jsonb_build_object('success', false, 'code', 'SELF_APPROVAL_FORBIDDEN', 'message', 'Self-approval is strictly forbidden by ASM policy.');
    END IF;

    -- 3. Cannot action claims that are already finalized
    IF v_claim.status IN ('APPROVED', 'SETTLED', 'REJECTED', 'CANCELLED') THEN
        RETURN jsonb_build_object('success', false, 'code', 'ALREADY_FINALIZED', 'message', 'This claim has already been finalized.');
    END IF;

    -- 4. Load employee and active approval instance with lock
    SELECT * INTO v_employee FROM employees WHERE id = v_claim.employee_id;
    SELECT * INTO v_instance FROM approval_instances 
    WHERE claim_id = p_claim_id AND status = 'IN_PROGRESS' 
    ORDER BY started_at DESC LIMIT 1 FOR UPDATE;

    -- 5. Cross-Stage Duplicate Approval Prevention:
    IF p_action = 'APPROVE' THEN
        IF EXISTS (
            SELECT 1 FROM approval_actions
            WHERE claim_id = p_claim_id
              AND actor_id = v_user_id
              AND action = 'APPROVE'
              AND (v_instance.id IS NULL OR approval_instance_id = v_instance.id)
        ) THEN
            RETURN jsonb_build_object(
                'success', false,
                'code', 'ALREADY_APPROVED_PREVIOUS_STAGE',
                'message', 'You have already approved this claim at an earlier approval stage and cannot approve it again.'
            );
        END IF;
    END IF;

    -- 6. Verify Authorization strictly based on current workflow step
    IF v_claim.status = 'LINE_MANAGER_REVIEW' THEN
        IF (v_employee.line_manager_id = v_user_id) OR has_role('ADMIN') THEN
            v_is_authorized := true;
        END IF;
    ELSIF v_claim.status = 'HOD_REVIEW' THEN
        IF (v_employee.hod_id = v_user_id) OR has_role('ADMIN') THEN
            v_is_authorized := true;
        END IF;
    ELSIF v_claim.status = 'SIVA_REVIEW' THEN
        IF has_role('MANAGEMENT') OR has_role('ADMIN') THEN
            v_is_authorized := true;
        END IF;
    ELSIF v_claim.status = 'FINANCE_REVIEW' THEN
        IF has_role('FINANCE') OR has_role('ADMIN') THEN
            v_is_authorized := true;
        END IF;
    END IF;

    IF NOT v_is_authorized THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You are not authorized to review this claim at this stage.');
    END IF;

    -- 7. Action: REJECT
    IF p_action = 'REJECT' THEN
        IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
            RETURN jsonb_build_object('success', false, 'code', 'COMMENT_REQUIRED', 'message', 'Reason comments are mandatory when rejecting a claim.');
        END IF;

        UPDATE expense_claims SET status = 'REJECTED', updated_at = now() WHERE id = p_claim_id;
        IF v_instance.id IS NOT NULL THEN
            UPDATE approval_instances SET status = 'REJECTED', completed_at = now() WHERE id = v_instance.id;
        END IF;
        -- Unlock expenses
        UPDATE expenses SET is_locked = false WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id AND released_at IS NULL);

        INSERT INTO approval_actions (approval_instance_id, claim_id, step_order, actor_id, action, previous_status, new_status, comments)
        VALUES (v_instance.id, p_claim_id, COALESCE(v_instance.current_step_order, 1), v_user_id, 'REJECT', v_claim.status, 'REJECTED', p_comments);

        PERFORM record_audit_log('CLAIM_REJECTED', 'expense_claims', p_claim_id, to_jsonb(v_claim), jsonb_build_object(
            'status', 'REJECTED',
            'comments', p_comments,
            'actor_id', v_user_id
        ));

        RETURN jsonb_build_object('success', true, 'status', 'REJECTED');
    END IF;

    -- 8. Action: REQUEST_CORRECTION
    IF p_action = 'REQUEST_CORRECTION' THEN
        IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
            RETURN jsonb_build_object('success', false, 'code', 'COMMENT_REQUIRED', 'message', 'Please specify what correction is required.');
        END IF;

        UPDATE expense_claims SET status = 'CORRECTION_REQUIRED', validation_notes = p_comments, updated_at = now() WHERE id = p_claim_id;
        IF v_instance.id IS NOT NULL THEN
            UPDATE approval_instances SET status = 'CORRECTION_REQUIRED' WHERE id = v_instance.id;
        END IF;
        -- Unlock expenses for employee modification
        UPDATE expenses SET is_locked = false WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id AND released_at IS NULL);

        INSERT INTO approval_actions (approval_instance_id, claim_id, step_order, actor_id, action, previous_status, new_status, comments)
        VALUES (v_instance.id, p_claim_id, COALESCE(v_instance.current_step_order, 1), v_user_id, 'REQUEST_CORRECTION', v_claim.status, 'CORRECTION_REQUIRED', p_comments);

        PERFORM record_audit_log('CLAIM_CORRECTION_REQUESTED', 'expense_claims', p_claim_id, to_jsonb(v_claim), jsonb_build_object(
            'status', 'CORRECTION_REQUIRED',
            'comments', p_comments,
            'actor_id', v_user_id
        ));

        RETURN jsonb_build_object('success', true, 'status', 'CORRECTION_REQUIRED');
    END IF;

    -- 9. Action: APPROVE
    IF p_action = 'APPROVE' THEN
        IF v_claim.status = 'LINE_MANAGER_REVIEW' THEN
            v_next_status := 'HOD_REVIEW';
            v_next_approver := v_employee.hod_id;
            v_next_role := 'DEPARTMENT_MANAGER';
        ELSIF v_claim.status = 'HOD_REVIEW' THEN
            -- Step 2 -> Step 3: Advance to SIVA_REVIEW
            v_next_status := 'SIVA_REVIEW';
            v_next_approver := NULL;
            v_next_role := 'MANAGEMENT';
        ELSIF v_claim.status = 'SIVA_REVIEW' THEN
            -- Step 3 -> Step 4: Advance to FINANCE_REVIEW
            v_next_status := 'FINANCE_REVIEW';
            v_next_approver := NULL;
            v_next_role := 'FINANCE';
        ELSIF v_claim.status = 'FINANCE_REVIEW' THEN
            -- Step 4 -> Final: APPROVED
            v_next_status := 'APPROVED';
            v_next_approver := NULL;
            v_next_role := NULL;
        ELSE
            RETURN jsonb_build_object('success', false, 'code', 'INVALID_STAGE_TRANSITION', 'message', 'Claim is not currently in an approvable stage.');
        END IF;

        IF v_instance.id IS NOT NULL THEN
            INSERT INTO approval_actions (approval_instance_id, claim_id, step_order, actor_id, action, previous_status, new_status, comments)
            VALUES (v_instance.id, p_claim_id, v_instance.current_step_order, v_user_id, 'APPROVE', v_claim.status, v_next_status, p_comments);
        END IF;

        IF v_next_status = 'APPROVED' THEN
            UPDATE expense_claims SET status = 'APPROVED', approved_at = now(), updated_at = now() WHERE id = p_claim_id;
            IF v_instance.id IS NOT NULL THEN
                UPDATE approval_instances SET status = 'APPROVED', completed_at = now() WHERE id = v_instance.id;
            END IF;

            IF v_claim.net_reimbursement_minor > 0 THEN
                INSERT INTO reimbursements (claim_id, employee_id, amount_minor, currency_code, aed_amount_minor, status)
                VALUES (p_claim_id, v_claim.employee_id, v_claim.net_reimbursement_minor, 'AED', v_claim.net_reimbursement_minor, 'PENDING')
                ON CONFLICT (claim_id) DO NOTHING;
            ELSE
                UPDATE expense_claims SET status = 'SETTLED' WHERE id = p_claim_id;
            END IF;

            -- Reconcile advance balance (accounting for returned refunds)
            IF v_claim.cash_advance_id IS NOT NULL AND v_claim.advance_applied_minor > 0 THEN
                UPDATE cash_advances
                SET reconciled_amount_minor = reconciled_amount_minor + v_claim.advance_applied_minor,
                    status = CASE 
                        WHEN (reconciled_amount_minor + v_claim.advance_applied_minor + COALESCE(returned_amount_minor, 0)) >= aed_amount_minor THEN 'SETTLED'::cash_advance_status
                        ELSE 'PARTIALLY_SETTLED'::cash_advance_status
                    END,
                    updated_at = now()
                WHERE id = v_claim.cash_advance_id;
            END IF;
        ELSE
            UPDATE expense_claims SET status = v_next_status, updated_at = now() WHERE id = p_claim_id;
            IF v_instance.id IS NOT NULL THEN
                UPDATE approval_instances 
                SET current_step_order = current_step_order + 1,
                    current_approver_id = v_next_approver,
                    current_approver_role = v_next_role
                WHERE id = v_instance.id;
            END IF;
        END IF;

        PERFORM record_audit_log('CLAIM_APPROVED_STAGE', 'expense_claims', p_claim_id, to_jsonb(v_claim), jsonb_build_object(
            'previous_status', v_claim.status,
            'new_status', v_next_status,
            'actor_id', v_user_id,
            'comments', p_comments
        ));

        RETURN jsonb_build_object('success', true, 'status', v_next_status);
    END IF;

    RETURN jsonb_build_object('success', false, 'code', 'UNSUPPORTED_ACTION', 'message', 'Action not supported.');
END;
$$;

-- ----------------------------------------------------------------------------
-- 10. SECURE ATOMIC CLAIM CANCELLATION RPC
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancel_expense_claim(
    p_claim_id UUID,
    p_cancellation_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_claim RECORD;
BEGIN
    IF p_cancellation_reason IS NULL OR length(trim(p_cancellation_reason)) = 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'REASON_REQUIRED', 'message', 'A cancellation reason is mandatory.');
    END IF;

    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CLAIM_NOT_FOUND', 'message', 'Claim not found.');
    END IF;

    -- Ownership check: Claim owner or Admin
    IF v_claim.employee_id != v_user_id AND NOT has_role('ADMIN') THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only the claim owner or an administrator can cancel a claim.');
    END IF;

    -- Prohibit cancellation of paid or settled claims
    IF v_claim.status IN ('APPROVED', 'REIMBURSEMENT_PROCESSING', 'PAID', 'SETTLED') THEN
        RETURN jsonb_build_object('success', false, 'code', 'CANNOT_CANCEL_FINALIZED',
            'message', 'Claims that are approved, processing, paid, or settled cannot be cancelled.');
    END IF;

    IF v_claim.status = 'CANCELLED' THEN
        RETURN jsonb_build_object('success', false, 'code', 'ALREADY_CANCELLED', 'message', 'This claim is already cancelled.');
    END IF;

    -- Atomic transition to CANCELLED
    -- Note: Trigger trg_claim_lifecycle_effects automatically releases claim_expenses, unlocks expenses, and releases advance reservations!
    UPDATE expense_claims
    SET status = 'CANCELLED',
        validation_notes = p_cancellation_reason,
        updated_at = now()
    WHERE id = p_claim_id;

    -- Mark active approval instance as cancelled
    UPDATE approval_instances
    SET status = 'CANCELLED', completed_at = now()
    WHERE claim_id = p_claim_id AND status = 'IN_PROGRESS';

    PERFORM record_audit_log(
        'CLAIM_CANCELLED', 'expense_claims', p_claim_id, to_jsonb(v_claim),
        jsonb_build_object(
            'previous_status', v_claim.status,
            'cancellation_reason', trim(p_cancellation_reason),
            'cancelled_by', v_user_id
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'CLAIM_CANCELLED',
        'claim_id', p_claim_id,
        'status', 'CANCELLED',
        'message', 'Claim successfully cancelled. Expenses and cash advance reservations have been released.'
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 11. CASH ADVANCE CANCELLATION RPC
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cancel_cash_advance(
    p_advance_id UUID,
    p_cancellation_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_advance RECORD;
BEGIN
    IF p_cancellation_reason IS NULL OR length(trim(p_cancellation_reason)) = 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'REASON_REQUIRED', 'message', 'A cancellation reason is mandatory.');
    END IF;

    SELECT * INTO v_advance FROM cash_advances WHERE id = p_advance_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'ADVANCE_NOT_FOUND', 'message', 'Cash advance not found.');
    END IF;

    IF v_advance.employee_id != v_user_id AND NOT has_role('ADMIN') THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only the advance requester or an administrator can cancel this request.');
    END IF;

    IF v_advance.status IN ('PAID', 'PARTIALLY_SETTLED', 'SETTLED') THEN
        RETURN jsonb_build_object('success', false, 'code', 'CANNOT_CANCEL_DISBURSED',
            'message', 'Disbursed or settled cash advances cannot be cancelled.');
    END IF;

    IF v_advance.status = 'CANCELLED' THEN
        RETURN jsonb_build_object('success', false, 'code', 'ALREADY_CANCELLED', 'message', 'This cash advance is already cancelled.');
    END IF;

    UPDATE cash_advances
    SET status = 'CANCELLED',
        updated_at = now()
    WHERE id = p_advance_id;

    PERFORM record_audit_log(
        'ADVANCE_CANCELLED', 'cash_advances', p_advance_id, to_jsonb(v_advance),
        jsonb_build_object(
            'previous_status', v_advance.status,
            'cancellation_reason', trim(p_cancellation_reason),
            'cancelled_by', v_user_id
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'ADVANCE_CANCELLED',
        'advance_id', p_advance_id,
        'status', 'CANCELLED'
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 12. RLS POLICIES FOR REFUNDS AND ADVANCE APPROVAL ACTIONS
-- ----------------------------------------------------------------------------
ALTER TABLE advance_approval_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE advance_refunds ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Advance approval actions visibility" ON advance_approval_actions;
CREATE POLICY "Advance approval actions visibility" ON advance_approval_actions FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM cash_advances a
        WHERE a.id = advance_approval_actions.advance_id
          AND (
            a.employee_id = auth_employee_id()
            OR is_manager_of(a.employee_id)
            OR is_hod_of(a.employee_id)
            OR has_role('MANAGEMENT')
            OR has_role('FINANCE')
            OR has_role('ADMIN')
          )
    )
);

DROP POLICY IF EXISTS "Advance refunds visibility" ON advance_refunds;
CREATE POLICY "Advance refunds visibility" ON advance_refunds FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM cash_advances a
        WHERE a.id = advance_refunds.advance_id
          AND (
            a.employee_id = auth_employee_id()
            OR has_role('FINANCE')
            OR has_role('ADMIN')
          )
    )
);

-- ----------------------------------------------------------------------------
-- 13. EXECUTION PERMISSIONS
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION request_cash_advance(BIGINT, CHAR, TEXT, DATE, DATE, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION request_cash_advance(BIGINT, CHAR, TEXT, DATE, DATE, UUID) TO authenticated;

REVOKE ALL ON FUNCTION review_cash_advance(UUID, approval_action_type, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION review_cash_advance(UUID, approval_action_type, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION record_cash_advance_payment(UUID, VARCHAR, VARCHAR, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION record_cash_advance_payment(UUID, VARCHAR, VARCHAR, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION record_cash_advance_refund(UUID, BIGINT, VARCHAR, DATE, VARCHAR, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION record_cash_advance_refund(UUID, BIGINT, VARCHAR, DATE, VARCHAR, TEXT, UUID) TO authenticated;

REVOKE ALL ON FUNCTION cancel_expense_claim(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cancel_expense_claim(UUID, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION cancel_cash_advance(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cancel_cash_advance(UUID, TEXT) TO authenticated;

REVOKE ALL ON FUNCTION process_approval_action(UUID, approval_action_type, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION process_approval_action(UUID, approval_action_type, TEXT) TO authenticated;
