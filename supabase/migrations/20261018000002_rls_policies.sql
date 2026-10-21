-- ============================================================================
-- ASM Expense & Reimbursement Platform — Row Level Security (RLS) Policies
-- Migration: 20261018000002_rls_policies.sql
-- ============================================================================

-- Helper functions for RLS checks
CREATE OR REPLACE FUNCTION auth_employee_id() 
RETURNS UUID AS $$
  SELECT auth.uid();
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION has_role(role_name app_role) 
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM employee_roles 
    WHERE employee_id = auth.uid() 
      AND role = role_name
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_manager_of(emp_id UUID) 
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM employees 
    WHERE id = emp_id 
      AND line_manager_id = auth.uid()
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION is_hod_of(emp_id UUID) 
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM employees emp
    JOIN departments dept ON emp.department_id = dept.id
    WHERE emp.id = emp_id 
      AND (emp.hod_id = auth.uid() OR dept.hod_employee_id = auth.uid())
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- Enable RLS across all tables
ALTER TABLE departments ENABLE ROW LEVEL SECURITY;
ALTER TABLE designations ENABLE ROW LEVEL SECURITY;
ALTER TABLE cost_centers ENABLE ROW LEVEL SECURITY;
ALTER TABLE employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE currencies ENABLE ROW LEVEL SECURITY;
ALTER TABLE exchange_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE policy_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_workflows ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_workflow_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE cash_advances ENABLE ROW LEVEL SECURITY;
ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_ocr_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE claim_expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE reimbursements ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_instances ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- 1. READ-ONLY REFERENCE DATA (Departments, Currencies, Policies, etc.)
-- ============================================================================
CREATE POLICY "Public read for active departments" ON departments FOR SELECT USING (true);
CREATE POLICY "Public read for active designations" ON designations FOR SELECT USING (true);
CREATE POLICY "Public read for active cost centers" ON cost_centers FOR SELECT USING (true);
CREATE POLICY "Public read for active currencies" ON currencies FOR SELECT USING (true);
CREATE POLICY "Public read for exchange rates" ON exchange_rates FOR SELECT USING (true);
CREATE POLICY "Public read for active expense categories" ON expense_categories FOR SELECT USING (true);
CREATE POLICY "Public read for policies and rules" ON policies FOR SELECT USING (true);
CREATE POLICY "Public read for policy rules" ON policy_rules FOR SELECT USING (true);
CREATE POLICY "Public read for active approval workflows" ON approval_workflows FOR SELECT USING (true);
CREATE POLICY "Public read for workflow steps" ON approval_workflow_steps FOR SELECT USING (true);

-- Admin write policies for configuration
CREATE POLICY "Admin write departments" ON departments FOR ALL USING (has_role('ADMIN'));
CREATE POLICY "Admin write designations" ON designations FOR ALL USING (has_role('ADMIN'));
CREATE POLICY "Admin write cost centers" ON cost_centers FOR ALL USING (has_role('ADMIN'));
CREATE POLICY "Admin write currencies" ON currencies FOR ALL USING (has_role('ADMIN'));
CREATE POLICY "Admin write exchange rates" ON exchange_rates FOR ALL USING (has_role('ADMIN') OR has_role('FINANCE'));
CREATE POLICY "Admin write expense categories" ON expense_categories FOR ALL USING (has_role('ADMIN') OR has_role('FINANCE'));
CREATE POLICY "Admin write policies" ON policies FOR ALL USING (has_role('ADMIN'));
CREATE POLICY "Admin write policy rules" ON policy_rules FOR ALL USING (has_role('ADMIN'));
CREATE POLICY "Admin write approval workflows" ON approval_workflows FOR ALL USING (has_role('ADMIN'));
CREATE POLICY "Admin write workflow steps" ON approval_workflow_steps FOR ALL USING (has_role('ADMIN'));

-- ============================================================================
-- 2. EMPLOYEES & ROLES
-- ============================================================================
CREATE POLICY "Employees can read own profile and team colleagues" ON employees FOR SELECT USING (
    id = auth_employee_id() 
    OR line_manager_id = auth_employee_id()
    OR is_hod_of(id)
    OR has_role('FINANCE')
    OR has_role('MANAGEMENT')
    OR has_role('ADMIN')
);

CREATE POLICY "Employees update own non-sensitive profile" ON employees FOR UPDATE USING (
    id = auth_employee_id()
) WITH CHECK (
    id = auth_employee_id()
);

CREATE POLICY "Admin full access employees" ON employees FOR ALL USING (has_role('ADMIN'));

CREATE POLICY "Users read own roles, Admin/Finance read all" ON employee_roles FOR SELECT USING (
    employee_id = auth_employee_id() 
    OR has_role('ADMIN') 
    OR has_role('FINANCE')
);
CREATE POLICY "Admin write employee roles" ON employee_roles FOR ALL USING (has_role('ADMIN'));

-- ============================================================================
-- 3. EXPENSES & RECEIPTS
-- ============================================================================
CREATE POLICY "Employees access own expenses" ON expenses FOR SELECT USING (
    employee_id = auth_employee_id()
    OR is_manager_of(employee_id)
    OR is_hod_of(employee_id)
    OR has_role('MANAGEMENT')
    OR has_role('FINANCE')
    OR has_role('ADMIN')
);

CREATE POLICY "Employees create own expenses" ON expenses FOR INSERT WITH CHECK (
    employee_id = auth_employee_id()
);

CREATE POLICY "Employees update own unlocked expenses" ON expenses FOR UPDATE USING (
    employee_id = auth_employee_id() AND is_locked = false
) WITH CHECK (
    employee_id = auth_employee_id() AND is_locked = false
);

CREATE POLICY "Employees delete own unlocked draft expenses" ON expenses FOR DELETE USING (
    employee_id = auth_employee_id() AND is_locked = false
);

-- Receipts & OCR
CREATE POLICY "Authorized view of receipts" ON expense_receipts FOR SELECT USING (
    uploaded_by = auth_employee_id()
    OR EXISTS (
        SELECT 1 FROM expenses e 
        WHERE e.id = expense_receipts.expense_id 
          AND (e.employee_id = auth_employee_id() OR is_manager_of(e.employee_id) OR is_hod_of(e.employee_id) OR has_role('FINANCE') OR has_role('ADMIN'))
    )
);

CREATE POLICY "Employees upload receipts for own expenses" ON expense_receipts FOR INSERT WITH CHECK (
    uploaded_by = auth_employee_id()
);

CREATE POLICY "Authorized view of OCR results" ON expense_ocr_results FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM expenses e 
        WHERE e.id = expense_ocr_results.expense_id 
          AND (e.employee_id = auth_employee_id() OR is_manager_of(e.employee_id) OR is_hod_of(e.employee_id) OR has_role('FINANCE') OR has_role('ADMIN'))
    )
);

-- ============================================================================
-- 4. CLAIMS & ADVANCES
-- ============================================================================
CREATE POLICY "Claims visibility based on ownership & authorization" ON expense_claims FOR SELECT USING (
    employee_id = auth_employee_id()
    OR is_manager_of(employee_id)
    OR is_hod_of(employee_id)
    OR has_role('MANAGEMENT')
    OR has_role('FINANCE')
    OR has_role('ADMIN')
);

CREATE POLICY "Employees insert own claims" ON expense_claims FOR INSERT WITH CHECK (
    employee_id = auth_employee_id()
);

CREATE POLICY "Employees update own draft or correction claims" ON expense_claims FOR UPDATE USING (
    employee_id = auth_employee_id() AND status IN ('DRAFT', 'CORRECTION_REQUIRED')
) WITH CHECK (
    employee_id = auth_employee_id() AND status IN ('DRAFT', 'CORRECTION_REQUIRED', 'SUBMITTED', 'CANCELLED')
);

-- Claim Expenses junction
CREATE POLICY "Claim expenses visibility" ON claim_expenses FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM expense_claims c 
        WHERE c.id = claim_expenses.claim_id 
          AND (c.employee_id = auth_employee_id() OR is_manager_of(c.employee_id) OR is_hod_of(c.employee_id) OR has_role('FINANCE') OR has_role('ADMIN'))
    )
);

CREATE POLICY "Claim expenses insert for own draft claim" ON claim_expenses FOR INSERT WITH CHECK (
    EXISTS (
        SELECT 1 FROM expense_claims c 
        WHERE c.id = claim_expenses.claim_id 
          AND c.employee_id = auth_employee_id() 
          AND c.status IN ('DRAFT', 'CORRECTION_REQUIRED')
    )
);

CREATE POLICY "Claim expenses delete for own draft claim" ON claim_expenses FOR DELETE USING (
    EXISTS (
        SELECT 1 FROM expense_claims c 
        WHERE c.id = claim_expenses.claim_id 
          AND c.employee_id = auth_employee_id() 
          AND c.status IN ('DRAFT', 'CORRECTION_REQUIRED')
    )
);

-- Cash Advances
CREATE POLICY "Advances visibility" ON cash_advances FOR SELECT USING (
    employee_id = auth_employee_id()
    OR is_manager_of(employee_id)
    OR is_hod_of(employee_id)
    OR has_role('MANAGEMENT')
    OR has_role('FINANCE')
    OR has_role('ADMIN')
);

CREATE POLICY "Employees insert own advances" ON cash_advances FOR INSERT WITH CHECK (
    employee_id = auth_employee_id()
);

CREATE POLICY "Employees update own draft advances" ON cash_advances FOR UPDATE USING (
    employee_id = auth_employee_id() AND status = 'DRAFT'
) WITH CHECK (
    employee_id = auth_employee_id() AND status IN ('DRAFT', 'SUBMITTED', 'CANCELLED')
);

-- ============================================================================
-- 5. APPROVALS, REIMBURSEMENTS & PAYMENTS
-- ============================================================================
CREATE POLICY "Approval instance visibility" ON approval_instances FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM expense_claims c 
        WHERE c.id = approval_instances.claim_id 
          AND (c.employee_id = auth_employee_id() OR is_manager_of(c.employee_id) OR is_hod_of(c.employee_id) OR has_role('FINANCE') OR has_role('ADMIN'))
    )
);

CREATE POLICY "Approval action visibility" ON approval_actions FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM expense_claims c 
        WHERE c.id = approval_actions.claim_id 
          AND (c.employee_id = auth_employee_id() OR is_manager_of(c.employee_id) OR is_hod_of(c.employee_id) OR has_role('FINANCE') OR has_role('ADMIN'))
    )
);

-- Reimbursements & Payments (Strict Finance / Admin / Claim Owner)
CREATE POLICY "Reimbursement visibility" ON reimbursements FOR SELECT USING (
    employee_id = auth_employee_id()
    OR has_role('FINANCE')
    OR has_role('ADMIN')
);

CREATE POLICY "Finance write reimbursements" ON reimbursements FOR ALL USING (
    has_role('FINANCE') OR has_role('ADMIN')
);

CREATE POLICY "Payment visibility" ON payments FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM reimbursements r 
        WHERE r.id = payments.reimbursement_id 
          AND (r.employee_id = auth_employee_id() OR has_role('FINANCE') OR has_role('ADMIN'))
    )
);

CREATE POLICY "Finance insert payments" ON payments FOR INSERT WITH CHECK (
    has_role('FINANCE') OR has_role('ADMIN')
);

-- ============================================================================
-- 6. NOTIFICATIONS & AUDIT LOGS
-- ============================================================================
CREATE POLICY "Employees view own notifications" ON notifications FOR SELECT USING (
    recipient_id = auth_employee_id()
);

CREATE POLICY "Employees update own notifications read state" ON notifications FOR UPDATE USING (
    recipient_id = auth_employee_id()
) WITH CHECK (
    recipient_id = auth_employee_id()
);

CREATE POLICY "Audit logs read by Admin and Finance only" ON audit_logs FOR SELECT USING (
    has_role('ADMIN') OR has_role('FINANCE')
);
-- Direct insert/update/delete to audit_logs is prevented for users; only security definer triggers or service role can write.
