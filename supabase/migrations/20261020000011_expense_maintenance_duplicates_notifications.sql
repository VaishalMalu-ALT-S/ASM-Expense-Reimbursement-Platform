-- ============================================================================
-- MIGRATION 0011: EXPENSE MAINTENANCE, DUPLICATE DETECTION, NOTIFICATIONS
-- Forward-only. Does not modify migrations 0001-0010.
--
-- 1. Duplicate detection (server-side, per employee):
--    a. Same vendor + same invoice number            -> DUPLICATE_INVOICE (blocked)
--    b. Same vendor + date + amount + currency, and the
--       invoice numbers do not prove they differ      -> POSSIBLE_DUPLICATE
--       (returned without writing; the employee may confirm and resubmit with
--       p_allow_possible_duplicate = true, which is recorded in the audit log)
-- 2. update_expense / delete_expense RPCs for the employee's own expenses that
--    are not locked in a claim under review. Direct client UPDATE/DELETE on
--    expenses is revoked so receipt totals, FX and audit stay consistent.
-- 3. In-app notifications generated on claim and cash advance workflow
--    transitions. Clients may only toggle is_read on their own rows.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. DUPLICATE DETECTION
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION normalize_vendor_key(p_vendor TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT lower(regexp_replace(trim(COALESCE(p_vendor, '')), '\s+', ' ', 'g'));
$$;

CREATE OR REPLACE FUNCTION normalize_invoice_key(p_invoice TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT NULLIF(upper(regexp_replace(COALESCE(p_invoice, ''), '[^A-Za-z0-9]', '', 'g')), '');
$$;

CREATE INDEX IF NOT EXISTS idx_expenses_duplicate_invoice
    ON expenses (employee_id, normalize_vendor_key(vendor), normalize_invoice_key(invoice_number))
    WHERE invoice_number IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_expenses_duplicate_amount
    ON expenses (employee_id, expense_date, amount_minor, currency_code);

-- Returns the first matching expense of the employee (excluding p_exclude_id)
-- and the kind of match: 'INVOICE' (hard) or 'POSSIBLE' (soft).
CREATE OR REPLACE FUNCTION find_duplicate_expense(
    p_employee_id UUID,
    p_exclude_id UUID,
    p_vendor TEXT,
    p_invoice_number TEXT,
    p_expense_date DATE,
    p_amount_minor BIGINT,
    p_currency_code TEXT
)
RETURNS TABLE (expense_id UUID, match_kind TEXT, expense_date DATE)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_vendor TEXT := normalize_vendor_key(p_vendor);
    v_invoice TEXT := normalize_invoice_key(p_invoice_number);
BEGIN
    IF v_invoice IS NOT NULL THEN
        RETURN QUERY
        SELECT e.id, 'INVOICE'::TEXT, e.expense_date
        FROM expenses e
        WHERE e.employee_id = p_employee_id
          AND (p_exclude_id IS NULL OR e.id <> p_exclude_id)
          AND e.invoice_number IS NOT NULL
          AND normalize_vendor_key(e.vendor) = v_vendor
          AND normalize_invoice_key(e.invoice_number) = v_invoice
        ORDER BY e.created_at
        LIMIT 1;
        IF FOUND THEN
            RETURN;
        END IF;
    END IF;

    RETURN QUERY
    SELECT e.id, 'POSSIBLE'::TEXT, e.expense_date
    FROM expenses e
    WHERE e.employee_id = p_employee_id
      AND (p_exclude_id IS NULL OR e.id <> p_exclude_id)
      AND e.expense_date = p_expense_date
      AND e.amount_minor = p_amount_minor
      AND e.currency_code = p_currency_code
      AND normalize_vendor_key(e.vendor) = v_vendor
      AND (v_invoice IS NULL OR e.invoice_number IS NULL
           OR normalize_invoice_key(e.invoice_number) = v_invoice)
    ORDER BY e.created_at
    LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION find_duplicate_expense(UUID, UUID, TEXT, TEXT, DATE, BIGINT, TEXT) FROM PUBLIC, anon, authenticated;

-- The signature gains p_allow_possible_duplicate; drop the old overload so
-- named-argument RPC calls stay unambiguous.
DROP FUNCTION IF EXISTS create_expense_with_receipt(UUID, UUID, BIGINT, TEXT, DATE, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, BIGINT);

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
    p_receipt_total_minor BIGINT DEFAULT NULL,
    p_allow_possible_duplicate BOOLEAN DEFAULT false
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
    v_dup RECORD;
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

        SELECT * INTO v_dup FROM find_duplicate_expense(v_uid, NULL, p_vendor, p_invoice_number,
            p_expense_date, p_amount_minor, p_currency_code);
        IF FOUND THEN
            IF v_dup.match_kind = 'INVOICE' THEN
                RETURN jsonb_build_object('success', false, 'code', 'DUPLICATE_INVOICE',
                    'duplicate_expense_id', v_dup.expense_id,
                    'message', 'Invoice ' || trim(p_invoice_number) || ' from ' || trim(p_vendor)
                        || ' is already recorded (expense dated ' || to_char(v_dup.expense_date, 'DD Mon YYYY') || ').');
            ELSIF NOT COALESCE(p_allow_possible_duplicate, false) THEN
                RETURN jsonb_build_object('success', false, 'code', 'POSSIBLE_DUPLICATE',
                    'duplicate_expense_id', v_dup.expense_id,
                    'message', 'You already recorded an expense from ' || trim(p_vendor) || ' on '
                        || to_char(p_expense_date, 'DD Mon YYYY') || ' for the same amount. Save it again only if it is a separate purchase.');
            END IF;
        END IF;

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

        IF v_dup.expense_id IS NOT NULL THEN
            PERFORM record_audit_log('EXPENSE_POSSIBLE_DUPLICATE_CONFIRMED', 'expenses', v_expense_id, NULL,
                jsonb_build_object('duplicate_of', v_dup.expense_id, 'confirmed_by', v_uid));
        END IF;

        RETURN jsonb_build_object('success', true, 'code', 'EXPENSE_RECORDED', 'replayed', false,
            'expense_id', v_expense_id, 'receipt_id', v_receipt_id,
            'amount_minor', p_amount_minor, 'currency_code', p_currency_code,
            'exchange_rate', v_rate, 'aed_amount_minor', v_aed, 'has_receipt', v_has_receipt,
            'possible_duplicate_of', v_dup.expense_id,
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

REVOKE ALL ON FUNCTION create_expense_with_receipt(UUID, UUID, BIGINT, TEXT, DATE, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, BIGINT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_expense_with_receipt(UUID, UUID, BIGINT, TEXT, DATE, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, BIGINT, BOOLEAN) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. EDIT / DELETE OWN UNSUBMITTED EXPENSES
-- An expense is editable when it is not locked and is not attached to a claim
-- that is under review or finalized (DRAFT and CORRECTION_REQUIRED claims are
-- still the employee's to change).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_expense(
    p_expense_id UUID,
    p_category_id UUID,
    p_amount_minor BIGINT,
    p_currency_code TEXT,
    p_expense_date DATE,
    p_vendor TEXT,
    p_description TEXT,
    p_invoice_number TEXT DEFAULT NULL,
    p_tax_amount_minor BIGINT DEFAULT 0,
    p_no_receipt_reason TEXT DEFAULT NULL,
    p_receipt_total_minor BIGINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_old expenses%ROWTYPE;
    v_new expenses%ROWTYPE;
    v_receipt_count INT;
    v_rate NUMERIC;
    v_aed BIGINT;
    v_no_receipt_limit BIGINT;
    v_dup RECORD;
    v_code TEXT;
    v_detail TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_AUTHENTICATED', 'message', 'Your session has expired. Please sign in again.');
    END IF;

    BEGIN
        SELECT * INTO v_old FROM expenses WHERE id = p_expense_id AND employee_id = v_uid FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION USING MESSAGE = 'EXPENSE_NOT_FOUND', DETAIL = 'Expense not found.';
        END IF;
        IF v_old.is_locked OR EXISTS (
            SELECT 1 FROM claim_expenses ce JOIN expense_claims c ON c.id = ce.claim_id
            WHERE ce.expense_id = p_expense_id AND ce.released_at IS NULL
              AND c.status NOT IN ('DRAFT', 'CORRECTION_REQUIRED')
        ) THEN
            RAISE EXCEPTION USING MESSAGE = 'EXPENSE_LOCKED', DETAIL = 'This expense is part of a submitted claim and cannot be edited.';
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

        SELECT * INTO v_dup FROM find_duplicate_expense(v_uid, p_expense_id, p_vendor, p_invoice_number,
            p_expense_date, p_amount_minor, p_currency_code);
        IF FOUND AND v_dup.match_kind = 'INVOICE' THEN
            RAISE EXCEPTION USING MESSAGE = 'DUPLICATE_INVOICE',
                DETAIL = 'Invoice ' || trim(p_invoice_number) || ' from ' || trim(p_vendor) || ' is already recorded on another expense.';
        END IF;

        IF v_old.has_receipt THEN
            SELECT count(*) INTO v_receipt_count FROM expense_receipts WHERE expense_id = p_expense_id;
            IF p_receipt_total_minor IS NULL OR p_receipt_total_minor <= 0 THEN
                RAISE EXCEPTION USING MESSAGE = 'RECEIPT_TOTAL_REQUIRED', DETAIL = 'Enter the total shown on the receipt.';
            END IF;
            IF v_receipt_count > 1 AND (p_amount_minor <> v_old.amount_minor OR p_currency_code <> v_old.currency_code) THEN
                RAISE EXCEPTION USING MESSAGE = 'MULTIPLE_RECEIPTS',
                    DETAIL = 'This expense has several receipts; its amount and currency cannot be edited. Delete it and record it again.';
            END IF;
            IF v_receipt_count = 1 THEN
                UPDATE expense_receipts
                SET receipt_total_minor = p_receipt_total_minor, currency_code = p_currency_code
                WHERE expense_id = p_expense_id;
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
                    DETAIL = 'Expenses above AED ' || to_char(v_no_receipt_limit / 100.0, 'FM999,999,990.00') || ' require a receipt.';
            END IF;
        END IF;

        UPDATE expenses SET
            category_id = p_category_id,
            amount_minor = p_amount_minor,
            currency_code = p_currency_code,
            exchange_rate = v_rate,
            aed_amount_minor = v_aed,
            expense_date = p_expense_date,
            vendor = trim(p_vendor),
            invoice_number = NULLIF(trim(COALESCE(p_invoice_number, '')), ''),
            tax_amount_minor = p_tax_amount_minor,
            description = trim(p_description),
            no_receipt_reason = CASE WHEN v_old.has_receipt THEN NULL ELSE trim(p_no_receipt_reason) END,
            updated_at = now()
        WHERE id = p_expense_id
        RETURNING * INTO v_new;

        PERFORM record_audit_log('EXPENSE_EDITED', 'expenses', p_expense_id, to_jsonb(v_old), to_jsonb(v_new));

        RETURN jsonb_build_object('success', true, 'code', 'EXPENSE_UPDATED',
            'expense_id', p_expense_id, 'aed_amount_minor', v_new.aed_amount_minor,
            'exchange_rate', v_new.exchange_rate,
            'possible_duplicate_of', CASE WHEN v_dup.match_kind = 'POSSIBLE' THEN v_dup.expense_id END,
            'message', 'Expense updated.');
    EXCEPTION
        WHEN raise_exception THEN
            GET STACKED DIAGNOSTICS v_code = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
            RETURN jsonb_build_object('success', false, 'code', v_code, 'message', COALESCE(NULLIF(v_detail, ''), 'Expense could not be updated.'));
        WHEN check_violation OR foreign_key_violation OR not_null_violation THEN
            RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_FAILED', 'message', 'Expense details are incomplete or invalid. Please review and try again.');
    END;
END;
$$;

-- Deletes an expense that has never been attached to any claim. Expenses with
-- claim history are kept for the audit trail.
CREATE OR REPLACE FUNCTION delete_expense(p_expense_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_old expenses%ROWTYPE;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_AUTHENTICATED', 'message', 'Your session has expired. Please sign in again.');
    END IF;

    SELECT * INTO v_old FROM expenses WHERE id = p_expense_id AND employee_id = v_uid FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'EXPENSE_NOT_FOUND', 'message', 'Expense not found.');
    END IF;
    IF v_old.is_locked THEN
        RETURN jsonb_build_object('success', false, 'code', 'EXPENSE_LOCKED', 'message', 'This expense is part of a submitted claim and cannot be deleted.');
    END IF;
    IF EXISTS (SELECT 1 FROM claim_expenses WHERE expense_id = p_expense_id) THEN
        RETURN jsonb_build_object('success', false, 'code', 'EXPENSE_HAS_CLAIM_HISTORY',
            'message', 'This expense has been part of a claim and is kept for the audit trail. It can be reused in a new claim instead.');
    END IF;

    DELETE FROM expenses WHERE id = p_expense_id;
    PERFORM record_audit_log('EXPENSE_DELETED', 'expenses', p_expense_id, to_jsonb(v_old), NULL);

    RETURN jsonb_build_object('success', true, 'code', 'EXPENSE_DELETED', 'expense_id', p_expense_id, 'message', 'Expense deleted.');
END;
$$;

REVOKE ALL ON FUNCTION update_expense(UUID, UUID, BIGINT, TEXT, DATE, TEXT, TEXT, TEXT, BIGINT, TEXT, BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_expense(UUID, UUID, BIGINT, TEXT, DATE, TEXT, TEXT, TEXT, BIGINT, TEXT, BIGINT) TO authenticated;
REVOKE ALL ON FUNCTION delete_expense(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION delete_expense(UUID) TO authenticated;

REVOKE UPDATE, DELETE ON expenses FROM anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. WORKFLOW NOTIFICATIONS
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_notifications_recipient_created ON notifications (recipient_id, created_at DESC);

CREATE OR REPLACE FUNCTION notify_employee(
    p_recipient UUID, p_title TEXT, p_body TEXT, p_event TEXT, p_entity_type TEXT, p_entity_id UUID
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_recipient IS NULL THEN
        RETURN;
    END IF;
    INSERT INTO notifications (recipient_id, title, body, event_type, entity_type, entity_id)
    VALUES (p_recipient, left(p_title, 200), p_body, p_event, p_entity_type, p_entity_id);
END;
$$;

-- Approvers for a workflow stage of the given employee's request.
CREATE OR REPLACE FUNCTION stage_approver_ids(p_employee_id UUID, p_stage TEXT)
RETURNS SETOF UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_stage = 'LINE_MANAGER_REVIEW' THEN
        RETURN QUERY SELECT e.line_manager_id FROM employees e
            WHERE e.id = p_employee_id AND e.line_manager_id IS NOT NULL AND e.line_manager_id <> p_employee_id;
    ELSIF p_stage = 'HOD_REVIEW' THEN
        RETURN QUERY SELECT e.hod_id FROM employees e
            WHERE e.id = p_employee_id AND e.hod_id IS NOT NULL AND e.hod_id <> p_employee_id;
    ELSIF p_stage IN ('SIVA_REVIEW', 'FINANCE_REVIEW', 'FINANCE_PAYMENT') THEN
        RETURN QUERY SELECT DISTINCT r.employee_id FROM employee_roles r
            JOIN employees e ON e.id = r.employee_id AND e.is_active = true
            WHERE r.role::text = CASE WHEN p_stage = 'SIVA_REVIEW' THEN 'MANAGEMENT' ELSE 'FINANCE' END
              AND r.employee_id <> p_employee_id;
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION notify_employee(UUID, TEXT, TEXT, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION stage_approver_ids(UUID, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION notify_claim_transition_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_ref TEXT := 'Claim #' || NEW.claim_number;
    v_amount TEXT := 'AED ' || to_char(NEW.total_expense_minor / 100.0, 'FM999,999,990.00');
    v_approver UUID;
    v_stage_label TEXT;
BEGIN
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;

    IF NEW.status::text IN ('LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW') THEN
        v_stage_label := CASE NEW.status::text
            WHEN 'LINE_MANAGER_REVIEW' THEN 'Line Manager'
            WHEN 'HOD_REVIEW' THEN 'Head of Department'
            WHEN 'SIVA_REVIEW' THEN 'Management'
            ELSE 'Finance' END;
        FOR v_approver IN SELECT * FROM stage_approver_ids(NEW.employee_id, NEW.status::text) LOOP
            PERFORM notify_employee(v_approver, 'Claim awaiting your approval',
                v_ref || ' (' || NEW.title || ', ' || v_amount || ') is waiting for ' || v_stage_label || ' review.',
                'CLAIM_APPROVAL_REQUIRED', 'expense_claim', NEW.id);
        END LOOP;
    ELSIF NEW.status::text = 'CORRECTION_REQUIRED' THEN
        PERFORM notify_employee(NEW.employee_id, 'Claim returned for correction',
            v_ref || ' was returned for correction. Review the approver comments and resubmit.',
            'CLAIM_CORRECTION_REQUIRED', 'expense_claim', NEW.id);
    ELSIF NEW.status::text = 'REJECTED' THEN
        PERFORM notify_employee(NEW.employee_id, 'Claim rejected',
            v_ref || ' (' || v_amount || ') was rejected. Open the claim to see the reason.',
            'CLAIM_REJECTED', 'expense_claim', NEW.id);
    ELSIF NEW.status::text = 'APPROVED' THEN
        PERFORM notify_employee(NEW.employee_id, 'Claim approved',
            v_ref || ' (' || v_amount || ') was approved and is awaiting payment.',
            'CLAIM_APPROVED', 'expense_claim', NEW.id);
        FOR v_approver IN SELECT * FROM stage_approver_ids(NEW.employee_id, 'FINANCE_PAYMENT') LOOP
            PERFORM notify_employee(v_approver, 'Reimbursement ready for payment',
                v_ref || ' was approved. Net reimbursement AED '
                    || to_char(NEW.net_reimbursement_minor / 100.0, 'FM999,999,990.00') || ' is awaiting payment.',
                'REIMBURSEMENT_PAYMENT_REQUIRED', 'expense_claim', NEW.id);
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_claim_transition ON expense_claims;
CREATE TRIGGER trg_notify_claim_transition
AFTER UPDATE OF status ON expense_claims
FOR EACH ROW EXECUTE FUNCTION notify_claim_transition_trigger();

CREATE OR REPLACE FUNCTION notify_advance_transition_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_ref TEXT := 'Cash advance #' || NEW.advance_number;
    v_amount TEXT := 'AED ' || to_char(NEW.aed_amount_minor / 100.0, 'FM999,999,990.00');
    v_approver UUID;
    v_stage_changed BOOLEAN := TG_OP = 'INSERT' OR NEW.current_approval_stage IS DISTINCT FROM OLD.current_approval_stage;
    v_status_changed BOOLEAN := TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status;
BEGIN
    IF v_stage_changed AND NEW.status::text NOT IN ('REJECTED', 'CANCELLED')
       AND NEW.current_approval_stage IN ('LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW') THEN
        FOR v_approver IN SELECT * FROM stage_approver_ids(NEW.employee_id, NEW.current_approval_stage) LOOP
            PERFORM notify_employee(v_approver, 'Cash advance awaiting your approval',
                v_ref || ' (' || v_amount || ') is waiting for your review.',
                'ADVANCE_APPROVAL_REQUIRED', 'cash_advance', NEW.id);
        END LOOP;
    END IF;

    IF v_status_changed AND TG_OP = 'UPDATE' THEN
        IF NEW.status::text = 'APPROVED' THEN
            PERFORM notify_employee(NEW.employee_id, 'Cash advance approved',
                v_ref || ' (' || v_amount || ') was approved and is awaiting disbursement.',
                'ADVANCE_APPROVED', 'cash_advance', NEW.id);
            FOR v_approver IN SELECT * FROM stage_approver_ids(NEW.employee_id, 'FINANCE_PAYMENT') LOOP
                PERFORM notify_employee(v_approver, 'Cash advance ready for disbursement',
                    v_ref || ' (' || v_amount || ') was approved and is awaiting disbursement.',
                    'ADVANCE_DISBURSEMENT_REQUIRED', 'cash_advance', NEW.id);
            END LOOP;
        ELSIF NEW.status::text = 'REJECTED' THEN
            PERFORM notify_employee(NEW.employee_id, 'Cash advance rejected',
                v_ref || ' (' || v_amount || ') was rejected. Open the advance to see the reason.',
                'ADVANCE_REJECTED', 'cash_advance', NEW.id);
        ELSIF NEW.status::text = 'PAID' THEN
            PERFORM notify_employee(NEW.employee_id, 'Cash advance disbursed',
                v_ref || ' (' || v_amount || ') has been disbursed.',
                'ADVANCE_PAID', 'cash_advance', NEW.id);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_advance_transition ON cash_advances;
CREATE TRIGGER trg_notify_advance_transition
AFTER INSERT OR UPDATE OF status, current_approval_stage ON cash_advances
FOR EACH ROW EXECUTE FUNCTION notify_advance_transition_trigger();

-- Notifications are created only by the server; recipients may mark them read.
REVOKE INSERT, UPDATE, DELETE ON notifications FROM anon, authenticated;
GRANT SELECT ON notifications TO authenticated;
GRANT UPDATE (is_read) ON notifications TO authenticated;
