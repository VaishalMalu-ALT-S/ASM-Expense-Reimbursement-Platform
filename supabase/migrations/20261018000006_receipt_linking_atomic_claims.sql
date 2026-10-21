-- ============================================================================
-- ASM Expense & Reimbursement Platform - Receipt Linking & Atomic Claim Flow
-- Migration: 20261018000006_receipt_linking_atomic_claims.sql
--
-- 1. Server-authoritative exchange rates and AED amounts on expenses
-- 2. Expense -> Receipt -> OCR result traceability (staged OCR, owner-checked)
-- 3. Atomic, idempotent RPCs: create_expense_with_receipt, create_and_submit_claim
-- 4. Receipt-total vs expense-breakup validation enforced on claim submission
-- 5. Trusted-function bypass for the 000005 client write-protection triggers
-- 6. Direct client INSERT/UPDATE/DELETE removed for records created by the RPCs
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. SCHEMA ADDITIONS
-- ----------------------------------------------------------------------------
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS idempotency_key UUID;
DO $$ BEGIN
    ALTER TABLE expenses ADD CONSTRAINT uq_expenses_employee_idempotency UNIQUE (employee_id, idempotency_key);
EXCEPTION WHEN duplicate_object OR duplicate_table THEN NULL; END $$;

ALTER TABLE expense_claims ADD COLUMN IF NOT EXISTS idempotency_key UUID;
DO $$ BEGIN
    ALTER TABLE expense_claims ADD CONSTRAINT uq_claims_employee_idempotency UNIQUE (employee_id, idempotency_key);
EXCEPTION WHEN duplicate_object OR duplicate_table THEN NULL; END $$;

-- Employee-verified receipt total, in the receipt's own currency (minor units)
ALTER TABLE expense_receipts ADD COLUMN IF NOT EXISTS receipt_total_minor BIGINT CHECK (receipt_total_minor > 0);
ALTER TABLE expense_receipts ADD COLUMN IF NOT EXISTS currency_code CHAR(3) REFERENCES currencies(code);
CREATE UNIQUE INDEX IF NOT EXISTS uq_expense_receipts_storage_path ON expense_receipts(storage_path);
CREATE INDEX IF NOT EXISTS idx_expense_receipts_expense ON expense_receipts(expense_id);

-- OCR runs before the expense exists, so results are staged against the
-- uploading employee + storage path and linked when the expense is created.
ALTER TABLE expense_ocr_results ALTER COLUMN expense_id DROP NOT NULL;
ALTER TABLE expense_ocr_results ADD COLUMN IF NOT EXISTS employee_id UUID REFERENCES employees(id) ON DELETE CASCADE;
ALTER TABLE expense_ocr_results ADD COLUMN IF NOT EXISTS storage_path VARCHAR(500);
ALTER TABLE expense_ocr_results ADD COLUMN IF NOT EXISTS ocr_status VARCHAR(20);
ALTER TABLE expense_ocr_results ADD COLUMN IF NOT EXISTS missing_fields TEXT[] NOT NULL DEFAULT '{}';
DO $$ BEGIN
    ALTER TABLE expense_ocr_results ADD CONSTRAINT chk_ocr_status CHECK (ocr_status IN ('SUCCESS', 'PARTIAL', 'FAILED'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_ocr_results_staging ON expense_ocr_results(employee_id, storage_path);
CREATE INDEX IF NOT EXISTS idx_ocr_results_receipt ON expense_ocr_results(receipt_id);
CREATE INDEX IF NOT EXISTS idx_ocr_results_expense ON expense_ocr_results(expense_id);

CREATE SEQUENCE IF NOT EXISTS expense_claim_number_seq;

-- ----------------------------------------------------------------------------
-- 2. AUTHORITATIVE EXCHANGE RATES
-- Rate in effect on the expense date; if the date precedes every configured
-- rate, the earliest configured rate is used. Finance owns exchange_rates.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_aed_exchange_rate(p_currency CHAR(3), p_on_date DATE)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_currency = 'AED' THEN
        RETURN 1;
    END IF;

    SELECT rate INTO v_rate FROM exchange_rates
    WHERE from_currency = p_currency AND to_currency = 'AED' AND effective_date <= p_on_date
    ORDER BY effective_date DESC LIMIT 1;

    IF v_rate IS NULL THEN
        SELECT rate INTO v_rate FROM exchange_rates
        WHERE from_currency = p_currency AND to_currency = 'AED'
        ORDER BY effective_date ASC LIMIT 1;
    END IF;

    RETURN v_rate;
END;
$$;

-- Fires before trg_protect_expense_modifications (alphabetical order), so the
-- 000005 trigger recomputes the AED amount from the authoritative rate.
CREATE OR REPLACE FUNCTION enforce_expense_fx_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF TG_OP = 'INSERT'
       OR NEW.amount_minor IS DISTINCT FROM OLD.amount_minor
       OR NEW.currency_code IS DISTINCT FROM OLD.currency_code
       OR NEW.expense_date IS DISTINCT FROM OLD.expense_date
       OR NEW.exchange_rate IS DISTINCT FROM OLD.exchange_rate
       OR NEW.aed_amount_minor IS DISTINCT FROM OLD.aed_amount_minor THEN
        v_rate := get_aed_exchange_rate(NEW.currency_code, NEW.expense_date);
        IF v_rate IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'FX_RATE_UNAVAILABLE',
                DETAIL = 'No exchange rate to AED is configured for ' || NEW.currency_code || '. Please contact Finance.';
        END IF;
        NEW.exchange_rate := v_rate;
        NEW.aed_amount_minor := ROUND(NEW.amount_minor * v_rate)::BIGINT;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_expense_fx ON expenses;
CREATE TRIGGER trg_enforce_expense_fx
BEFORE INSERT OR UPDATE ON expenses
FOR EACH ROW EXECUTE FUNCTION enforce_expense_fx_trigger();

-- ----------------------------------------------------------------------------
-- 3. TRUSTED-FUNCTION BYPASS FOR 000005 WRITE-PROTECTION TRIGGERS
-- The 000005 versions keyed on request.jwt.claims, which is also set inside
-- SECURITY DEFINER workflow functions, so submit/approve were blocked by their
-- own protections. As SECURITY INVOKER functions, current_user is the client
-- role only for direct client statements; trusted definer functions run as
-- their owner and are not blocked.
-- ----------------------------------------------------------------------------
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
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION protect_expense_modifications_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp
AS $$
BEGIN
    IF current_user IN ('authenticated', 'anon') AND NOT has_role('ADMIN') THEN
        IF OLD.is_locked = true THEN
            RAISE EXCEPTION 'Security Violation: This expense is locked in a submitted claim and cannot be modified.';
        END IF;
        IF NEW.is_locked IS DISTINCT FROM OLD.is_locked AND NEW.is_locked = false THEN
            RAISE EXCEPTION 'Security Violation: Clients cannot unlock expenses directly.';
        END IF;
        IF NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key THEN
            RAISE EXCEPTION 'Security Violation: Idempotency key is server-controlled.';
        END IF;
    END IF;
    IF NEW.exchange_rate > 0 THEN
        NEW.aed_amount_minor := ROUND(NEW.amount_minor * NEW.exchange_rate);
    END IF;
    RETURN NEW;
END;
$$;

-- 000003 passed TG_TABLE_NAME (type name) to record_audit_log(VARCHAR, ...);
-- name has no implicit cast to varchar, so every audited INSERT/UPDATE/DELETE
-- on expenses, expense_claims, cash_advances and payments raised an error.
CREATE OR REPLACE FUNCTION audit_entity_change_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        PERFORM record_audit_log((TG_TABLE_NAME || '_CREATED')::varchar, TG_TABLE_NAME::varchar, NEW.id, NULL, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        PERFORM record_audit_log((TG_TABLE_NAME || '_UPDATED')::varchar, TG_TABLE_NAME::varchar, NEW.id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        PERFORM record_audit_log((TG_TABLE_NAME || '_DELETED')::varchar, TG_TABLE_NAME::varchar, OLD.id, to_jsonb(OLD), NULL);
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

-- 000005 inserted a text CASE expression ('LINE_MANAGER' / 'HOD') into the
-- app_role column approval_instances.current_approver_role; 'HOD' is not an
-- app_role value and text has no implicit cast to the enum, so every valid
-- submission raised an error. Logic is otherwise unchanged from 000005, plus a
-- row lock so concurrent submissions of the same claim are serialized.
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
    WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id);

    UPDATE expense_claims
    SET status = v_next_status,
        validation_status = 'PASSED',
        validation_notes = 'Deterministic policy and receipt validations passed on submission.',
        submitted_at = now(),
        updated_at = now()
    WHERE id = p_claim_id;

    INSERT INTO approval_instances (
        claim_id,
        current_step_order,
        current_approver_id,
        current_approver_role,
        status,
        started_at
    ) VALUES (
        p_claim_id,
        1,
        v_first_approver_id,
        (CASE WHEN v_next_status = 'LINE_MANAGER_REVIEW' THEN 'LINE_MANAGER' ELSE 'DEPARTMENT_MANAGER' END)::app_role,
        'IN_PROGRESS',
        now()
    ) RETURNING id INTO v_instance_id;

    RETURN jsonb_build_object(
        'success', true,
        'code', 'CLAIM_SUBMITTED',
        'message', 'Claim successfully submitted for approval.',
        'status', v_next_status
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ----------------------------------------------------------------------------
-- 4. RECEIPT TOTAL VALIDATION
-- Every claimed expense marked as receipted must have at least one receipt
-- whose employee-verified totals (same currency) equal the claimed amount,
-- within the configured receipt_tolerance_aed (seeded as 0 = exact match).
-- No-receipt expenses are governed by no_receipt_limit_aed on submission.
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
        WHERE ce.claim_id = p_claim_id AND e.has_receipt = true
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
               'expense_id', id,
               'vendor', vendor,
               'reason', reason,
               'expense_aed_minor', aed_amount_minor,
               'receipt_aed_minor', receipt_aed_minor
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

-- Enforced on every path that moves a claim out of DRAFT/CORRECTION_REQUIRED.
CREATE OR REPLACE FUNCTION validate_claim_receipts_on_submit_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_eval JSONB;
BEGIN
    IF OLD.status IN ('DRAFT', 'CORRECTION_REQUIRED')
       AND NEW.status NOT IN ('DRAFT', 'CORRECTION_REQUIRED', 'CANCELLED') THEN
        v_eval := evaluate_claim_receipts(NEW.id);
        IF NOT (v_eval->>'valid')::BOOLEAN THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'RECEIPT_TOTAL_MISMATCH', DETAIL = v_eval::text;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_claim_receipts ON expense_claims;
CREATE TRIGGER trg_validate_claim_receipts
BEFORE UPDATE OF status ON expense_claims
FOR EACH ROW EXECUTE FUNCTION validate_claim_receipts_on_submit_trigger();

-- ----------------------------------------------------------------------------
-- 5. ATOMIC EXPENSE + RECEIPT + OCR LINK
-- Business-rule failures are raised inside an exception block so every write
-- in the call is rolled back, then returned as a structured JSON error.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_expense_with_receipt(
    p_idempotency_key UUID,
    p_category_id UUID,
    p_amount_minor BIGINT,
    p_currency_code TEXT,
    p_expense_date DATE,
    p_vendor TEXT,
    p_description TEXT,
    p_invoice_number TEXT DEFAULT NULL,
    p_tax_amount_minor BIGINT DEFAULT 0,
    p_no_receipt_reason TEXT DEFAULT NULL,
    p_receipt_storage_path TEXT DEFAULT NULL,
    p_receipt_file_name TEXT DEFAULT NULL,
    p_receipt_total_minor BIGINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_expense RECORD;
    v_expense_id UUID;
    v_receipt_id UUID;
    v_has_receipt BOOLEAN := p_receipt_storage_path IS NOT NULL;
    v_rate NUMERIC;
    v_aed BIGINT;
    v_no_receipt_limit BIGINT;
    v_object RECORD;
    v_size BIGINT;
    v_mime TEXT;
    v_code TEXT;
    v_detail TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_AUTHENTICATED', 'message', 'Your session has expired. Please sign in again.');
    END IF;
    IF p_idempotency_key IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REQUIRED', 'message', 'Request is missing an idempotency key.');
    END IF;

    SELECT id, aed_amount_minor, exchange_rate, has_receipt INTO v_expense
    FROM expenses WHERE employee_id = v_uid AND idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object('success', true, 'code', 'EXPENSE_ALREADY_RECORDED', 'replayed', true,
            'expense_id', v_expense.id, 'aed_amount_minor', v_expense.aed_amount_minor,
            'exchange_rate', v_expense.exchange_rate, 'has_receipt', v_expense.has_receipt,
            'message', 'Expense was already recorded.');
    END IF;

    BEGIN
        IF NOT EXISTS (SELECT 1 FROM employees WHERE id = v_uid AND is_active = true) THEN
            RAISE EXCEPTION USING MESSAGE = 'EMPLOYEE_INACTIVE', DETAIL = 'Your employee profile is not active.';
        END IF;
        IF p_amount_minor IS NULL OR p_amount_minor <= 0 THEN
            RAISE EXCEPTION USING MESSAGE = 'AMOUNT_INVALID', DETAIL = 'Expense amount must be greater than zero.';
        END IF;
        IF p_tax_amount_minor IS NULL OR p_tax_amount_minor < 0 OR p_tax_amount_minor > p_amount_minor THEN
            RAISE EXCEPTION USING MESSAGE = 'TAX_INVALID', DETAIL = 'Tax amount must be between zero and the expense amount.';
        END IF;
        IF p_expense_date IS NULL OR p_expense_date > CURRENT_DATE + 1 THEN
            RAISE EXCEPTION USING MESSAGE = 'DATE_INVALID', DETAIL = 'Expense date is missing or in the future.';
        END IF;
        IF p_vendor IS NULL OR length(trim(p_vendor)) = 0 THEN
            RAISE EXCEPTION USING MESSAGE = 'VENDOR_REQUIRED', DETAIL = 'Vendor name is required.';
        END IF;
        IF p_description IS NULL OR length(trim(p_description)) = 0 THEN
            RAISE EXCEPTION USING MESSAGE = 'DESCRIPTION_REQUIRED', DETAIL = 'Business purpose / description is required.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM expense_categories WHERE id = p_category_id AND is_active = true) THEN
            RAISE EXCEPTION USING MESSAGE = 'CATEGORY_INVALID', DETAIL = 'Selected expense category is not available.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM currencies WHERE code = p_currency_code AND is_active = true) THEN
            RAISE EXCEPTION USING MESSAGE = 'CURRENCY_INVALID', DETAIL = 'Currency ' || COALESCE(p_currency_code, '') || ' is not supported.';
        END IF;

        v_rate := get_aed_exchange_rate(p_currency_code::CHAR(3), p_expense_date);
        IF v_rate IS NULL THEN
            RAISE EXCEPTION USING MESSAGE = 'FX_RATE_UNAVAILABLE', DETAIL = 'No exchange rate to AED is configured for ' || p_currency_code || '. Please contact Finance.';
        END IF;
        v_aed := ROUND(p_amount_minor * v_rate)::BIGINT;

        IF v_has_receipt THEN
            IF split_part(p_receipt_storage_path, '/', 1) <> v_uid::text OR position('..' IN p_receipt_storage_path) > 0 THEN
                RAISE EXCEPTION USING MESSAGE = 'RECEIPT_NOT_OWNED', DETAIL = 'The receipt file does not belong to your account.';
            END IF;

            SELECT name, metadata INTO v_object FROM storage.objects
            WHERE bucket_id = 'receipts' AND name = p_receipt_storage_path;
            IF NOT FOUND THEN
                RAISE EXCEPTION USING MESSAGE = 'RECEIPT_FILE_NOT_FOUND', DETAIL = 'The receipt upload was not found. Please upload the receipt again.';
            END IF;

            v_size := NULLIF(v_object.metadata->>'size', '')::BIGINT;
            v_mime := lower(COALESCE(v_object.metadata->>'mimetype', ''));
            IF v_size IS NULL OR v_size <= 0 THEN
                RAISE EXCEPTION USING MESSAGE = 'RECEIPT_FILE_INVALID', DETAIL = 'The receipt file is empty or incomplete. Please upload it again.';
            END IF;
            IF v_mime NOT IN ('image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf') THEN
                RAISE EXCEPTION USING MESSAGE = 'RECEIPT_FILE_TYPE_INVALID', DETAIL = 'Receipt must be a JPEG, PNG, WEBP, HEIC image or a PDF.';
            END IF;

            IF EXISTS (SELECT 1 FROM expense_receipts WHERE storage_path = p_receipt_storage_path) THEN
                RAISE EXCEPTION USING MESSAGE = 'RECEIPT_ALREADY_LINKED', DETAIL = 'This receipt is already attached to another expense.';
            END IF;

            IF p_receipt_total_minor IS NULL OR p_receipt_total_minor <= 0 THEN
                RAISE EXCEPTION USING MESSAGE = 'RECEIPT_TOTAL_REQUIRED', DETAIL = 'Enter the total shown on the receipt.';
            END IF;
        ELSE
            IF p_no_receipt_reason IS NULL OR length(trim(p_no_receipt_reason)) = 0 THEN
                RAISE EXCEPTION USING MESSAGE = 'NO_RECEIPT_REASON_REQUIRED', DETAIL = 'A justification is required for expenses without a receipt.';
            END IF;

            SELECT (rule_value->>'limit_minor')::BIGINT INTO v_no_receipt_limit
            FROM policy_rules WHERE rule_key = 'no_receipt_limit_aed';
            v_no_receipt_limit := COALESCE(v_no_receipt_limit, 50000);
            IF v_aed > v_no_receipt_limit THEN
                RAISE EXCEPTION USING MESSAGE = 'RECEIPT_REQUIRED',
                    DETAIL = 'Expenses above AED ' || to_char(v_no_receipt_limit / 100.0, 'FM999,999,990.00') || ' require a receipt. Use Scan Receipt to attach it.';
            END IF;
        END IF;

        INSERT INTO expenses (
            employee_id, category_id, amount_minor, currency_code, exchange_rate, aed_amount_minor,
            expense_date, vendor, invoice_number, tax_amount_minor, description,
            has_receipt, no_receipt_reason, idempotency_key
        ) VALUES (
            v_uid, p_category_id, p_amount_minor, p_currency_code, v_rate, v_aed,
            p_expense_date, trim(p_vendor), NULLIF(trim(COALESCE(p_invoice_number, '')), ''), p_tax_amount_minor, trim(p_description),
            v_has_receipt, CASE WHEN v_has_receipt THEN NULL ELSE trim(p_no_receipt_reason) END, p_idempotency_key
        )
        ON CONFLICT (employee_id, idempotency_key) DO NOTHING
        RETURNING id INTO v_expense_id;

        IF v_expense_id IS NULL THEN
            SELECT id, aed_amount_minor, exchange_rate, has_receipt INTO v_expense
            FROM expenses WHERE employee_id = v_uid AND idempotency_key = p_idempotency_key;
            RETURN jsonb_build_object('success', true, 'code', 'EXPENSE_ALREADY_RECORDED', 'replayed', true,
                'expense_id', v_expense.id, 'aed_amount_minor', v_expense.aed_amount_minor,
                'exchange_rate', v_expense.exchange_rate, 'has_receipt', v_expense.has_receipt,
                'message', 'Expense was already recorded.');
        END IF;

        IF v_has_receipt THEN
            INSERT INTO expense_receipts (
                expense_id, storage_path, original_file_name, file_size_bytes, mime_type,
                uploaded_by, receipt_total_minor, currency_code
            ) VALUES (
                v_expense_id, p_receipt_storage_path,
                COALESCE(NULLIF(trim(COALESCE(p_receipt_file_name, '')), ''), split_part(p_receipt_storage_path, '/', -1)),
                v_size, v_mime, v_uid, p_receipt_total_minor, p_currency_code
            ) RETURNING id INTO v_receipt_id;

            UPDATE expense_ocr_results
            SET expense_id = v_expense_id, receipt_id = v_receipt_id, is_verified_by_user = true
            WHERE employee_id = v_uid AND storage_path = p_receipt_storage_path AND expense_id IS NULL;
        END IF;

        RETURN jsonb_build_object('success', true, 'code', 'EXPENSE_RECORDED', 'replayed', false,
            'expense_id', v_expense_id, 'receipt_id', v_receipt_id,
            'amount_minor', p_amount_minor, 'currency_code', p_currency_code,
            'exchange_rate', v_rate, 'aed_amount_minor', v_aed, 'has_receipt', v_has_receipt,
            'message', 'Expense recorded.');
    EXCEPTION
        WHEN raise_exception THEN
            GET STACKED DIAGNOSTICS v_code = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
            RETURN jsonb_build_object('success', false, 'code', v_code, 'message', COALESCE(NULLIF(v_detail, ''), 'Expense could not be saved.'));
        WHEN unique_violation THEN
            RETURN jsonb_build_object('success', false, 'code', 'RECEIPT_ALREADY_LINKED', 'message', 'This receipt is already attached to another expense.');
        WHEN check_violation OR foreign_key_violation OR not_null_violation THEN
            RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_FAILED', 'message', 'Expense details are incomplete or invalid. Please review and try again.');
    END;
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. ATOMIC CLAIM CREATION + SUBMISSION
-- Creates the claim, attaches expenses and runs submit_claim_for_approval in
-- one transaction. Any failure rolls back everything (no orphan drafts).
-- Retrying with the same idempotency key returns the original claim.
-- ----------------------------------------------------------------------------
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
    v_eval JSONB;
    v_vendors TEXT;
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
        IF EXISTS (SELECT 1 FROM claim_expenses WHERE expense_id = ANY(p_expense_ids)) THEN
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
            IF v_code = 'RECEIPT_TOTAL_MISMATCH' THEN
                v_eval := v_detail::jsonb;
                SELECT string_agg(DISTINCT m->>'vendor', ', ') INTO v_vendors
                FROM jsonb_array_elements(v_eval->'mismatches') AS m;
                RETURN jsonb_build_object('success', false, 'code', v_code,
                    'validation_status', 'CORRECTION_REQUIRED',
                    'breakup_total_minor', v_eval->'breakup_total_minor',
                    'receipt_total_minor', v_eval->'receipt_total_minor',
                    'mismatches', v_eval->'mismatches',
                    'message', 'Receipt totals do not match the claimed amounts for: ' || COALESCE(v_vendors, 'selected expenses')
                        || '. Correct these expenses or their receipts and submit again.');
            END IF;
            RETURN jsonb_build_object('success', false, 'code', v_code,
                'message', COALESCE(NULLIF(v_detail, ''), 'Claim could not be submitted.'));
        WHEN unique_violation THEN
            RETURN jsonb_build_object('success', false, 'code', 'EXPENSE_ALREADY_CLAIMED', 'message', 'One or more selected expenses are already included in another claim.');
    END;
END;
$$;

-- ----------------------------------------------------------------------------
-- 7. PRIVILEGES & RLS
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION get_aed_exchange_rate(CHAR, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION evaluate_claim_receipts(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION enforce_expense_fx_trigger() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION validate_claim_receipts_on_submit_trigger() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION create_expense_with_receipt(UUID, UUID, BIGINT, TEXT, DATE, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_expense_with_receipt(UUID, UUID, BIGINT, TEXT, DATE, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, BIGINT) TO authenticated;
REVOKE ALL ON FUNCTION create_and_submit_claim(UUID, TEXT, TEXT, UUID[], UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_and_submit_claim(UUID, TEXT, TEXT, UUID[], UUID) TO authenticated;

-- Records created by the RPCs above must not be written directly by clients.
REVOKE INSERT ON expenses FROM anon, authenticated;
REVOKE INSERT ON expense_claims FROM anon, authenticated;
REVOKE INSERT ON claim_expenses FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON expense_receipts FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON expense_ocr_results FROM anon, authenticated;

-- Replace the open OCR policy from FIX_EXPENSES_RLS_POLICIES.sql (USING true).
DROP POLICY IF EXISTS "Employees view expense ocr results" ON expense_ocr_results;
DROP POLICY IF EXISTS "Authorized view of OCR results" ON expense_ocr_results;
CREATE POLICY "Authorized view of OCR results" ON expense_ocr_results
FOR SELECT TO authenticated
USING (
    employee_id = auth.uid()
    OR EXISTS (
        SELECT 1 FROM expenses e
        WHERE e.id = expense_ocr_results.expense_id
          AND (e.employee_id = auth.uid()
               OR is_manager_of(e.employee_id)
               OR is_hod_of(e.employee_id)
               OR has_role('MANAGEMENT')
               OR has_role('FINANCE')
               OR has_role('ADMIN'))
    )
);
