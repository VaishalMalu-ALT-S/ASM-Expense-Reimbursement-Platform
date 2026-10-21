-- ============================================================================
-- ASM Expense & Reimbursement — Master RLS Policies & Security Fix
-- Run this in your Supabase SQL Editor:
-- https://supabase.com/dashboard/project/vrnqemqzmklrjpssneng/sql/new
-- ============================================================================

-- 1. Helper Functions
CREATE OR REPLACE FUNCTION auth_employee_id() 
RETURNS UUID AS $$
  SELECT auth.uid();
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION has_role(role_name text) 
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM employee_roles 
    WHERE employee_id = auth.uid() 
      AND role::text = role_name
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'app_role') THEN
    EXECUTE '
      CREATE OR REPLACE FUNCTION has_role(role_name app_role) 
      RETURNS BOOLEAN AS $f$
        SELECT EXISTS (
          SELECT 1 FROM employee_roles 
          WHERE employee_id = auth.uid() 
            AND role = role_name
        );
      $f$ LANGUAGE sql STABLE SECURITY DEFINER;
    ';
  END IF;
END $$;

-- 2. Reference Data (Allow public read so categories and currencies load cleanly)
ALTER TABLE expense_categories ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Public read for active expense categories" ON expense_categories;
CREATE POLICY "Public read for active expense categories" ON expense_categories 
FOR SELECT TO public 
USING (true);

ALTER TABLE currencies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Public read for active currencies" ON currencies;
CREATE POLICY "Public read for active currencies" ON currencies 
FOR SELECT TO public 
USING (true);

ALTER TABLE exchange_rates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Public read for exchange rates" ON exchange_rates;
CREATE POLICY "Public read for exchange rates" ON exchange_rates 
FOR SELECT TO public 
USING (true);

ALTER TABLE departments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Employees read departments" ON departments;
CREATE POLICY "Employees read departments" ON departments 
FOR SELECT TO authenticated 
USING (true);

ALTER TABLE designations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Employees read designations" ON designations;
CREATE POLICY "Employees read designations" ON designations 
FOR SELECT TO authenticated 
USING (true);

-- 3. Employees & Roles
ALTER TABLE employees ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Employees read profile" ON employees;
CREATE POLICY "Employees read profile" ON employees 
FOR SELECT TO authenticated 
USING (true);

ALTER TABLE employee_roles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users read own roles" ON employee_roles;
CREATE POLICY "Users read own roles" ON employee_roles 
FOR SELECT TO authenticated 
USING (employee_id = auth.uid());

-- 4. Expenses (Full CRUD for own expenses)
ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Employees access own expenses" ON expenses;
DROP POLICY IF EXISTS "Employees create own expenses" ON expenses;
DROP POLICY IF EXISTS "Employees update own unlocked expenses" ON expenses;
DROP POLICY IF EXISTS "Employees delete own unlocked draft expenses" ON expenses;

CREATE POLICY "Employees access own expenses" ON expenses 
FOR SELECT TO authenticated 
USING (
    employee_id = auth.uid()
    OR has_role('LINE_MANAGER')
    OR has_role('DEPARTMENT_MANAGER')
    OR has_role('MANAGEMENT')
    OR has_role('FINANCE')
    OR has_role('ADMIN')
);

CREATE POLICY "Employees create own expenses" ON expenses 
FOR INSERT TO authenticated 
WITH CHECK (
    employee_id = auth.uid()
);

CREATE POLICY "Employees update own unlocked expenses" ON expenses 
FOR UPDATE TO authenticated 
USING (
    employee_id = auth.uid() AND is_locked = false
) 
WITH CHECK (
    employee_id = auth.uid() AND is_locked = false
);

CREATE POLICY "Employees delete own unlocked draft expenses" ON expenses 
FOR DELETE TO authenticated 
USING (
    employee_id = auth.uid() AND is_locked = false
);

-- 5. Expense Receipts & OCR Results
ALTER TABLE expense_receipts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Employees manage own expense receipts" ON expense_receipts;
CREATE POLICY "Employees manage own expense receipts" ON expense_receipts 
FOR ALL TO authenticated 
USING (uploaded_by = auth.uid())
WITH CHECK (uploaded_by = auth.uid());

ALTER TABLE expense_ocr_results ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Employees view expense ocr results" ON expense_ocr_results;
CREATE POLICY "Employees view expense ocr results" ON expense_ocr_results 
FOR ALL TO authenticated 
USING (true)
WITH CHECK (true);

-- 6. Expense Claims & Advances
ALTER TABLE expense_claims ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Claims visibility based on ownership & authorization" ON expense_claims;
DROP POLICY IF EXISTS "Employees insert own claims" ON expense_claims;
DROP POLICY IF EXISTS "Employees update own draft claims" ON expense_claims;

CREATE POLICY "Claims visibility based on ownership & authorization" ON expense_claims 
FOR SELECT TO authenticated 
USING (
    employee_id = auth.uid()
    OR has_role('LINE_MANAGER')
    OR has_role('DEPARTMENT_MANAGER')
    OR has_role('MANAGEMENT')
    OR has_role('FINANCE')
    OR has_role('ADMIN')
);

CREATE POLICY "Employees insert own claims" ON expense_claims 
FOR INSERT TO authenticated 
WITH CHECK (
    employee_id = auth.uid()
);

CREATE POLICY "Employees update own draft claims" ON expense_claims 
FOR UPDATE TO authenticated 
USING (
    employee_id = auth.uid() AND status IN ('DRAFT', 'CORRECTION_REQUIRED')
)
WITH CHECK (
    employee_id = auth.uid()
);

ALTER TABLE claim_expenses ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Claim expenses visibility" ON claim_expenses;
DROP POLICY IF EXISTS "Claim expenses insert" ON claim_expenses;
CREATE POLICY "Claim expenses visibility" ON claim_expenses 
FOR SELECT TO authenticated 
USING (true);
CREATE POLICY "Claim expenses insert" ON claim_expenses 
FOR INSERT TO authenticated 
WITH CHECK (true);

ALTER TABLE cash_advances ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Advances visibility" ON cash_advances;
DROP POLICY IF EXISTS "Employees insert advances" ON cash_advances;
CREATE POLICY "Advances visibility" ON cash_advances 
FOR SELECT TO authenticated 
USING (
    employee_id = auth.uid()
    OR has_role('LINE_MANAGER')
    OR has_role('FINANCE')
    OR has_role('ADMIN')
);
CREATE POLICY "Employees insert advances" ON cash_advances 
FOR INSERT TO authenticated 
WITH CHECK (employee_id = auth.uid());

-- 7. Audit Logs Trigger Access
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow authenticated insert audit logs" ON audit_logs;
CREATE POLICY "Allow authenticated insert audit logs" ON audit_logs 
FOR INSERT TO authenticated 
WITH CHECK (true);

DROP POLICY IF EXISTS "Users read own audit logs" ON audit_logs;
CREATE POLICY "Users read own audit logs" ON audit_logs 
FOR SELECT TO authenticated 
USING (actor_user_id = auth.uid());

-- 8. Storage Policies for receipts bucket
DROP POLICY IF EXISTS "Authenticated users can upload receipts" ON storage.objects;
CREATE POLICY "Authenticated users can upload receipts"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'receipts');

DROP POLICY IF EXISTS "Authenticated users can view receipts" ON storage.objects;
CREATE POLICY "Authenticated users can view receipts"
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'receipts');
