-- ============================================================================
-- ASM Expense & Reimbursement Platform - Settlement, Correction & Advances
-- Migration: 20261019000007_settlement_correction_advances.sql
--
-- 1. Expense <-> claim links become releasable history (rejected / cancelled /
--    removed in correction) instead of a permanent one-claim-per-expense rule
-- 2. Server-side claim status state machine (also serializes double approvals)
-- 3. Cash advance reservation: available = amount - reconciled - reserved by
--    other active claims, computed under a row lock
-- 4. Correction + resubmission RPC (resubmit_corrected_claim)
-- 5. Reimbursement payment fixed against the actual schema (payments table)
-- 6. Audit coverage for links, reimbursements, advances, resubmission, payment
--
-- The approval hierarchy (HOD -> FINANCE vs HOD -> SIVA -> FINANCE) is NOT
-- changed here; both transitions remain permitted by the state machine.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. CLAIM <-> EXPENSE LINK HISTORY
-- ----------------------------------------------------------------------------
ALTER TABLE claim_expenses ADD COLUMN IF NOT EXISTS released_at TIMESTAMPTZ;
ALTER TABLE claim_expenses ADD COLUMN IF NOT EXISTS release_reason VARCHAR(40);
DO $$ BEGIN
    ALTER TABLE claim_expenses ADD CONSTRAINT chk_claim_expense_release CHECK (
        (released_at IS NULL AND release_reason IS NULL)
        OR (released_at IS NOT NULL AND release_reason IN ('CLAIM_REJECTED', 'CLAIM_CANCELLED', 'REMOVED_IN_CORRECTION'))
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Links of claims that already ended without payment are released (history kept).
UPDATE claim_expenses ce
SET released_at = c.updated_at, release_reason = 'CLAIM_' || c.status::text
FROM expense_claims c
WHERE c.id = ce.claim_id AND c.status IN ('REJECTED', 'CANCELLED') AND ce.released_at IS NULL;

-- One ACTIVE claim per expense (replaces the 000005 permanent UNIQUE(expense_id)).
CREATE UNIQUE INDEX IF NOT EXISTS uq_claim_expenses_active_expense ON claim_expenses(expense_id) WHERE released_at IS NULL;
ALTER TABLE claim_expenses DROP CONSTRAINT IF EXISTS unique_expense_per_claim;
CREATE INDEX IF NOT EXISTS idx_claim_expenses_expense ON claim_expenses(expense_id);
CREATE INDEX IF NOT EXISTS idx_claims_cash_advance ON expense_claims(cash_advance_id) WHERE cash_advance_id IS NOT NULL;

-- Configurable: may an expense from a REJECTED claim be claimed again?
-- (Cancelled claims and expenses removed during correction are always reusable.)
INSERT INTO policy_rules (policy_id, rule_key, rule_value, description, is_active)
SELECT id, 'allow_expense_reuse_after_rejection', '{"enabled": true}'::jsonb,
       'Whether expenses from a rejected claim may be included in a new claim', true
FROM policies WHERE code = 'ASM_EXPENSE_POLICY_2026'
ON CONFLICT (rule_key) DO NOTHING;

-- Shared structured error response for claim RPCs
CREATE OR REPLACE FUNCTION claim_failure_response(p_code TEXT, p_detail TEXT)
RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp
AS $$
DECLARE
    v_eval JSONB;
    v_vendors TEXT;
BEGIN
    IF p_code = 'RECEIPT_TOTAL_MISMATCH' THEN
        v_eval := p_detail::jsonb;
        SELECT string_agg(DISTINCT m->>'vendor', ', ') INTO v_vendors
        FROM jsonb_array_elements(v_eval->'mismatches') AS m;
        RETURN jsonb_build_object('success', false, 'code', p_code,
            'validation_status', 'CORRECTION_REQUIRED',
            'breakup_total_minor', v_eval->'breakup_total_minor',
            'receipt_total_minor', v_eval->'receipt_total_minor',
            'mismatches', v_eval->'mismatches',
            'message', 'Receipt totals do not match the claimed amounts for: ' || COALESCE(v_vendors, 'selected expenses')
                || '. Correct these expenses or their receipts and submit again.');
    END IF;
    RETURN jsonb_build_object('success', false, 'code', p_code,
        'message', COALESCE(NULLIF(p_detail, ''), 'Claim could not be submitted.'));
END;
$$;

-- Guards every link activation / release.
CREATE OR REPLACE FUNCTION guard_claim_expense_link_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_claim RECORD;
    v_owner UUID;
    v_prev_claim UUID;
    v_reuse_allowed BOOLEAN;
BEGIN
    IF TG_OP = 'UPDATE' AND (NEW.claim_id IS DISTINCT FROM OLD.claim_id OR NEW.expense_id IS DISTINCT FROM OLD.expense_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'LINK_IMMUTABLE', DETAIL = 'Claim expense links cannot be reassigned.';
    END IF;

    SELECT status, employee_id INTO v_claim FROM expense_claims WHERE id = NEW.claim_id;

    IF TG_OP = 'UPDATE' AND OLD.released_at IS NULL AND NEW.released_at IS NOT NULL THEN
        IF v_claim.status NOT IN ('DRAFT', 'CORRECTION_REQUIRED', 'REJECTED', 'CANCELLED') THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'EXPENSE_LINK_LOCKED',
                DETAIL = 'Expenses on claims under review, approved or paid cannot be released.';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.released_at IS NULL AND (TG_OP = 'INSERT' OR OLD.released_at IS NOT NULL) THEN
        IF v_claim.status NOT IN ('DRAFT', 'CORRECTION_REQUIRED') THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'CLAIM_NOT_EDITABLE',
                DETAIL = 'Expenses can only be added to a claim that is being prepared or corrected.';
        END IF;
        SELECT employee_id INTO v_owner FROM expenses WHERE id = NEW.expense_id;
        IF v_owner IS DISTINCT FROM v_claim.employee_id THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'EXPENSE_NOT_FOUND',
                DETAIL = 'One or more selected expenses could not be found in your account.';
        END IF;

        SELECT ce.claim_id INTO v_prev_claim FROM claim_expenses ce
        WHERE ce.expense_id = NEW.expense_id AND ce.release_reason = 'CLAIM_REJECTED' AND ce.claim_id <> NEW.claim_id
        ORDER BY ce.released_at DESC LIMIT 1;
        IF v_prev_claim IS NOT NULL THEN
            SELECT (rule_value->>'enabled')::BOOLEAN INTO v_reuse_allowed
            FROM policy_rules WHERE rule_key = 'allow_expense_reuse_after_rejection' AND is_active = true;
            IF NOT COALESCE(v_reuse_allowed, true) THEN
                RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'EXPENSE_REUSE_NOT_ALLOWED',
                    DETAIL = 'An expense from a rejected claim cannot be claimed again under the current policy.';
            END IF;
            PERFORM record_audit_log('EXPENSE_REUSED_AFTER_REJECTION', 'expenses', NEW.expense_id,
                jsonb_build_object('previous_claim_id', v_prev_claim), jsonb_build_object('claim_id', NEW.claim_id));
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_claim_expense_link ON claim_expenses;
CREATE TRIGGER trg_guard_claim_expense_link
BEFORE INSERT OR UPDATE ON claim_expenses
FOR EACH ROW EXECUTE FUNCTION guard_claim_expense_link_trigger();

DROP TRIGGER IF EXISTS trg_audit_claim_expenses ON claim_expenses;
CREATE TRIGGER trg_audit_claim_expenses
AFTER INSERT OR UPDATE ON claim_expenses
FOR EACH ROW EXECUTE FUNCTION audit_entity_change_trigger();

-- An expense actively linked to a claim under review / approved / paid stays
-- locked, whichever function attempts the unlock.
CREATE OR REPLACE FUNCTION keep_claimed_expense_locked_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    IF OLD.is_locked AND NOT NEW.is_locked AND EXISTS (
        SELECT 1 FROM claim_expenses ce
        JOIN expense_claims c ON c.id = ce.claim_id
        WHERE ce.expense_id = NEW.id AND ce.released_at IS NULL
          AND c.status IN ('SUBMITTED', 'LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW',
                           'APPROVED', 'REIMBURSEMENT_PROCESSING', 'PAID', 'SETTLED')
    ) THEN
        NEW.is_locked := true;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_keep_claimed_expense_locked ON expenses;
CREATE TRIGGER trg_keep_claimed_expense_locked
BEFORE UPDATE OF is_locked ON expenses
FOR EACH ROW EXECUTE FUNCTION keep_claimed_expense_locked_trigger();

-- ----------------------------------------------------------------------------
-- 2. CLAIM STATUS STATE MACHINE
-- Applies to every writer (clients, admins, workflow functions). A stale
-- concurrent approval re-applying the same step is rejected here.
-- HOD_REVIEW -> SIVA_REVIEW and HOD_REVIEW -> FINANCE_REVIEW are both allowed
-- pending the business decision on the Management stage.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_claim_status_transition_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_allowed claim_status[];
BEGIN
    v_allowed := CASE OLD.status
        WHEN 'DRAFT' THEN ARRAY['LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'CANCELLED']::claim_status[]
        WHEN 'CORRECTION_REQUIRED' THEN ARRAY['LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'CANCELLED']::claim_status[]
        WHEN 'LINE_MANAGER_REVIEW' THEN ARRAY['HOD_REVIEW', 'REJECTED', 'CORRECTION_REQUIRED']::claim_status[]
        WHEN 'HOD_REVIEW' THEN ARRAY['SIVA_REVIEW', 'FINANCE_REVIEW', 'REJECTED', 'CORRECTION_REQUIRED']::claim_status[]
        WHEN 'SIVA_REVIEW' THEN ARRAY['FINANCE_REVIEW', 'REJECTED', 'CORRECTION_REQUIRED']::claim_status[]
        WHEN 'FINANCE_REVIEW' THEN ARRAY['APPROVED', 'REJECTED', 'CORRECTION_REQUIRED']::claim_status[]
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

-- Lifecycle side effects: release links on rejection/cancellation and audit
-- advance reservation / release / application.
CREATE OR REPLACE FUNCTION claim_lifecycle_effects_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_reason TEXT;
BEGIN
    IF NEW.status IN ('REJECTED', 'CANCELLED') AND OLD.status IS DISTINCT FROM NEW.status THEN
        v_reason := 'CLAIM_' || NEW.status::text;
        UPDATE claim_expenses SET released_at = now(), release_reason = v_reason
        WHERE claim_id = NEW.id AND released_at IS NULL;
        UPDATE expenses SET is_locked = false
        WHERE is_locked AND id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = NEW.id AND release_reason = v_reason);
    END IF;

    IF OLD.cash_advance_id IS NOT NULL
       AND OLD.status IN ('SUBMITTED', 'LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW', 'CORRECTION_REQUIRED')
       AND (NEW.cash_advance_id IS DISTINCT FROM OLD.cash_advance_id OR NEW.status IN ('REJECTED', 'CANCELLED')) THEN
        PERFORM record_audit_log('ADVANCE_RELEASED', 'cash_advances', OLD.cash_advance_id,
            jsonb_build_object('claim_id', NEW.id, 'released_minor', OLD.advance_applied_minor),
            jsonb_build_object('reason', CASE WHEN NEW.status IN ('REJECTED', 'CANCELLED') THEN 'CLAIM_' || NEW.status::text ELSE 'ADVANCE_CHANGED' END));
    END IF;

    IF NEW.cash_advance_id IS NOT NULL AND OLD.status IN ('DRAFT', 'CORRECTION_REQUIRED')
       AND NEW.status IN ('LINE_MANAGER_REVIEW', 'HOD_REVIEW') THEN
        PERFORM record_audit_log('ADVANCE_RESERVED', 'cash_advances', NEW.cash_advance_id, NULL,
            jsonb_build_object('claim_id', NEW.id, 'reserved_minor', NEW.advance_applied_minor));
    END IF;

    IF NEW.cash_advance_id IS NOT NULL AND OLD.status = 'FINANCE_REVIEW' AND NEW.status = 'APPROVED' THEN
        PERFORM record_audit_log('ADVANCE_APPLIED', 'cash_advances', NEW.cash_advance_id, NULL,
            jsonb_build_object('claim_id', NEW.id, 'applied_minor', NEW.advance_applied_minor));
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_claim_lifecycle_effects ON expense_claims;
CREATE TRIGGER trg_claim_lifecycle_effects
AFTER UPDATE OF status, cash_advance_id ON expense_claims
FOR EACH ROW EXECUTE FUNCTION claim_lifecycle_effects_trigger();

-- Clients may no longer change the advance on a claim directly.
CREATE OR REPLACE FUNCTION protect_claim_financials_and_status_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp
AS $$
BEGIN
    IF current_user IN ('authenticated', 'anon') AND NOT has_role('ADMIN') THEN
        IF OLD.status NOT IN ('DRAFT', 'CORRECTION_REQUIRED') THEN
            RAISE EXCEPTION 'Security Violation: Claim is locked under review and cannot be modified directly.';
        END IF;

        IF NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'Security Violation: Direct modification of claim status is prohibited. Use workflow approval functions.';
        END IF;

        IF NEW.total_expense_minor IS DISTINCT FROM OLD.total_expense_minor
           OR NEW.advance_applied_minor IS DISTINCT FROM OLD.advance_applied_minor
           OR NEW.net_reimbursement_minor IS DISTINCT FROM OLD.net_reimbursement_minor THEN
            RAISE EXCEPTION 'Security Violation: Direct modification of financial totals is prohibited. Totals are computed server-side.';
        END IF;

        IF NEW.validation_status IS DISTINCT FROM OLD.validation_status THEN
            RAISE EXCEPTION 'Security Violation: Validation status is server-controlled.';
        END IF;

        IF NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key THEN
            RAISE EXCEPTION 'Security Violation: Idempotency key is server-controlled.';
        END IF;

        IF NEW.cash_advance_id IS DISTINCT FROM OLD.cash_advance_id THEN
            RAISE EXCEPTION 'Security Violation: The cash advance on a claim can only be changed through correction and resubmission.';
        END IF;

        IF NEW.employee_id IS DISTINCT FROM OLD.employee_id OR NEW.claim_number IS DISTINCT FROM OLD.claim_number THEN
            RAISE EXCEPTION 'Security Violation: Claim ownership and number are server-controlled.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------------
-- 3. CASH ADVANCE RESERVATION
-- Reserved = advance_applied_minor of the employee's other claims that are
-- still in workflow. Approved claims are already counted in
-- reconciled_amount_minor (process_approval_action); rejected/cancelled
-- claims no longer reserve anything.
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

        v_available := GREATEST(v_advance.aed_amount_minor - v_advance.reconciled_amount_minor - v_reserved, 0);
        IF v_available = 0 THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADVANCE_EXHAUSTED',
                DETAIL = 'The selected cash advance has no remaining balance; it is fully applied or reserved by other claims.';
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
-- 4. ACTIVE-LINK AWARE VALIDATION (replaces 000006 versions)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION evaluate_claim_receipts(p_claim_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_tolerance BIGINT;
    v_breakup BIGINT;
    v_receipts BIGINT;
    v_mismatches JSONB;
BEGIN
    SELECT (rule_value->>'tolerance_minor')::BIGINT INTO v_tolerance
    FROM policy_rules WHERE rule_key = 'receipt_tolerance_aed' AND is_active = true;
    v_tolerance := COALESCE(v_tolerance, 0);

    WITH lines AS (
        SELECT e.id, e.vendor, e.aed_amount_minor, e.exchange_rate,
               COUNT(r.id) AS receipt_count,
               COUNT(r.id) FILTER (WHERE r.receipt_total_minor IS NULL) AS unverified_count,
               COUNT(r.id) FILTER (WHERE r.currency_code IS DISTINCT FROM e.currency_code) AS currency_mismatch_count,
               COALESCE(SUM(r.receipt_total_minor) FILTER (WHERE r.currency_code = e.currency_code), 0) AS receipt_total_minor
        FROM claim_expenses ce
        JOIN expenses e ON e.id = ce.expense_id
        LEFT JOIN expense_receipts r ON r.expense_id = e.id
        WHERE ce.claim_id = p_claim_id AND ce.released_at IS NULL AND e.has_receipt = true
        GROUP BY e.id
    ), evaluated AS (
        SELECT l.id, l.vendor, l.aed_amount_minor,
               ROUND(l.receipt_total_minor * l.exchange_rate)::BIGINT AS receipt_aed_minor,
               CASE
                   WHEN l.receipt_count = 0 THEN 'RECEIPT_MISSING'
                   WHEN l.unverified_count > 0 THEN 'RECEIPT_TOTAL_UNVERIFIED'
                   WHEN l.currency_mismatch_count > 0 THEN 'RECEIPT_CURRENCY_MISMATCH'
                   WHEN ABS(ROUND(l.receipt_total_minor * l.exchange_rate)::BIGINT - l.aed_amount_minor) > v_tolerance
                       THEN 'RECEIPT_TOTAL_MISMATCH'
               END AS reason
        FROM lines l
    )
    SELECT COALESCE(SUM(aed_amount_minor), 0),
           COALESCE(SUM(receipt_aed_minor), 0),
           COALESCE(jsonb_agg(jsonb_build_object(
               'expense_id', id, 'vendor', vendor, 'reason', reason,
               'expense_aed_minor', aed_amount_minor, 'receipt_aed_minor', receipt_aed_minor
           )) FILTER (WHERE reason IS NOT NULL), '[]'::jsonb)
    INTO v_breakup, v_receipts, v_mismatches
    FROM evaluated;

    RETURN jsonb_build_object(
        'valid', jsonb_array_length(v_mismatches) = 0,
        'breakup_total_minor', v_breakup,
        'receipt_total_minor', v_receipts,
        'tolerance_minor', v_tolerance,
        'mismatches', v_mismatches
    );
END;
$$;

CREATE OR REPLACE FUNCTION submit_claim_for_approval(p_claim_id UUID)
RETURNS JSONB AS $$
DECLARE
    v_claim RECORD;
    v_no_receipt_limit BIGINT;
    v_max_claim_limit BIGINT;
    v_violating_expenses RECORD;
    v_first_approver_id UUID;
    v_next_status claim_status;
    v_instance_id UUID;
BEGIN
    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CLAIM_NOT_FOUND', 'message', 'Claim not found.');
    END IF;

    IF v_claim.employee_id != auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'You can only submit your own claims.');
    END IF;

    IF v_claim.status NOT IN ('DRAFT', 'CORRECTION_REQUIRED') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Claim is not in editable status.');
    END IF;

    PERFORM recalculate_claim_totals(p_claim_id);
    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id;

    IF v_claim.total_expense_minor <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'EMPTY_CLAIM', 'message', 'Claim must contain at least one valid expense.');
    END IF;

    SELECT (rule_value->>'limit_minor')::BIGINT INTO v_no_receipt_limit
    FROM policy_rules WHERE rule_key = 'no_receipt_limit_aed';
    IF v_no_receipt_limit IS NULL THEN v_no_receipt_limit := 50000; END IF;

    SELECT (rule_value->>'limit_minor')::BIGINT INTO v_max_claim_limit
    FROM policy_rules WHERE rule_key = 'max_claim_limit_aed';
    IF v_max_claim_limit IS NULL THEN v_max_claim_limit := 1000000; END IF;

    IF v_claim.total_expense_minor > v_max_claim_limit THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'MAX_CLAIM_LIMIT_EXCEEDED',
            'message', 'Total claim exceeds the maximum allowed limit of AED ' || (v_max_claim_limit / 100)::text
        );
    END IF;

    SELECT e.id, e.vendor, e.aed_amount_minor INTO v_violating_expenses
    FROM claim_expenses ce
    JOIN expenses e ON ce.expense_id = e.id
    WHERE ce.claim_id = p_claim_id
      AND ce.released_at IS NULL
      AND e.has_receipt = false
      AND e.aed_amount_minor > v_no_receipt_limit
    LIMIT 1;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'RECEIPT_REQUIRED',
            'message', 'Expense for "' || v_violating_expenses.vendor || '" of AED ' || (v_violating_expenses.aed_amount_minor / 100)::text || ' exceeds the no-receipt limit of AED ' || (v_no_receipt_limit / 100)::text || '. A receipt is mandatory.'
        );
    END IF;

    SELECT line_manager_id INTO v_first_approver_id FROM employees WHERE id = v_claim.employee_id;
    IF v_first_approver_id IS NULL THEN
        SELECT hod_id INTO v_first_approver_id FROM employees WHERE id = v_claim.employee_id;
        v_next_status := 'HOD_REVIEW';
    ELSE
        v_next_status := 'LINE_MANAGER_REVIEW';
    END IF;

    IF v_first_approver_id = auth.uid() THEN
        SELECT hod_id INTO v_first_approver_id FROM employees WHERE id = v_claim.employee_id;
        v_next_status := 'HOD_REVIEW';
    END IF;

    UPDATE expenses
    SET is_locked = true
    WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id AND released_at IS NULL);

    UPDATE expense_claims
    SET status = v_next_status,
        validation_status = 'PASSED',
        validation_notes = 'Deterministic policy and receipt validations passed on submission.',
        submitted_at = now(),
        updated_at = now()
    WHERE id = p_claim_id;

    INSERT INTO approval_instances (
        claim_id, current_step_order, current_approver_id, current_approver_role, status, started_at
    ) VALUES (
        p_claim_id, 1, v_first_approver_id,
        (CASE WHEN v_next_status = 'LINE_MANAGER_REVIEW' THEN 'LINE_MANAGER' ELSE 'DEPARTMENT_MANAGER' END)::app_role,
        'IN_PROGRESS', now()
    ) RETURNING id INTO v_instance_id;

    RETURN jsonb_build_object(
        'success', true,
        'code', 'CLAIM_SUBMITTED',
        'message', 'Claim successfully submitted for approval.',
        'status', v_next_status
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION create_and_submit_claim(
    p_idempotency_key UUID,
    p_title TEXT,
    p_purpose TEXT,
    p_expense_ids UUID[],
    p_cash_advance_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_claim RECORD;
    v_claim_id UUID;
    v_count INT;
    v_owned INT;
    v_submit JSONB;
    v_code TEXT;
    v_detail TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_AUTHENTICATED', 'message', 'Your session has expired. Please sign in again.');
    END IF;
    IF p_idempotency_key IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REQUIRED', 'message', 'Request is missing an idempotency key.');
    END IF;

    SELECT id, claim_number, status, validation_status, total_expense_minor, advance_applied_minor, net_reimbursement_minor
    INTO v_claim FROM expense_claims WHERE employee_id = v_uid AND idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object('success', true, 'code', 'CLAIM_ALREADY_SUBMITTED', 'replayed', true,
            'claim_id', v_claim.id, 'claim_number', v_claim.claim_number, 'status', v_claim.status,
            'validation_status', v_claim.validation_status,
            'total_expense_minor', v_claim.total_expense_minor, 'advance_applied_minor', v_claim.advance_applied_minor,
            'net_reimbursement_minor', v_claim.net_reimbursement_minor,
            'message', 'Claim was already submitted.');
    END IF;

    BEGIN
        IF p_title IS NULL OR length(trim(p_title)) = 0 OR p_purpose IS NULL OR length(trim(p_purpose)) = 0 THEN
            RAISE EXCEPTION USING MESSAGE = 'REQUIRED_FIELD', DETAIL = 'Claim title and business purpose are required.';
        END IF;

        v_count := COALESCE(cardinality(p_expense_ids), 0);
        IF v_count = 0 THEN
            RAISE EXCEPTION USING MESSAGE = 'EMPTY_CLAIM', DETAIL = 'Select at least one expense to include in this claim.';
        END IF;
        IF (SELECT COUNT(DISTINCT x) FROM unnest(p_expense_ids) AS x) <> v_count THEN
            RAISE EXCEPTION USING MESSAGE = 'DUPLICATE_EXPENSE', DETAIL = 'The same expense was selected more than once.';
        END IF;

        PERFORM 1 FROM expenses WHERE id = ANY(p_expense_ids) AND employee_id = v_uid FOR UPDATE;
        SELECT COUNT(*) INTO v_owned FROM expenses WHERE id = ANY(p_expense_ids) AND employee_id = v_uid;
        IF v_owned <> v_count THEN
            RAISE EXCEPTION USING MESSAGE = 'EXPENSE_NOT_FOUND', DETAIL = 'One or more selected expenses could not be found in your account.';
        END IF;
        IF EXISTS (SELECT 1 FROM expenses WHERE id = ANY(p_expense_ids) AND is_locked = true) THEN
            RAISE EXCEPTION USING MESSAGE = 'EXPENSE_LOCKED', DETAIL = 'One or more selected expenses are already under review.';
        END IF;
        IF EXISTS (SELECT 1 FROM claim_expenses WHERE expense_id = ANY(p_expense_ids) AND released_at IS NULL) THEN
            RAISE EXCEPTION USING MESSAGE = 'EXPENSE_ALREADY_CLAIMED', DETAIL = 'One or more selected expenses are already included in another claim.';
        END IF;

        IF p_cash_advance_id IS NOT NULL THEN
            PERFORM 1 FROM cash_advances
            WHERE id = p_cash_advance_id AND employee_id = v_uid AND status IN ('PAID', 'PARTIALLY_SETTLED')
            FOR UPDATE;
            IF NOT FOUND THEN
                RAISE EXCEPTION USING MESSAGE = 'ADVANCE_INVALID', DETAIL = 'The selected cash advance is not available for reconciliation.';
            END IF;
        END IF;

        INSERT INTO expense_claims (claim_number, employee_id, title, purpose, claim_date, cash_advance_id, idempotency_key)
        VALUES (
            'CLM-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('expense_claim_number_seq')::text, 6, '0'),
            v_uid, trim(p_title), trim(p_purpose), CURRENT_DATE, p_cash_advance_id, p_idempotency_key
        )
        ON CONFLICT (employee_id, idempotency_key) DO NOTHING
        RETURNING id INTO v_claim_id;

        IF v_claim_id IS NULL THEN
            SELECT id, claim_number, status, validation_status, total_expense_minor, advance_applied_minor, net_reimbursement_minor
            INTO v_claim FROM expense_claims WHERE employee_id = v_uid AND idempotency_key = p_idempotency_key;
            RETURN jsonb_build_object('success', true, 'code', 'CLAIM_ALREADY_SUBMITTED', 'replayed', true,
                'claim_id', v_claim.id, 'claim_number', v_claim.claim_number, 'status', v_claim.status,
                'validation_status', v_claim.validation_status,
                'total_expense_minor', v_claim.total_expense_minor, 'advance_applied_minor', v_claim.advance_applied_minor,
                'net_reimbursement_minor', v_claim.net_reimbursement_minor,
                'message', 'Claim was already submitted.');
        END IF;

        INSERT INTO claim_expenses (claim_id, expense_id)
        SELECT v_claim_id, x FROM unnest(p_expense_ids) AS x;

        v_submit := submit_claim_for_approval(v_claim_id);
        IF NOT COALESCE((v_submit->>'success')::BOOLEAN, false) THEN
            RAISE EXCEPTION USING MESSAGE = COALESCE(v_submit->>'code', 'SUBMISSION_FAILED'),
                DETAIL = COALESCE(v_submit->>'message', 'Claim failed validation.');
        END IF;

        SELECT id, claim_number, status, validation_status, total_expense_minor, advance_applied_minor, net_reimbursement_minor
        INTO v_claim FROM expense_claims WHERE id = v_claim_id;

        RETURN jsonb_build_object('success', true, 'code', 'CLAIM_SUBMITTED', 'replayed', false,
            'claim_id', v_claim.id, 'claim_number', v_claim.claim_number, 'status', v_claim.status,
            'validation_status', v_claim.validation_status,
            'total_expense_minor', v_claim.total_expense_minor, 'advance_applied_minor', v_claim.advance_applied_minor,
            'net_reimbursement_minor', v_claim.net_reimbursement_minor,
            'message', 'Claim submitted for approval.');
    EXCEPTION
        WHEN raise_exception THEN
            GET STACKED DIAGNOSTICS v_code = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
            RETURN claim_failure_response(v_code, v_detail);
        WHEN unique_violation THEN
            RETURN jsonb_build_object('success', false, 'code', 'EXPENSE_ALREADY_CLAIMED', 'message', 'One or more selected expenses are already included in another claim.');
    END;
END;
$$;

-- ----------------------------------------------------------------------------
-- 5. CORRECTION + RESUBMISSION
-- p_expense_ids is the complete corrected expense set; p_cash_advance_id the
-- advance to apply (NULL = none). Removed expenses are released (history
-- kept), new ones attached, totals / receipts / policy / advance revalidated,
-- and the claim re-enters the approval workflow - all in one transaction.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION resubmit_corrected_claim(
    p_claim_id UUID,
    p_idempotency_key UUID,
    p_expense_ids UUID[],
    p_cash_advance_id UUID DEFAULT NULL,
    p_title TEXT DEFAULT NULL,
    p_purpose TEXT DEFAULT NULL,
    p_comments TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_claim RECORD;
    v_count INT;
    v_owned INT;
    v_before JSONB;
    v_submit JSONB;
    v_code TEXT;
    v_detail TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_AUTHENTICATED', 'message', 'Your session has expired. Please sign in again.');
    END IF;
    IF p_idempotency_key IS NULL OR p_claim_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'REQUIRED_FIELD', 'message', 'Request is missing the claim or idempotency key.');
    END IF;

    IF EXISTS (
        SELECT 1 FROM audit_logs
        WHERE action = 'CLAIM_RESUBMITTED' AND entity_id = p_claim_id AND actor_user_id = v_uid
          AND new_values->>'idempotency_key' = p_idempotency_key::text
    ) THEN
        SELECT id, claim_number, status, total_expense_minor, advance_applied_minor, net_reimbursement_minor
        INTO v_claim FROM expense_claims WHERE id = p_claim_id;
        RETURN jsonb_build_object('success', true, 'code', 'CLAIM_ALREADY_RESUBMITTED', 'replayed', true,
            'claim_id', v_claim.id, 'claim_number', v_claim.claim_number, 'status', v_claim.status,
            'total_expense_minor', v_claim.total_expense_minor, 'advance_applied_minor', v_claim.advance_applied_minor,
            'net_reimbursement_minor', v_claim.net_reimbursement_minor,
            'message', 'Claim was already resubmitted.');
    END IF;

    BEGIN
        SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
        IF NOT FOUND OR v_claim.employee_id <> v_uid THEN
            RAISE EXCEPTION USING MESSAGE = 'CLAIM_NOT_FOUND', DETAIL = 'Claim not found.';
        END IF;
        IF v_claim.status <> 'CORRECTION_REQUIRED' THEN
            RAISE EXCEPTION USING MESSAGE = 'INVALID_STATE', DETAIL = 'Only claims returned for correction can be corrected and resubmitted.';
        END IF;

        v_count := COALESCE(cardinality(p_expense_ids), 0);
        IF v_count = 0 THEN
            RAISE EXCEPTION USING MESSAGE = 'EMPTY_CLAIM', DETAIL = 'A claim must contain at least one expense.';
        END IF;
        IF (SELECT COUNT(DISTINCT x) FROM unnest(p_expense_ids) AS x) <> v_count THEN
            RAISE EXCEPTION USING MESSAGE = 'DUPLICATE_EXPENSE', DETAIL = 'The same expense was selected more than once.';
        END IF;

        PERFORM 1 FROM expenses WHERE id = ANY(p_expense_ids) AND employee_id = v_uid FOR UPDATE;
        SELECT COUNT(*) INTO v_owned FROM expenses WHERE id = ANY(p_expense_ids) AND employee_id = v_uid;
        IF v_owned <> v_count THEN
            RAISE EXCEPTION USING MESSAGE = 'EXPENSE_NOT_FOUND', DETAIL = 'One or more selected expenses could not be found in your account.';
        END IF;
        IF EXISTS (SELECT 1 FROM expenses WHERE id = ANY(p_expense_ids) AND is_locked = true) THEN
            RAISE EXCEPTION USING MESSAGE = 'EXPENSE_LOCKED', DETAIL = 'One or more selected expenses are already under review in another claim.';
        END IF;
        IF EXISTS (
            SELECT 1 FROM claim_expenses
            WHERE expense_id = ANY(p_expense_ids) AND released_at IS NULL AND claim_id <> p_claim_id
        ) THEN
            RAISE EXCEPTION USING MESSAGE = 'EXPENSE_ALREADY_CLAIMED', DETAIL = 'One or more selected expenses are already included in another claim.';
        END IF;

        IF p_cash_advance_id IS NOT NULL THEN
            PERFORM 1 FROM cash_advances
            WHERE id = p_cash_advance_id AND employee_id = v_uid AND status IN ('PAID', 'PARTIALLY_SETTLED')
            FOR UPDATE;
            IF NOT FOUND THEN
                RAISE EXCEPTION USING MESSAGE = 'ADVANCE_INVALID', DETAIL = 'The selected cash advance is not available for reconciliation.';
            END IF;
        END IF;

        v_before := jsonb_build_object(
            'expense_ids', (SELECT COALESCE(jsonb_agg(expense_id ORDER BY added_at), '[]'::jsonb)
                            FROM claim_expenses WHERE claim_id = p_claim_id AND released_at IS NULL),
            'cash_advance_id', v_claim.cash_advance_id,
            'total_expense_minor', v_claim.total_expense_minor,
            'advance_applied_minor', v_claim.advance_applied_minor,
            'net_reimbursement_minor', v_claim.net_reimbursement_minor,
            'correction_reason', v_claim.validation_notes
        );

        UPDATE claim_expenses SET released_at = now(), release_reason = 'REMOVED_IN_CORRECTION'
        WHERE claim_id = p_claim_id AND released_at IS NULL AND NOT (expense_id = ANY(p_expense_ids));

        UPDATE claim_expenses SET released_at = NULL, release_reason = NULL
        WHERE claim_id = p_claim_id AND released_at IS NOT NULL AND expense_id = ANY(p_expense_ids);

        INSERT INTO claim_expenses (claim_id, expense_id)
        SELECT p_claim_id, x FROM unnest(p_expense_ids) AS x
        WHERE NOT EXISTS (SELECT 1 FROM claim_expenses ce WHERE ce.claim_id = p_claim_id AND ce.expense_id = x);

        UPDATE expense_claims
        SET cash_advance_id = p_cash_advance_id,
            title = COALESCE(NULLIF(trim(COALESCE(p_title, '')), ''), title),
            purpose = COALESCE(NULLIF(trim(COALESCE(p_purpose, '')), ''), purpose),
            updated_at = now()
        WHERE id = p_claim_id;

        v_submit := submit_claim_for_approval(p_claim_id);
        IF NOT COALESCE((v_submit->>'success')::BOOLEAN, false) THEN
            RAISE EXCEPTION USING MESSAGE = COALESCE(v_submit->>'code', 'SUBMISSION_FAILED'),
                DETAIL = COALESCE(v_submit->>'message', 'Claim failed validation.');
        END IF;

        SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id;

        PERFORM record_audit_log('CLAIM_RESUBMITTED', 'expense_claims', p_claim_id, v_before, jsonb_build_object(
            'idempotency_key', p_idempotency_key,
            'expense_ids', to_jsonb(p_expense_ids),
            'cash_advance_id', v_claim.cash_advance_id,
            'total_expense_minor', v_claim.total_expense_minor,
            'advance_applied_minor', v_claim.advance_applied_minor,
            'net_reimbursement_minor', v_claim.net_reimbursement_minor,
            'status', v_claim.status,
            'comments', NULLIF(trim(COALESCE(p_comments, '')), '')
        ));

        RETURN jsonb_build_object('success', true, 'code', 'CLAIM_RESUBMITTED', 'replayed', false,
            'claim_id', v_claim.id, 'claim_number', v_claim.claim_number, 'status', v_claim.status,
            'total_expense_minor', v_claim.total_expense_minor, 'advance_applied_minor', v_claim.advance_applied_minor,
            'net_reimbursement_minor', v_claim.net_reimbursement_minor,
            'message', 'Corrected claim resubmitted for approval.');
    EXCEPTION
        WHEN raise_exception THEN
            GET STACKED DIAGNOSTICS v_code = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
            RETURN claim_failure_response(v_code, v_detail);
        WHEN unique_violation THEN
            RETURN jsonb_build_object('success', false, 'code', 'EXPENSE_ALREADY_CLAIMED', 'message', 'One or more selected expenses are already included in another claim.');
    END;
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. REIMBURSEMENT PAYMENT
-- Schema: reimbursements has no paid_at; the payment record (payments) holds
-- payment_date and created_at (paid timestamp). The paid amount is always the
-- server-computed claim net reimbursement. Rejected attempts are audited.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_reimbursement_payment(
    p_reimbursement_id UUID,
    p_idempotency_key VARCHAR,
    p_payment_reference VARCHAR,
    p_payment_method VARCHAR DEFAULT 'BANK_TRANSFER',
    p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_reimb RECORD;
    v_claim RECORD;
    v_payment RECORD;
    v_payment_id UUID;
    v_paid_at TIMESTAMPTZ;
    v_amount BIGINT;
    v_code TEXT;
    v_message TEXT;
BEGIN
    IF p_reimbursement_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Reimbursement not found.');
    END IF;

    IF v_uid IS NULL OR NOT (has_role('FINANCE') OR has_role('ADMIN')) THEN
        v_code := 'FORBIDDEN'; v_message := 'Only Finance can record reimbursement payments.';
    ELSIF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0
          OR p_payment_reference IS NULL OR length(trim(p_payment_reference)) = 0 THEN
        v_code := 'REQUIRED_FIELD'; v_message := 'Payment reference is required.';
    END IF;

    IF v_code IS NULL THEN
        SELECT * INTO v_reimb FROM reimbursements WHERE id = p_reimbursement_id FOR UPDATE;
        IF NOT FOUND THEN
            v_code := 'NOT_FOUND'; v_message := 'Reimbursement not found.';
        END IF;
    END IF;

    IF v_code IS NULL THEN
        SELECT * INTO v_payment FROM payments WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            IF v_payment.reimbursement_id = p_reimbursement_id THEN
                RETURN jsonb_build_object('success', true, 'code', 'IDEMPOTENT_SUCCESS', 'replayed', true,
                    'payment_id', v_payment.id, 'paid_amount_minor', v_payment.paid_amount_minor,
                    'paid_at', v_payment.created_at, 'payment_date', v_payment.payment_date,
                    'message', 'Payment was already recorded.');
            END IF;
            v_code := 'IDEMPOTENCY_KEY_CONFLICT'; v_message := 'This request key was already used for a different payment.';
        END IF;
    END IF;

    IF v_code IS NULL THEN
        SELECT * INTO v_claim FROM expense_claims WHERE id = v_reimb.claim_id FOR UPDATE;
        IF v_reimb.status = 'PAID' THEN
            v_code := 'ALREADY_PAID'; v_message := 'This reimbursement has already been paid.';
        ELSIF v_reimb.status NOT IN ('PENDING', 'PROCESSING') THEN
            v_code := 'INVALID_STATE'; v_message := 'This reimbursement is not awaiting payment.';
        ELSIF v_claim.status NOT IN ('APPROVED', 'REIMBURSEMENT_PROCESSING') THEN
            v_code := 'CLAIM_NOT_ELIGIBLE'; v_message := 'Only fully approved claims can be paid.';
        ELSIF v_claim.employee_id = v_uid THEN
            v_code := 'SELF_PAYMENT_FORBIDDEN'; v_message := 'You cannot record payment for your own claim.';
        ELSIF v_claim.net_reimbursement_minor <= 0
              OR v_reimb.amount_minor <> v_claim.net_reimbursement_minor
              OR v_reimb.aed_amount_minor <> v_claim.net_reimbursement_minor
              OR v_reimb.employee_id <> v_claim.employee_id THEN
            v_code := 'AMOUNT_MISMATCH'; v_message := 'Reimbursement amount does not match the approved claim. Contact the system administrator.';
        ELSIF EXISTS (SELECT 1 FROM payments WHERE payment_reference = trim(p_payment_reference)) THEN
            v_code := 'DUPLICATE_REFERENCE'; v_message := 'This payment reference has already been used.';
        END IF;
    END IF;

    IF v_code IS NOT NULL THEN
        PERFORM record_audit_log('PAYMENT_REJECTED', 'reimbursements', p_reimbursement_id, NULL,
            jsonb_build_object('code', v_code, 'payment_reference', p_payment_reference, 'idempotency_key', p_idempotency_key));
        RETURN jsonb_build_object('success', false, 'code', v_code, 'message', v_message,
            'payment_id', CASE WHEN v_code = 'ALREADY_PAID'
                THEN (SELECT id FROM payments WHERE reimbursement_id = p_reimbursement_id ORDER BY created_at DESC LIMIT 1) END);
    END IF;

    v_amount := v_claim.net_reimbursement_minor;

    INSERT INTO payments (
        reimbursement_id, payment_reference, idempotency_key, payment_method,
        paid_amount_minor, payment_date, recorded_by, notes
    ) VALUES (
        p_reimbursement_id, trim(p_payment_reference), p_idempotency_key, COALESCE(NULLIF(trim(p_payment_method), ''), 'BANK_TRANSFER'),
        v_amount, CURRENT_DATE, v_uid, p_notes
    ) RETURNING id, created_at INTO v_payment_id, v_paid_at;

    UPDATE reimbursements SET status = 'PAID', processed_by = v_uid, updated_at = v_paid_at
    WHERE id = p_reimbursement_id;

    UPDATE expense_claims SET status = 'PAID', updated_at = v_paid_at
    WHERE id = v_claim.id;

    INSERT INTO notifications (recipient_id, title, body, event_type, entity_type, entity_id)
    VALUES (v_claim.employee_id, 'Reimbursement Paid',
        'Reimbursement of AED ' || to_char(v_amount / 100.0, 'FM999,999,990.00') || ' for claim #' || v_claim.claim_number
            || ' has been paid. Ref: ' || trim(p_payment_reference),
        'PAYMENT_COMPLETED', 'reimbursement', p_reimbursement_id);

    RETURN jsonb_build_object('success', true, 'code', 'PAYMENT_RECORDED', 'replayed', false,
        'payment_id', v_payment_id, 'paid_amount_minor', v_amount,
        'paid_at', v_paid_at, 'payment_date', CURRENT_DATE,
        'message', 'Payment recorded.');
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_reimbursements ON reimbursements;
CREATE TRIGGER trg_audit_reimbursements
AFTER INSERT OR UPDATE ON reimbursements
FOR EACH ROW EXECUTE FUNCTION audit_entity_change_trigger();

-- ----------------------------------------------------------------------------
-- 7. PRIVILEGES
-- ----------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE ON reimbursements FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON payments FROM anon, authenticated;
REVOKE UPDATE, DELETE ON claim_expenses FROM anon, authenticated;

-- Submission is only reachable through create_and_submit_claim / resubmit_corrected_claim.
REVOKE ALL ON FUNCTION submit_claim_for_approval(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION recalculate_claim_totals(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION record_audit_log(VARCHAR, VARCHAR, UUID, JSONB, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION claim_failure_response(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION guard_claim_expense_link_trigger() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION keep_claimed_expense_locked_trigger() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION enforce_claim_status_transition_trigger() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION claim_lifecycle_effects_trigger() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION resubmit_corrected_claim(UUID, UUID, UUID[], UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION resubmit_corrected_claim(UUID, UUID, UUID[], UUID, TEXT, TEXT, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION record_reimbursement_payment(UUID, VARCHAR, VARCHAR, VARCHAR, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION record_reimbursement_payment(UUID, VARCHAR, VARCHAR, VARCHAR, TEXT) TO authenticated;
