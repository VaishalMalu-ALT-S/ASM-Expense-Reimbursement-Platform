-- ============================================================================
-- ASM Expense & Reimbursement Platform - Production Security Hardening
-- Migration: 20261018000005_security_hardening.sql
-- ============================================================================

-- 1. SEARCH_PATH HARDENING & DEFINER SECURITY
-- Every SECURITY DEFINER function must explicitly lock search_path to public, pg_temp
-- to prevent search-path hijacking attacks.

CREATE OR REPLACE FUNCTION has_role(role_name text) 
RETURNS boolean 
LANGUAGE plpgsql 
SECURITY DEFINER 
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM employee_roles
    WHERE employee_id = auth.uid()
      AND role::text = role_name
  );
END;
$$;

CREATE OR REPLACE FUNCTION has_role(role_name app_role) 
RETURNS boolean 
LANGUAGE plpgsql 
SECURITY DEFINER 
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM employee_roles
    WHERE employee_id = auth.uid()
      AND role = role_name
  );
END;
$$;

CREATE OR REPLACE FUNCTION auth_employee_id()
RETURNS UUID AS $$
    SELECT auth.uid();
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION is_manager_of(emp_id UUID)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM employees 
        WHERE id = emp_id AND line_manager_id = auth.uid()
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION is_hod_of(emp_id UUID)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM employees e
        JOIN departments d ON e.department_id = d.id
        WHERE e.id = emp_id AND d.hod_employee_id = auth.uid()
    );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- 2. HARDEN AUDIT LOGGING FUNCTION
CREATE OR REPLACE FUNCTION record_audit_log(
    p_action VARCHAR,
    p_entity_type VARCHAR,
    p_entity_id UUID,
    p_old_values JSONB DEFAULT NULL,
    p_new_values JSONB DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_role VARCHAR := 'SYSTEM';
BEGIN
    IF v_user_id IS NOT NULL THEN
        SELECT role::text INTO v_role 
        FROM employee_roles 
        WHERE employee_id = v_user_id 
        LIMIT 1;
    END IF;

    INSERT INTO audit_logs (
        actor_user_id,
        actor_role,
        action,
        entity_type,
        entity_id,
        old_values,
        new_values,
        created_at
    ) VALUES (
        v_user_id,
        COALESCE(v_role, 'EMPLOYEE'),
        p_action,
        p_entity_type,
        p_entity_id,
        p_old_values,
        p_new_values,
        now()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Lock down direct client modification of audit_logs
REVOKE INSERT, UPDATE, DELETE ON audit_logs FROM authenticated, anon, PUBLIC;
GRANT SELECT ON audit_logs TO authenticated;

-- 3. HARDEN CLAIM FINANCIAL TOTALS & SUBMISSION FUNCTIONS
CREATE OR REPLACE FUNCTION recalculate_claim_totals(p_claim_id UUID)
RETURNS VOID AS $$
DECLARE
    v_total_expense_minor BIGINT := 0;
    v_advance_applied_minor BIGINT := 0;
    v_net_reimbursement_minor BIGINT := 0;
    v_advance_id UUID;
    v_advance_balance BIGINT := 0;
BEGIN
    -- Sum all expenses attached to claim in AED minor units
    SELECT COALESCE(SUM(e.aed_amount_minor), 0)
    INTO v_total_expense_minor
    FROM claim_expenses ce
    JOIN expenses e ON ce.expense_id = e.id
    WHERE ce.claim_id = p_claim_id;

    -- Check if advance is attached
    SELECT cash_advance_id INTO v_advance_id
    FROM expense_claims
    WHERE id = p_claim_id;

    IF v_advance_id IS NOT NULL THEN
        SELECT (aed_amount_minor - reconciled_amount_minor)
        INTO v_advance_balance
        FROM cash_advances
        WHERE id = v_advance_id;

        IF v_advance_balance < 0 THEN
            v_advance_balance := 0;
        END IF;

        IF v_total_expense_minor >= v_advance_balance THEN
            v_advance_applied_minor := v_advance_balance;
            v_net_reimbursement_minor := v_total_expense_minor - v_advance_applied_minor;
        ELSE
            v_advance_applied_minor := v_total_expense_minor;
            v_net_reimbursement_minor := 0;
        END IF;
    ELSE
        v_advance_applied_minor := 0;
        v_net_reimbursement_minor := v_total_expense_minor;
    END IF;

    UPDATE expense_claims
    SET total_expense_minor = v_total_expense_minor,
        advance_applied_minor = v_advance_applied_minor,
        net_reimbursement_minor = v_net_reimbursement_minor,
        updated_at = now()
    WHERE id = p_claim_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

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
    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CLAIM_NOT_FOUND', 'message', 'Claim not found.');
    END IF;

    -- Verify authenticated user is strictly the claim owner
    IF v_claim.employee_id != auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'You can only submit your own claims.');
    END IF;

    IF v_claim.status NOT IN ('DRAFT', 'CORRECTION_REQUIRED') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Claim is not in editable status.');
    END IF;

    -- Recalculate totals server-side
    PERFORM recalculate_claim_totals(p_claim_id);
    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id;

    IF v_claim.total_expense_minor <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'EMPTY_CLAIM', 'message', 'Claim must contain at least one valid expense.');
    END IF;

    -- Fetch policy limits
    SELECT (rule_value->>'limit_minor')::BIGINT INTO v_no_receipt_limit 
    FROM policy_rules WHERE rule_key = 'no_receipt_limit_aed';
    IF v_no_receipt_limit IS NULL THEN v_no_receipt_limit := 50000; END IF;

    SELECT (rule_value->>'limit_minor')::BIGINT INTO v_max_claim_limit 
    FROM policy_rules WHERE rule_key = 'max_claim_limit_aed';
    IF v_max_claim_limit IS NULL THEN v_max_claim_limit := 1000000; END IF;

    -- Validate Max Claim Limit
    IF v_claim.total_expense_minor > v_max_claim_limit THEN
        RETURN jsonb_build_object(
            'success', false, 
            'code', 'MAX_CLAIM_LIMIT_EXCEEDED', 
            'message', 'Total claim exceeds the maximum allowed limit of AED ' || (v_max_claim_limit / 100)::text
        );
    END IF;

    -- Validate No-Receipt Policy
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

    -- Determine Line Manager or HOD
    SELECT line_manager_id INTO v_first_approver_id FROM employees WHERE id = v_claim.employee_id;
    IF v_first_approver_id IS NULL THEN
        SELECT hod_id INTO v_first_approver_id FROM employees WHERE id = v_claim.employee_id;
        v_next_status := 'HOD_REVIEW';
    ELSE
        v_next_status := 'LINE_MANAGER_REVIEW';
    END IF;

    -- Prevent self-routing if submitter is their own manager
    IF v_first_approver_id = auth.uid() THEN
        SELECT hod_id INTO v_first_approver_id FROM employees WHERE id = v_claim.employee_id;
        v_next_status := 'HOD_REVIEW';
    END IF;

    -- Lock all associated expenses
    UPDATE expenses 
    SET is_locked = true 
    WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id);

    -- Update Claim Status
    UPDATE expense_claims
    SET status = v_next_status,
        validation_status = 'PASSED',
        validation_notes = 'Deterministic policy and receipt validations passed on submission.',
        submitted_at = now(),
        updated_at = now()
    WHERE id = p_claim_id;

    -- Create Approval Instance
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
        CASE WHEN v_next_status = 'LINE_MANAGER_REVIEW' THEN 'LINE_MANAGER' ELSE 'HOD' END,
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

-- 4. HARDEN MULTI-TIER APPROVAL ENGINE
CREATE OR REPLACE FUNCTION process_approval_action(
    p_claim_id UUID,
    p_action approval_action_type,
    p_comments TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
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
    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CLAIM_NOT_FOUND', 'message', 'Claim not found.');
    END IF;

    -- Rule 1: Prevent Self-Approval under all circumstances
    IF v_claim.employee_id = v_user_id THEN
        RETURN jsonb_build_object('success', false, 'code', 'SELF_APPROVAL_FORBIDDEN', 'message', 'Self-approval is strictly forbidden by ASM policy.');
    END IF;

    -- Rule 2: Cannot action claims that are already finalized
    IF v_claim.status IN ('APPROVED', 'SETTLED', 'REJECTED', 'CANCELLED') THEN
        RETURN jsonb_build_object('success', false, 'code', 'ALREADY_FINALIZED', 'message', 'This claim has already been finalized.');
    END IF;

    SELECT * INTO v_employee FROM employees WHERE id = v_claim.employee_id;
    SELECT * INTO v_instance FROM approval_instances WHERE claim_id = p_claim_id AND status = 'IN_PROGRESS' ORDER BY started_at DESC LIMIT 1;

    -- Verify Authorization strictly based on current workflow step
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

    -- Action: REJECT
    IF p_action = 'REJECT' THEN
        IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
            RETURN jsonb_build_object('success', false, 'code', 'COMMENT_REQUIRED', 'message', 'Reason comments are mandatory when rejecting a claim.');
        END IF;

        UPDATE expense_claims SET status = 'REJECTED', updated_at = now() WHERE id = p_claim_id;
        IF v_instance.id IS NOT NULL THEN
            UPDATE approval_instances SET status = 'REJECTED', completed_at = now() WHERE id = v_instance.id;
        END IF;
        UPDATE expenses SET is_locked = false WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id);

        INSERT INTO approval_actions (approval_instance_id, claim_id, step_order, actor_id, action, previous_status, new_status, comments)
        VALUES (v_instance.id, p_claim_id, COALESCE(v_instance.current_step_order, 1), v_user_id, 'REJECT', v_claim.status, 'REJECTED', p_comments);

        RETURN jsonb_build_object('success', true, 'status', 'REJECTED');
    END IF;

    -- Action: REQUEST_CORRECTION
    IF p_action = 'REQUEST_CORRECTION' THEN
        IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
            RETURN jsonb_build_object('success', false, 'code', 'COMMENT_REQUIRED', 'message', 'Please specify what correction is required.');
        END IF;

        UPDATE expense_claims SET status = 'CORRECTION_REQUIRED', validation_notes = p_comments, updated_at = now() WHERE id = p_claim_id;
        IF v_instance.id IS NOT NULL THEN
            UPDATE approval_instances SET status = 'CORRECTION_REQUIRED' WHERE id = v_instance.id;
        END IF;
        -- Unlock expenses for employee modification
        UPDATE expenses SET is_locked = false WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id);

        INSERT INTO approval_actions (approval_instance_id, claim_id, step_order, actor_id, action, previous_status, new_status, comments)
        VALUES (v_instance.id, p_claim_id, COALESCE(v_instance.current_step_order, 1), v_user_id, 'REQUEST_CORRECTION', v_claim.status, 'CORRECTION_REQUIRED', p_comments);

        RETURN jsonb_build_object('success', true, 'status', 'CORRECTION_REQUIRED');
    END IF;

    -- Action: APPROVE
    IF p_action = 'APPROVE' THEN
        IF v_claim.status = 'LINE_MANAGER_REVIEW' THEN
            v_next_status := 'HOD_REVIEW';
            v_next_approver := v_employee.hod_id;
            v_next_role := 'DEPARTMENT_MANAGER';
        ELSIF v_claim.status = 'HOD_REVIEW' THEN
            v_next_status := 'FINANCE_REVIEW';
            v_next_role := 'FINANCE';
        ELSIF v_claim.status = 'SIVA_REVIEW' THEN
            v_next_status := 'FINANCE_REVIEW';
            v_next_role := 'FINANCE';
        ELSIF v_claim.status = 'FINANCE_REVIEW' THEN
            v_next_status := 'APPROVED';
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

            -- Reconcile advance balance
            IF v_claim.cash_advance_id IS NOT NULL AND v_claim.advance_applied_minor > 0 THEN
                UPDATE cash_advances
                SET reconciled_amount_minor = reconciled_amount_minor + v_claim.advance_applied_minor,
                    status = CASE 
                        WHEN (reconciled_amount_minor + v_claim.advance_applied_minor) >= aed_amount_minor THEN 'SETTLED'::cash_advance_status
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

        RETURN jsonb_build_object('success', true, 'status', v_next_status);
    END IF;

    RETURN jsonb_build_object('success', false, 'code', 'UNSUPPORTED_ACTION', 'message', 'Action not supported.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- 5. HARDEN REIMBURSEMENT PAYMENT SETTLEMENT
CREATE OR REPLACE FUNCTION record_reimbursement_payment(
    p_reimbursement_id UUID,
    p_idempotency_key VARCHAR,
    p_payment_reference VARCHAR,
    p_payment_method VARCHAR DEFAULT 'BANK_TRANSFER',
    p_notes TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_reimb RECORD;
    v_payment_id UUID;
BEGIN
    -- Security: Strictly Finance or Admin
    IF NOT (has_role('FINANCE') OR has_role('ADMIN')) THEN
        RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only Finance or Admin can record payments.');
    END IF;

    -- Idempotency check
    SELECT id INTO v_payment_id FROM payments WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true, 
            'code', 'IDEMPOTENT_SUCCESS', 
            'message', 'Payment already processed with this idempotency key.', 
            'payment_id', v_payment_id
        );
    END IF;

    SELECT * INTO v_reimb FROM reimbursements WHERE id = p_reimbursement_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Reimbursement not found.');
    END IF;

    IF v_reimb.status = 'PAID' THEN
        RETURN jsonb_build_object('success', false, 'code', 'ALREADY_PAID', 'message', 'This reimbursement has already been paid.');
    END IF;

    -- Atomic Insert Payment
    INSERT INTO payments (
        reimbursement_id,
        payment_reference,
        idempotency_key,
        payment_method,
        paid_amount_minor,
        payment_date,
        recorded_by,
        notes
    ) VALUES (
        p_reimbursement_id,
        p_payment_reference,
        p_idempotency_key,
        p_payment_method,
        v_reimb.amount_minor,
        CURRENT_DATE,
        v_user_id,
        p_notes
    ) RETURNING id INTO v_payment_id;

    -- Update Reimbursement Status
    UPDATE reimbursements 
    SET status = 'PAID', paid_at = now() 
    WHERE id = p_reimbursement_id;

    -- Update Parent Claim Status to SETTLED
    UPDATE expense_claims 
    SET status = 'SETTLED', updated_at = now() 
    WHERE id = v_reimb.claim_id;

    RETURN jsonb_build_object(
        'success', true, 
        'code', 'PAYMENT_RECORDED', 
        'payment_id', v_payment_id
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Revoke dangerous direct execution and grant strictly to authenticated
REVOKE ALL ON FUNCTION recalculate_claim_totals(UUID) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION submit_claim_for_approval(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION process_approval_action(UUID, approval_action_type, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION record_reimbursement_payment(UUID, VARCHAR, VARCHAR, VARCHAR, TEXT) TO authenticated;

-- 6. CLIENT WRITE PROTECTION TRIGGERS (DATABASE ENFORCED)

-- Protection A: Prevent employees from updating reporting hierarchy
CREATE OR REPLACE FUNCTION protect_employee_hierarchy_trigger()
RETURNS TRIGGER AS $$
BEGIN
    -- Check if called from client session
    IF current_setting('request.jwt.claims', true) IS NOT NULL THEN
        IF NOT has_role('ADMIN') THEN
            IF NEW.line_manager_id IS DISTINCT FROM OLD.line_manager_id
               OR NEW.hod_id IS DISTINCT FROM OLD.hod_id
               OR NEW.department_id IS DISTINCT FROM OLD.department_id
               OR NEW.is_active IS DISTINCT FROM OLD.is_active
               OR NEW.employee_code IS DISTINCT FROM OLD.employee_code THEN
                RAISE EXCEPTION 'Security Violation: Employees are not permitted to modify reporting hierarchy, department, or status.';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_protect_employee_hierarchy ON employees;
CREATE TRIGGER trg_protect_employee_hierarchy
BEFORE UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION protect_employee_hierarchy_trigger();

-- Protection B: Prevent clients from directly writing workflow status and financial totals
CREATE OR REPLACE FUNCTION protect_claim_financials_and_status_trigger()
RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('request.jwt.claims', true) IS NOT NULL THEN
        IF NOT has_role('ADMIN') THEN
            -- Only allow client updates when in DRAFT or CORRECTION_REQUIRED
            IF OLD.status NOT IN ('DRAFT', 'CORRECTION_REQUIRED') THEN
                RAISE EXCEPTION 'Security Violation: Claim is locked under review and cannot be modified directly.';
            END IF;
            
            -- Clients must not directly change status (must call submit_claim_for_approval or process_approval_action)
            IF NEW.status IS DISTINCT FROM OLD.status THEN
                RAISE EXCEPTION 'Security Violation: Direct modification of claim status is prohibited. Use workflow approval functions.';
            END IF;

            -- Clients must not directly tamper with financial totals
            IF NEW.total_expense_minor IS DISTINCT FROM OLD.total_expense_minor
               OR NEW.advance_applied_minor IS DISTINCT FROM OLD.advance_applied_minor
               OR NEW.net_reimbursement_minor IS DISTINCT FROM OLD.net_reimbursement_minor THEN
                RAISE EXCEPTION 'Security Violation: Direct modification of financial totals is prohibited. Totals are computed server-side.';
            END IF;

            -- Validation status is server-controlled
            IF NEW.validation_status IS DISTINCT FROM OLD.validation_status THEN
                RAISE EXCEPTION 'Security Violation: Validation status is server-controlled.';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_protect_claim_financials_and_status ON expense_claims;
CREATE TRIGGER trg_protect_claim_financials_and_status
BEFORE UPDATE ON expense_claims
FOR EACH ROW EXECUTE FUNCTION protect_claim_financials_and_status_trigger();

-- Protection C: Prevent modifying locked expenses and enforce currency conversion math
CREATE OR REPLACE FUNCTION protect_expense_modifications_trigger()
RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('request.jwt.claims', true) IS NOT NULL THEN
        IF NOT has_role('ADMIN') THEN
            IF OLD.is_locked = true THEN
                RAISE EXCEPTION 'Security Violation: This expense is locked in a submitted claim and cannot be modified.';
            END IF;
            IF NEW.is_locked IS DISTINCT FROM OLD.is_locked AND NEW.is_locked = false THEN
                RAISE EXCEPTION 'Security Violation: Clients cannot unlock expenses directly.';
            END IF;
        END IF;
    END IF;
    -- Always enforce AED amount is mathematically consistent
    IF NEW.exchange_rate > 0 THEN
        NEW.aed_amount_minor := ROUND(NEW.amount_minor * NEW.exchange_rate);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_protect_expense_modifications ON expenses;
CREATE TRIGGER trg_protect_expense_modifications
BEFORE UPDATE ON expenses
FOR EACH ROW EXECUTE FUNCTION protect_expense_modifications_trigger();

-- 7. ATTACHMENT INTEGRITY: Prevent same expense from belonging to multiple claims
ALTER TABLE claim_expenses DROP CONSTRAINT IF EXISTS unique_expense_per_claim;
ALTER TABLE claim_expenses ADD CONSTRAINT unique_expense_per_claim UNIQUE (expense_id);

-- 8. STORAGE HARDENING (RECEIPTS BUCKET)
-- Ensure receipts bucket is strictly private
UPDATE storage.buckets SET public = false WHERE id = 'receipts';

DROP POLICY IF EXISTS "Authenticated users can upload receipts" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can view receipts" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can update receipts" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can delete receipts" ON storage.objects;

-- Strict INSERT: Only owner can upload to their designated user folder
CREATE POLICY "Strict owner receipt upload"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
    bucket_id = 'receipts'
    AND (storage.foldername(name))[1] = auth.uid()::text
);

-- Strict SELECT: Owner, Authorized Approvers (Manager / HOD), Finance, and Admin
CREATE POLICY "Strict authorized receipt view"
ON storage.objects FOR SELECT TO authenticated
USING (
    bucket_id = 'receipts'
    AND (
        -- Owner
        (storage.foldername(name))[1] = auth.uid()::text
        -- Finance, Management, Admin
        OR has_role('FINANCE')
        OR has_role('MANAGEMENT')
        OR has_role('ADMIN')
        -- Direct Line Manager of the receipt owner
        OR (
            (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
            AND is_manager_of((storage.foldername(name))[1]::uuid)
        )
        -- Department HOD of the receipt owner
        OR (
            (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
            AND is_hod_of((storage.foldername(name))[1]::uuid)
        )
    )
);

-- Strict UPDATE & DELETE: Only owner on their own files or Admin
CREATE POLICY "Strict owner receipt update"
ON storage.objects FOR UPDATE TO authenticated
USING (
    bucket_id = 'receipts'
    AND ((storage.foldername(name))[1] = auth.uid()::text OR has_role('ADMIN'))
);

CREATE POLICY "Strict owner receipt delete"
ON storage.objects FOR DELETE TO authenticated
USING (
    bucket_id = 'receipts'
    AND ((storage.foldername(name))[1] = auth.uid()::text OR has_role('ADMIN'))
);
