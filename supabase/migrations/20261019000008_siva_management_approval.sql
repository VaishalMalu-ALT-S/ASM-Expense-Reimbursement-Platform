-- ============================================================================
-- ASM Expense & Reimbursement Platform - Phase 3A
-- Migration: 20261019000008_siva_management_approval.sql
-- Description: Enable Siva / Management Approval in the 4-Tier Approval Chain
-- Flow: EMPLOYEE -> LINE MANAGER -> HOD -> SIVA/MANAGEMENT -> FINANCE -> PAID
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. HARDEN STATE MACHINE: ENFORCE STRICT 4-TIER APPROVAL PROGRESSION
-- Direct HOD -> FINANCE_REVIEW is disallowed; HOD must advance to SIVA_REVIEW.
-- SIVA_REVIEW can only transition to FINANCE_REVIEW, REJECTED, or CORRECTION_REQUIRED.
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
        -- Option B: HOD MUST progress to SIVA_REVIEW (no direct bypass to FINANCE_REVIEW)
        WHEN 'HOD_REVIEW' THEN ARRAY['SIVA_REVIEW', 'REJECTED', 'CORRECTION_REQUIRED']::claim_status[]
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

-- ----------------------------------------------------------------------------
-- 2. CANONICAL APPROVAL FUNCTION: HARDEN SIVA/MANAGEMENT TIER
-- Enforces:
-- - Row-level locking (FOR UPDATE) for strict concurrency protection
-- - Self-approval prevention
-- - Cross-stage duplicate approval prevention (cannot approve if previously approved this instance)
-- - Strict stage authorization (MANAGEMENT role required for SIVA_REVIEW)
-- - Explicit audit logging
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
    -- An approver who already approved this claim during the active instance cannot approve it again
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
-- 3. RLS HARDENING: GRANT MANAGEMENT ROLE ACCESS TO CLAIM JUNCTIONS & AUDIT TRAIL
-- Ensures users with MANAGEMENT role can view claim_expenses, approval_instances,
-- and approval_actions when reviewing claims at the SIVA_REVIEW stage.
-- ----------------------------------------------------------------------------

-- Claim Expenses Visibility
DROP POLICY IF EXISTS "Claim expenses visibility" ON claim_expenses;
CREATE POLICY "Claim expenses visibility" ON claim_expenses FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM expense_claims c 
        WHERE c.id = claim_expenses.claim_id 
          AND (
            c.employee_id = auth_employee_id() 
            OR is_manager_of(c.employee_id) 
            OR is_hod_of(c.employee_id) 
            OR has_role('MANAGEMENT')
            OR has_role('FINANCE') 
            OR has_role('ADMIN')
          )
    )
);

-- Approval Instances Visibility
DROP POLICY IF EXISTS "Approval instance visibility" ON approval_instances;
CREATE POLICY "Approval instance visibility" ON approval_instances FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM expense_claims c 
        WHERE c.id = approval_instances.claim_id 
          AND (
            c.employee_id = auth_employee_id() 
            OR is_manager_of(c.employee_id) 
            OR is_hod_of(c.employee_id) 
            OR has_role('MANAGEMENT')
            OR has_role('FINANCE') 
            OR has_role('ADMIN')
          )
    )
);

-- Approval Actions Visibility
DROP POLICY IF EXISTS "Approval action visibility" ON approval_actions;
CREATE POLICY "Approval action visibility" ON approval_actions FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM expense_claims c 
        WHERE c.id = approval_actions.claim_id 
          AND (
            c.employee_id = auth_employee_id() 
            OR is_manager_of(c.employee_id) 
            OR is_hod_of(c.employee_id) 
            OR has_role('MANAGEMENT')
            OR has_role('FINANCE') 
            OR has_role('ADMIN')
          )
    )
);

-- ----------------------------------------------------------------------------
-- 4. FUNCTION PERMISSIONS
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION process_approval_action(UUID, approval_action_type, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION process_approval_action(UUID, approval_action_type, TEXT) TO authenticated;
