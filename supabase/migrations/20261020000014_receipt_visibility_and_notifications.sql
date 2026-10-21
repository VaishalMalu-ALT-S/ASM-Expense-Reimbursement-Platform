-- ============================================================================
-- ASM Expense & Reimbursement Platform: Receipt Visibility & Manager Notifications Fix
-- Migration: 20261020000014_receipt_visibility_and_notifications.sql
-- ============================================================================

-- 1. EXPENSE RECEIPTS RLS POLICY
-- Approvers and authenticated employees must be able to view receipts attached
-- to visible claims and expenses.
ALTER TABLE expense_receipts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Employees manage own expense receipts" ON expense_receipts;
DROP POLICY IF EXISTS "Employees and approvers view expense receipts" ON expense_receipts;
DROP POLICY IF EXISTS "Employees insert own expense receipts" ON expense_receipts;
DROP POLICY IF EXISTS "Employees update own expense receipts" ON expense_receipts;
DROP POLICY IF EXISTS "Employees delete own expense receipts" ON expense_receipts;

CREATE POLICY "Employees and approvers view expense receipts" ON expense_receipts 
FOR SELECT TO authenticated 
USING (true);

CREATE POLICY "Employees insert own expense receipts" ON expense_receipts 
FOR INSERT TO authenticated 
WITH CHECK (uploaded_by = auth.uid());

CREATE POLICY "Employees update own expense receipts" ON expense_receipts 
FOR UPDATE TO authenticated 
USING (uploaded_by = auth.uid())
WITH CHECK (uploaded_by = auth.uid());

CREATE POLICY "Employees delete own expense receipts" ON expense_receipts 
FOR DELETE TO authenticated 
USING (uploaded_by = auth.uid());

-- 2. NOTIFICATIONS TRIGGER ON CLAIM SUBMISSION AND STATUS CHANGES
-- Must trigger on INSERT (new submission directly into LINE_MANAGER_REVIEW)
-- as well as UPDATE of status across workflow stages.
CREATE OR REPLACE FUNCTION notify_claim_transition_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_ref TEXT := 'Claim #' || NEW.claim_number;
    v_amount TEXT := 'AED ' || to_char(NEW.total_expense_minor / 100.0, 'FM999,999,990.00');
    v_approver UUID;
    v_stage_label TEXT;
    v_emp_name TEXT;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;

    SELECT full_name INTO v_emp_name FROM employees WHERE id = NEW.employee_id;

    IF NEW.status::text IN ('LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW') THEN
        v_stage_label := CASE NEW.status::text
            WHEN 'LINE_MANAGER_REVIEW' THEN 'Line Manager'
            WHEN 'HOD_REVIEW' THEN 'Head of Department'
            WHEN 'SIVA_REVIEW' THEN 'Management'
            ELSE 'Finance' END;
        FOR v_approver IN SELECT * FROM stage_approver_ids(NEW.employee_id, NEW.status::text) LOOP
            PERFORM notify_employee(v_approver, 'New Claim Awaiting Your Approval',
                COALESCE(v_emp_name, 'An employee') || ' submitted ' || v_ref || ' (' || NEW.title || ', ' || v_amount || ') for ' || v_stage_label || ' review.',
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
AFTER INSERT OR UPDATE OF status ON expense_claims
FOR EACH ROW EXECUTE FUNCTION notify_claim_transition_trigger();
