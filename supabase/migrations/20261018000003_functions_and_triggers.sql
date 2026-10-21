-- ============================================================================
-- ASM Expense & Reimbursement Platform — Financial Functions & Triggers
-- Migration: 20261018000003_functions_and_triggers.sql
-- ============================================================================

-- 1. Helper function to record audit logs
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Audit triggers for Expenses, Claims, Advances, Payments
CREATE OR REPLACE FUNCTION audit_entity_change_trigger()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        PERFORM record_audit_log(TG_TABLE_NAME || '_CREATED', TG_TABLE_NAME, NEW.id, NULL, to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'UPDATE') THEN
        PERFORM record_audit_log(TG_TABLE_NAME || '_UPDATED', TG_TABLE_NAME, NEW.id, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSIF (TG_OP = 'DELETE') THEN
        PERFORM record_audit_log(TG_TABLE_NAME || '_DELETED', TG_TABLE_NAME, OLD.id, to_jsonb(OLD), NULL);
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_audit_expenses ON expenses;
CREATE TRIGGER trg_audit_expenses AFTER INSERT OR UPDATE OR DELETE ON expenses FOR EACH ROW EXECUTE FUNCTION audit_entity_change_trigger();

DROP TRIGGER IF EXISTS trg_audit_claims ON expense_claims;
CREATE TRIGGER trg_audit_claims AFTER INSERT OR UPDATE OR DELETE ON expense_claims FOR EACH ROW EXECUTE FUNCTION audit_entity_change_trigger();

DROP TRIGGER IF EXISTS trg_audit_advances ON cash_advances;
CREATE TRIGGER trg_audit_advances AFTER INSERT OR UPDATE OR DELETE ON cash_advances FOR EACH ROW EXECUTE FUNCTION audit_entity_change_trigger();

DROP TRIGGER IF EXISTS trg_audit_payments ON payments;
CREATE TRIGGER trg_audit_payments AFTER INSERT OR UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION audit_entity_change_trigger();

-- 3. Deterministic Recalculation of Claim Totals
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

        -- Apply advance against expense
        IF v_total_expense_minor >= v_advance_balance THEN
            v_advance_applied_minor := v_advance_balance;
            v_net_reimbursement_minor := v_total_expense_minor - v_advance_applied_minor;
        ELSE
            v_advance_applied_minor := v_total_expense_minor;
            v_net_reimbursement_minor := 0; -- Employee still owes the remainder of the advance
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Server-Side Deterministic Claim Submission & Validation Engine
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

    IF v_claim.status NOT IN ('DRAFT', 'CORRECTION_REQUIRED') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Claim is not in editable status.');
    END IF;

    -- Verify authenticated user is owner
    IF v_claim.employee_id != auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'You can only submit your own claims.');
    END IF;

    -- Recalculate totals first
    PERFORM recalculate_claim_totals(p_claim_id);
    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id;

    IF v_claim.total_expense_minor <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'EMPTY_CLAIM', 'message', 'Claim must contain at least one valid expense.');
    END IF;

    -- Fetch configurable rules
    SELECT (rule_value->>'limit_minor')::BIGINT INTO v_no_receipt_limit 
    FROM policy_rules WHERE rule_key = 'no_receipt_limit_aed';
    IF v_no_receipt_limit IS NULL THEN v_no_receipt_limit := 50000; END IF; -- Default 500.00 AED (50000 fils)

    SELECT (rule_value->>'limit_minor')::BIGINT INTO v_max_claim_limit 
    FROM policy_rules WHERE rule_key = 'max_claim_limit_aed';
    IF v_max_claim_limit IS NULL THEN v_max_claim_limit := 1000000; END IF; -- Default 10,000.00 AED (1000000 fils)

    -- Check Max Claim Limit
    IF v_claim.total_expense_minor > v_max_claim_limit THEN
        RETURN jsonb_build_object(
            'success', false, 
            'code', 'MAX_CLAIM_LIMIT_EXCEEDED', 
            'message', 'Total claim exceeds the maximum allowed limit of AED ' || (v_max_claim_limit / 100)::text
        );
    END IF;

    -- Validate No-Receipt Policy for each expense
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

    -- Determine Line Manager
    SELECT line_manager_id INTO v_first_approver_id FROM employees WHERE id = v_claim.employee_id;
    IF v_first_approver_id IS NULL THEN
        -- Fallback to HOD if no direct line manager
        SELECT hod_id INTO v_first_approver_id FROM employees WHERE id = v_claim.employee_id;
        v_next_status := 'HOD_REVIEW';
    ELSE
        v_next_status := 'LINE_MANAGER_REVIEW';
    END IF;

    -- Lock all associated expenses so they cannot be edited during review
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

    -- Create/Update Approval Instance
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
        'LINE_MANAGER',
        'IN_PROGRESS',
        now()
    ) RETURNING id INTO v_instance_id;

    -- Create notification for Approver
    IF v_first_approver_id IS NOT NULL THEN
        INSERT INTO notifications (
            recipient_id,
            title,
            body,
            event_type,
            entity_type,
            entity_id
        ) VALUES (
            v_first_approver_id,
            'Expense Claim Awaiting Your Review',
            'Claim #' || v_claim.claim_number || ' totaling AED ' || (v_claim.total_expense_minor / 100)::text || ' requires your review.',
            'CLAIM_APPROVAL_REQUIRED',
            'expense_claim',
            p_claim_id
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true, 
        'code', 'CLAIM_SUBMITTED', 
        'message', 'Claim successfully submitted for approval.',
        'status', v_next_status
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Multi-Tier Approval Action Engine (Strict Prevention of Self-Approval & IDOR)
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

    -- Rule: Prevent Self-Approval under all circumstances
    IF v_claim.employee_id = v_user_id THEN
        RETURN jsonb_build_object('success', false, 'code', 'SELF_APPROVAL_FORBIDDEN', 'message', 'Self-approval is strictly forbidden by ASM policy.');
    END IF;

    SELECT * INTO v_employee FROM employees WHERE id = v_claim.employee_id;
    SELECT * INTO v_instance FROM approval_instances WHERE claim_id = p_claim_id AND status = 'IN_PROGRESS' ORDER BY started_at DESC LIMIT 1;

    -- Verify Authorization based on current stage
    IF v_claim.status = 'LINE_MANAGER_REVIEW' THEN
        IF v_employee.line_manager_id = v_user_id OR has_role('ADMIN') THEN
            v_is_authorized := true;
        END IF;
    ELSIF v_claim.status = 'HOD_REVIEW' THEN
        IF v_employee.hod_id = v_user_id OR has_role('ADMIN') THEN
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

    -- Handle Action: REJECT
    IF p_action = 'REJECT' THEN
        IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
            RETURN jsonb_build_object('success', false, 'code', 'COMMENT_REQUIRED', 'message', 'Reason comments are mandatory when rejecting a claim.');
        END IF;

        UPDATE expense_claims SET status = 'REJECTED', updated_at = now() WHERE id = p_claim_id;
        UPDATE approval_instances SET status = 'REJECTED', completed_at = now() WHERE id = v_instance.id;
        UPDATE expenses SET is_locked = false WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id);

        INSERT INTO approval_actions (approval_instance_id, claim_id, step_order, actor_id, action, previous_status, new_status, comments)
        VALUES (v_instance.id, p_claim_id, v_instance.current_step_order, v_user_id, 'REJECT', v_claim.status, 'REJECTED', p_comments);

        INSERT INTO notifications (recipient_id, title, body, event_type, entity_type, entity_id)
        VALUES (v_claim.employee_id, 'Claim Rejected', 'Your claim #' || v_claim.claim_number || ' was rejected: ' || p_comments, 'CLAIM_REJECTED', 'expense_claim', p_claim_id);

        RETURN jsonb_build_object('success', true, 'status', 'REJECTED');
    END IF;

    -- Handle Action: REQUEST_CORRECTION
    IF p_action = 'REQUEST_CORRECTION' THEN
        IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
            RETURN jsonb_build_object('success', false, 'code', 'COMMENT_REQUIRED', 'message', 'Please specify what correction is required.');
        END IF;

        UPDATE expense_claims SET status = 'CORRECTION_REQUIRED', validation_notes = p_comments, updated_at = now() WHERE id = p_claim_id;
        UPDATE approval_instances SET status = 'CORRECTION_REQUIRED' WHERE id = v_instance.id;
        -- Unlock expenses for correction
        UPDATE expenses SET is_locked = false WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id);

        INSERT INTO approval_actions (approval_instance_id, claim_id, step_order, actor_id, action, previous_status, new_status, comments)
        VALUES (v_instance.id, p_claim_id, v_instance.current_step_order, v_user_id, 'REQUEST_CORRECTION', v_claim.status, 'CORRECTION_REQUIRED', p_comments);

        INSERT INTO notifications (recipient_id, title, body, event_type, entity_type, entity_id)
        VALUES (v_claim.employee_id, 'Correction Required on Claim', 'Correction needed for claim #' || v_claim.claim_number || ': ' || p_comments, 'CORRECTION_REQUIRED', 'expense_claim', p_claim_id);

        RETURN jsonb_build_object('success', true, 'status', 'CORRECTION_REQUIRED');
    END IF;

    -- Handle Action: APPROVE (Advance to Next Tier)
    IF p_action = 'APPROVE' THEN
        IF v_claim.status = 'LINE_MANAGER_REVIEW' THEN
            v_next_status := 'HOD_REVIEW';
            v_next_approver := v_employee.hod_id;
            v_next_role := 'DEPARTMENT_MANAGER';
        ELSIF v_claim.status = 'HOD_REVIEW' THEN
            v_next_status := 'SIVA_REVIEW';
            v_next_role := 'MANAGEMENT';
        ELSIF v_claim.status = 'SIVA_REVIEW' THEN
            v_next_status := 'FINANCE_REVIEW';
            v_next_role := 'FINANCE';
        ELSIF v_claim.status = 'FINANCE_REVIEW' THEN
            v_next_status := 'APPROVED';
        END IF;

        -- Record Approval Action
        INSERT INTO approval_actions (approval_instance_id, claim_id, step_order, actor_id, action, previous_status, new_status, comments)
        VALUES (v_instance.id, p_claim_id, v_instance.current_step_order, v_user_id, 'APPROVE', v_claim.status, v_next_status, p_comments);

        IF v_next_status = 'APPROVED' THEN
            -- Fully approved by Finance! Create reimbursement record
            UPDATE expense_claims SET status = 'APPROVED', approved_at = now(), updated_at = now() WHERE id = p_claim_id;
            UPDATE approval_instances SET status = 'APPROVED', completed_at = now() WHERE id = v_instance.id;

            -- Create pending reimbursement if net reimbursable > 0
            IF v_claim.net_reimbursement_minor > 0 THEN
                INSERT INTO reimbursements (claim_id, employee_id, amount_minor, currency_code, aed_amount_minor, status)
                VALUES (p_claim_id, v_claim.employee_id, v_claim.net_reimbursement_minor, 'AED', v_claim.net_reimbursement_minor, 'PENDING')
                ON CONFLICT (claim_id) DO NOTHING;
            ELSE
                -- Net is 0 (or covered fully by cash advance)
                UPDATE expense_claims SET status = 'SETTLED' WHERE id = p_claim_id;
            END IF;

            -- Reconcile advance balance if an advance was applied
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

            INSERT INTO notifications (recipient_id, title, body, event_type, entity_type, entity_id)
            VALUES (v_claim.employee_id, 'Claim Fully Approved', 'Claim #' || v_claim.claim_number || ' has been approved by Finance and queued for payment.', 'CLAIM_APPROVED', 'expense_claim', p_claim_id);
        ELSE
            -- Move to next review step
            UPDATE expense_claims SET status = v_next_status, updated_at = now() WHERE id = p_claim_id;
            UPDATE approval_instances 
            SET current_step_order = current_step_order + 1,
                current_approver_id = v_next_approver,
                current_approver_role = v_next_role
            WHERE id = v_instance.id;

            -- Notify next approver if specific employee
            IF v_next_approver IS NOT NULL THEN
                INSERT INTO notifications (recipient_id, title, body, event_type, entity_type, entity_id)
                VALUES (v_next_approver, 'Claim Awaiting Your Approval', 'Claim #' || v_claim.claim_number || ' is now pending your review.', 'CLAIM_APPROVAL_REQUIRED', 'expense_claim', p_claim_id);
            END IF;
        END IF;

        RETURN jsonb_build_object('success', true, 'status', v_next_status);
    END IF;

    RETURN jsonb_build_object('success', false, 'code', 'UNSUPPORTED_ACTION', 'message', 'Action not supported.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. Idempotent Payment Settlement Engine (Finance Only)
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

    -- Check Idempotency Key
    SELECT id INTO v_payment_id FROM payments WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true, 
            'code', 'IDEMPOTENT_SUCCESS', 
            'message', 'Payment already processed with this key.', 
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

    -- Insert Payment atomically
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
    SET status = 'PAID',
        processed_by = v_user_id,
        updated_at = now()
    WHERE id = p_reimbursement_id;

    -- Update Claim Status to PAID and SETTLED
    UPDATE expense_claims
    SET status = 'PAID',
        updated_at = now()
    WHERE id = v_reimb.claim_id;

    -- Notify Employee
    INSERT INTO notifications (
        recipient_id,
        title,
        body,
        event_type,
        entity_type,
        entity_id
    ) VALUES (
        v_reimb.employee_id,
        'Payment Settled & Reimbursed',
        'Reimbursement of AED ' || (v_reimb.amount_minor / 100)::text || ' has been processed. Ref: ' || p_payment_reference,
        'PAYMENT_COMPLETED',
        'reimbursement',
        p_reimbursement_id
    );

    RETURN jsonb_build_object(
        'success', true, 
        'code', 'PAYMENT_RECORDED', 
        'message', 'Payment successfully recorded.', 
        'payment_id', v_payment_id
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
