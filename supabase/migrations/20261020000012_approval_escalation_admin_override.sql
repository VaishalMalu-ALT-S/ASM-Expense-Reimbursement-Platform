-- ============================================================================
-- MIGRATION 0012: SAME-APPROVER ESCALATION AND ADMIN OVERRIDE
-- Forward-only. Does not modify migrations 0001-0011.
--
-- Business decisions (confirmed by the product owner):
-- 1. When the approver of the next stage is the same person who already
--    approved this request (or is the requester), that person is skipped and
--    the request is routed to the next level:
--      HOD_REVIEW  -> skipped when the employee's HOD already approved / is the requester
--      SIVA_REVIEW -> skipped only when Management holders exist but every one of
--                     them already approved / is the requester
--    FINANCE_REVIEW is never skipped. A stage with no approver configured at
--    all is not skipped (that is a hierarchy data problem).
-- 2. Admin may act at a stage they are not the designated approver for only as
--    an emergency override with a mandatory reason, flagged in the audit log.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. CLAIM STATE MACHINE: allow the forward skips produced by escalation.
-- Claim status is server-controlled (clients cannot update it directly).
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
        WHEN 'LINE_MANAGER_REVIEW' THEN ARRAY['HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW', 'REJECTED', 'CORRECTION_REQUIRED', 'CANCELLED']::claim_status[]
        WHEN 'HOD_REVIEW' THEN ARRAY['SIVA_REVIEW', 'FINANCE_REVIEW', 'REJECTED', 'CORRECTION_REQUIRED', 'CANCELLED']::claim_status[]
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

-- ----------------------------------------------------------------------------
-- 2. ESCALATION HELPERS
-- p_prior_approvers: everyone who has approved this request so far, including
-- the actor of the current approval.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION approval_stage_should_escalate(
    p_stage TEXT,
    p_employee_id UUID,
    p_prior_approvers UUID[]
)
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_hod UUID;
    v_holders INT;
    v_eligible INT;
BEGIN
    IF p_stage = 'HOD_REVIEW' THEN
        SELECT hod_id INTO v_hod FROM employees WHERE id = p_employee_id;
        IF v_hod IS NULL THEN
            RETURN NULL;
        END IF;
        IF v_hod = p_employee_id THEN
            RETURN 'HOD is the requester';
        END IF;
        IF v_hod = ANY(p_prior_approvers) THEN
            RETURN 'HOD already approved at an earlier stage';
        END IF;
    ELSIF p_stage = 'SIVA_REVIEW' THEN
        SELECT count(*),
               count(*) FILTER (WHERE r.employee_id <> p_employee_id AND NOT (r.employee_id = ANY(p_prior_approvers)))
        INTO v_holders, v_eligible
        FROM employee_roles r JOIN employees e ON e.id = r.employee_id AND e.is_active = true
        WHERE r.role = 'MANAGEMENT';
        IF v_holders > 0 AND v_eligible = 0 THEN
            RETURN 'every Management approver already approved or is the requester';
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION next_review_stage(p_stage TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE p_stage
        WHEN 'LINE_MANAGER_REVIEW' THEN 'HOD_REVIEW'
        WHEN 'HOD_REVIEW' THEN 'SIVA_REVIEW'
        WHEN 'SIVA_REVIEW' THEN 'FINANCE_REVIEW'
        WHEN 'FINANCE_REVIEW' THEN 'APPROVED'
    END;
$$;

REVOKE ALL ON FUNCTION approval_stage_should_escalate(TEXT, UUID, UUID[]) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. CLAIM APPROVAL (supersedes 0009)
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
    v_next_text TEXT;
    v_next_approver UUID := NULL;
    v_next_role app_role := NULL;
    v_is_designated BOOLEAN := false;
    v_admin_override BOOLEAN := false;
    v_prior UUID[];
    v_reason TEXT;
    v_skipped JSONB := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_AUTHENTICATED', 'message', 'Your session has expired. Please sign in again.');
    END IF;

    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CLAIM_NOT_FOUND', 'message', 'Claim not found.');
    END IF;

    IF v_claim.employee_id = v_user_id THEN
        RETURN jsonb_build_object('success', false, 'code', 'SELF_APPROVAL_FORBIDDEN', 'message', 'Self-approval is strictly forbidden by ASM policy.');
    END IF;

    IF v_claim.status IN ('APPROVED', 'SETTLED', 'REJECTED', 'CANCELLED') THEN
        RETURN jsonb_build_object('success', false, 'code', 'ALREADY_FINALIZED', 'message', 'This claim has already been finalized.');
    END IF;

    SELECT * INTO v_employee FROM employees WHERE id = v_claim.employee_id;
    SELECT * INTO v_instance FROM approval_instances
    WHERE claim_id = p_claim_id AND status = 'IN_PROGRESS'
    ORDER BY started_at DESC LIMIT 1 FOR UPDATE;

    IF p_action = 'APPROVE' THEN
        IF EXISTS (
            SELECT 1 FROM approval_actions
            WHERE claim_id = p_claim_id
              AND actor_id = v_user_id
              AND action = 'APPROVE'
              AND (v_instance.id IS NULL OR approval_instance_id = v_instance.id)
        ) THEN
            RETURN jsonb_build_object('success', false, 'code', 'ALREADY_APPROVED_PREVIOUS_STAGE',
                'message', 'You have already approved this claim at an earlier approval stage and cannot approve it again.');
        END IF;
    END IF;

    v_is_designated := CASE v_claim.status
        WHEN 'LINE_MANAGER_REVIEW' THEN v_employee.line_manager_id = v_user_id
        WHEN 'HOD_REVIEW' THEN v_employee.hod_id = v_user_id
        WHEN 'SIVA_REVIEW' THEN has_role('MANAGEMENT')
        WHEN 'FINANCE_REVIEW' THEN has_role('FINANCE')
        ELSE false
    END;
    v_is_designated := COALESCE(v_is_designated, false);

    IF NOT v_is_designated THEN
        IF v_claim.status IN ('LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW') AND has_role('ADMIN') THEN
            IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
                RETURN jsonb_build_object('success', false, 'code', 'ADMIN_OVERRIDE_REASON_REQUIRED',
                    'message', 'You are not the designated approver for this stage. An Admin override requires a reason.');
            END IF;
            v_admin_override := true;
        ELSE
            RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You are not authorized to review this claim at this stage.');
        END IF;
    END IF;

    IF v_admin_override THEN
        PERFORM record_audit_log('ADMIN_APPROVAL_OVERRIDE', 'expense_claims', p_claim_id, to_jsonb(v_claim),
            jsonb_build_object('stage', v_claim.status, 'action', p_action, 'reason', trim(p_comments), 'admin_id', v_user_id));
    END IF;

    IF p_action = 'REJECT' THEN
        IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
            RETURN jsonb_build_object('success', false, 'code', 'COMMENT_REQUIRED', 'message', 'Reason comments are mandatory when rejecting a claim.');
        END IF;

        UPDATE expense_claims SET status = 'REJECTED', updated_at = now() WHERE id = p_claim_id;
        IF v_instance.id IS NOT NULL THEN
            UPDATE approval_instances SET status = 'REJECTED', completed_at = now() WHERE id = v_instance.id;
        END IF;
        UPDATE expenses SET is_locked = false WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id AND released_at IS NULL);

        INSERT INTO approval_actions (approval_instance_id, claim_id, step_order, actor_id, action, previous_status, new_status, comments)
        VALUES (v_instance.id, p_claim_id, COALESCE(v_instance.current_step_order, 1), v_user_id, 'REJECT', v_claim.status, 'REJECTED', p_comments);

        PERFORM record_audit_log('CLAIM_REJECTED', 'expense_claims', p_claim_id, to_jsonb(v_claim), jsonb_build_object(
            'status', 'REJECTED', 'comments', p_comments, 'actor_id', v_user_id, 'admin_override', v_admin_override));

        RETURN jsonb_build_object('success', true, 'status', 'REJECTED', 'admin_override', v_admin_override);
    END IF;

    IF p_action = 'REQUEST_CORRECTION' THEN
        IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
            RETURN jsonb_build_object('success', false, 'code', 'COMMENT_REQUIRED', 'message', 'Please specify what correction is required.');
        END IF;

        UPDATE expense_claims SET status = 'CORRECTION_REQUIRED', validation_notes = p_comments, updated_at = now() WHERE id = p_claim_id;
        IF v_instance.id IS NOT NULL THEN
            UPDATE approval_instances SET status = 'CORRECTION_REQUIRED' WHERE id = v_instance.id;
        END IF;
        UPDATE expenses SET is_locked = false WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id AND released_at IS NULL);

        INSERT INTO approval_actions (approval_instance_id, claim_id, step_order, actor_id, action, previous_status, new_status, comments)
        VALUES (v_instance.id, p_claim_id, COALESCE(v_instance.current_step_order, 1), v_user_id, 'REQUEST_CORRECTION', v_claim.status, 'CORRECTION_REQUIRED', p_comments);

        PERFORM record_audit_log('CLAIM_CORRECTION_REQUESTED', 'expense_claims', p_claim_id, to_jsonb(v_claim), jsonb_build_object(
            'status', 'CORRECTION_REQUIRED', 'comments', p_comments, 'actor_id', v_user_id, 'admin_override', v_admin_override));

        RETURN jsonb_build_object('success', true, 'status', 'CORRECTION_REQUIRED', 'admin_override', v_admin_override);
    END IF;

    IF p_action = 'APPROVE' THEN
        v_next_text := next_review_stage(v_claim.status::text);
        IF v_next_text IS NULL THEN
            RETURN jsonb_build_object('success', false, 'code', 'INVALID_STAGE_TRANSITION', 'message', 'Claim is not currently in an approvable stage.');
        END IF;

        SELECT array_agg(DISTINCT actor_id) || v_user_id INTO v_prior
        FROM approval_actions
        WHERE claim_id = p_claim_id AND action = 'APPROVE'
          AND (v_instance.id IS NULL OR approval_instance_id = v_instance.id);
        v_prior := COALESCE(v_prior, ARRAY[v_user_id]);

        LOOP
            v_reason := approval_stage_should_escalate(v_next_text, v_claim.employee_id, v_prior);
            EXIT WHEN v_reason IS NULL;
            v_skipped := v_skipped || jsonb_build_object('stage', v_next_text, 'reason', v_reason);
            v_next_text := next_review_stage(v_next_text);
        END LOOP;
        v_next_status := v_next_text::claim_status;

        IF v_next_status = 'HOD_REVIEW' THEN
            v_next_approver := v_employee.hod_id;
            v_next_role := 'DEPARTMENT_MANAGER';
        ELSIF v_next_status = 'SIVA_REVIEW' THEN
            v_next_role := 'MANAGEMENT';
        ELSIF v_next_status = 'FINANCE_REVIEW' THEN
            v_next_role := 'FINANCE';
        END IF;

        IF v_instance.id IS NOT NULL THEN
            INSERT INTO approval_actions (approval_instance_id, claim_id, step_order, actor_id, action, previous_status, new_status, comments)
            VALUES (v_instance.id, p_claim_id, v_instance.current_step_order, v_user_id, 'APPROVE', v_claim.status, v_next_status, p_comments);
        END IF;

        IF jsonb_array_length(v_skipped) > 0 THEN
            PERFORM record_audit_log('CLAIM_STAGE_ESCALATED', 'expense_claims', p_claim_id, NULL,
                jsonb_build_object('from_status', v_claim.status, 'to_status', v_next_status, 'skipped', v_skipped, 'actor_id', v_user_id));
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
                SET current_step_order = current_step_order + 1 + jsonb_array_length(v_skipped),
                    current_approver_id = v_next_approver,
                    current_approver_role = v_next_role
                WHERE id = v_instance.id;
            END IF;
        END IF;

        PERFORM record_audit_log('CLAIM_APPROVED_STAGE', 'expense_claims', p_claim_id, to_jsonb(v_claim), jsonb_build_object(
            'previous_status', v_claim.status, 'new_status', v_next_status, 'actor_id', v_user_id,
            'comments', p_comments, 'admin_override', v_admin_override));

        RETURN jsonb_build_object('success', true, 'status', v_next_status,
            'admin_override', v_admin_override, 'escalated', v_skipped);
    END IF;

    RETURN jsonb_build_object('success', false, 'code', 'UNSUPPORTED_ACTION', 'message', 'Action not supported.');
END;
$$;

-- ----------------------------------------------------------------------------
-- 4. CASH ADVANCE REVIEW (supersedes 0009)
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
    v_is_designated BOOLEAN := false;
    v_admin_override BOOLEAN := false;
    v_next_stage TEXT;
    v_new_status cash_advance_status := 'UNDER_REVIEW';
    v_step_order INT;
    v_prior UUID[];
    v_reason TEXT;
    v_skipped JSONB := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHENTICATED', 'message', 'You must be signed in to review cash advances.');
    END IF;

    SELECT * INTO v_advance FROM cash_advances WHERE id = p_advance_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'ADVANCE_NOT_FOUND', 'message', 'Cash advance not found.');
    END IF;

    IF v_advance.employee_id = v_user_id THEN
        RETURN jsonb_build_object('success', false, 'code', 'SELF_APPROVAL_FORBIDDEN', 'message', 'Self-approval of cash advances is strictly forbidden.');
    END IF;

    IF v_advance.status != 'UNDER_REVIEW' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Advance is not awaiting review. Current status: ' || v_advance.status::text);
    END IF;

    SELECT * INTO v_employee FROM employees WHERE id = v_advance.employee_id;

    v_step_order := CASE v_advance.current_approval_stage
        WHEN 'LINE_MANAGER_REVIEW' THEN 1 WHEN 'HOD_REVIEW' THEN 2
        WHEN 'SIVA_REVIEW' THEN 3 WHEN 'FINANCE_REVIEW' THEN 4 END;
    IF v_step_order IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STAGE', 'message', 'Advance is not in an approvable stage: ' || v_advance.current_approval_stage);
    END IF;

    v_is_designated := COALESCE(CASE v_advance.current_approval_stage
        WHEN 'LINE_MANAGER_REVIEW' THEN v_employee.line_manager_id = v_user_id
        WHEN 'HOD_REVIEW' THEN v_employee.hod_id = v_user_id
        WHEN 'SIVA_REVIEW' THEN has_role('MANAGEMENT')
        WHEN 'FINANCE_REVIEW' THEN has_role('FINANCE')
    END, false);

    IF NOT v_is_designated THEN
        IF has_role('ADMIN') THEN
            IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
                RETURN jsonb_build_object('success', false, 'code', 'ADMIN_OVERRIDE_REASON_REQUIRED',
                    'message', 'You are not the designated approver for this stage. An Admin override requires a reason.');
            END IF;
            v_admin_override := true;
        ELSE
            RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You are not authorized to review this cash advance at stage ' || v_advance.current_approval_stage);
        END IF;
    END IF;

    IF v_admin_override THEN
        PERFORM record_audit_log('ADMIN_APPROVAL_OVERRIDE', 'cash_advances', p_advance_id, to_jsonb(v_advance),
            jsonb_build_object('stage', v_advance.current_approval_stage, 'action', p_action, 'reason', trim(p_comments), 'admin_id', v_user_id));
    END IF;

    IF p_action = 'REJECT' THEN
        IF p_comments IS NULL OR length(trim(p_comments)) = 0 THEN
            RETURN jsonb_build_object('success', false, 'code', 'COMMENT_REQUIRED', 'message', 'Reason comments are mandatory when rejecting a cash advance.');
        END IF;

        UPDATE cash_advances
        SET status = 'REJECTED', current_approval_stage = 'REJECTED', updated_at = now()
        WHERE id = p_advance_id;

        INSERT INTO advance_approval_actions (advance_id, step_order, actor_id, action, previous_stage, new_stage, comments)
        VALUES (p_advance_id, v_step_order, v_user_id, 'REJECT', v_advance.current_approval_stage, 'REJECTED', p_comments);

        PERFORM record_audit_log('ADVANCE_REJECTED', 'cash_advances', p_advance_id, to_jsonb(v_advance),
            jsonb_build_object('status', 'REJECTED', 'stage', v_advance.current_approval_stage, 'comments', p_comments,
                'reviewer_id', v_user_id, 'admin_override', v_admin_override));

        RETURN jsonb_build_object('success', true, 'status', 'REJECTED', 'admin_override', v_admin_override);
    END IF;

    IF p_action = 'APPROVE' THEN
        IF EXISTS (
            SELECT 1 FROM advance_approval_actions
            WHERE advance_id = p_advance_id AND actor_id = v_user_id AND action = 'APPROVE'
        ) THEN
            RETURN jsonb_build_object('success', false, 'code', 'ALREADY_APPROVED_PREVIOUS_STAGE',
                'message', 'You have already approved this advance at an earlier approval stage.');
        END IF;

        SELECT array_agg(DISTINCT actor_id) || v_user_id INTO v_prior
        FROM advance_approval_actions WHERE advance_id = p_advance_id AND action = 'APPROVE';
        v_prior := COALESCE(v_prior, ARRAY[v_user_id]);

        v_next_stage := next_review_stage(v_advance.current_approval_stage);
        LOOP
            v_reason := approval_stage_should_escalate(v_next_stage, v_advance.employee_id, v_prior);
            EXIT WHEN v_reason IS NULL;
            v_skipped := v_skipped || jsonb_build_object('stage', v_next_stage, 'reason', v_reason);
            v_next_stage := next_review_stage(v_next_stage);
        END LOOP;
        IF v_next_stage = 'APPROVED' THEN
            v_new_status := 'APPROVED';
        END IF;

        UPDATE cash_advances
        SET current_approval_stage = v_next_stage,
            status = v_new_status,
            approved_by = CASE WHEN v_new_status = 'APPROVED' THEN v_user_id ELSE approved_by END,
            approved_at = CASE WHEN v_new_status = 'APPROVED' THEN now() ELSE approved_at END,
            updated_at = now()
        WHERE id = p_advance_id;

        INSERT INTO advance_approval_actions (advance_id, step_order, actor_id, action, previous_stage, new_stage, comments)
        VALUES (p_advance_id, v_step_order, v_user_id, 'APPROVE', v_advance.current_approval_stage, v_next_stage, p_comments);

        IF jsonb_array_length(v_skipped) > 0 THEN
            PERFORM record_audit_log('ADVANCE_STAGE_ESCALATED', 'cash_advances', p_advance_id, NULL,
                jsonb_build_object('from_stage', v_advance.current_approval_stage, 'to_stage', v_next_stage, 'skipped', v_skipped, 'actor_id', v_user_id));
        END IF;

        PERFORM record_audit_log('ADVANCE_APPROVED_STAGE', 'cash_advances', p_advance_id, to_jsonb(v_advance),
            jsonb_build_object('previous_stage', v_advance.current_approval_stage, 'new_stage', v_next_stage, 'status', v_new_status,
                'approved_by', v_user_id, 'admin_override', v_admin_override));

        RETURN jsonb_build_object(
            'success', true,
            'status', v_new_status,
            'current_stage', v_next_stage,
            'admin_override', v_admin_override,
            'escalated', v_skipped,
            'message', 'Advance approved at step ' || v_step_order::text || '. Advanced to ' || v_next_stage
        );
    END IF;

    RETURN jsonb_build_object('success', false, 'code', 'UNSUPPORTED_ACTION', 'message', 'Action must be APPROVE or REJECT.');
END;
$$;

REVOKE ALL ON FUNCTION process_approval_action(UUID, approval_action_type, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION process_approval_action(UUID, approval_action_type, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION review_cash_advance(UUID, approval_action_type, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION review_cash_advance(UUID, approval_action_type, TEXT) TO authenticated;
