-- ============================================================================
-- Fix Reimbursements & Payments RLS Policies
-- Run this in your Supabase SQL Editor:
-- https://supabase.com/dashboard/project/vrnqemqzmklrjpssneng/sql/new
-- ============================================================================

-- 1. Reimbursements table visibility & management
ALTER TABLE reimbursements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Reimbursements visibility policy" ON reimbursements;
CREATE POLICY "Reimbursements visibility policy" ON reimbursements
FOR SELECT TO authenticated
USING (
    employee_id = auth.uid()
    OR has_role('FINANCE')
    OR has_role('ADMIN')
    OR has_role('MANAGEMENT')
);

DROP POLICY IF EXISTS "Finance manage reimbursements" ON reimbursements;
CREATE POLICY "Finance manage reimbursements" ON reimbursements
FOR ALL TO authenticated
USING (
    has_role('FINANCE') OR has_role('ADMIN')
)
WITH CHECK (
    has_role('FINANCE') OR has_role('ADMIN')
);

-- 2. Payments table visibility
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Payments visibility policy" ON payments;
CREATE POLICY "Payments visibility policy" ON payments
FOR SELECT TO authenticated
USING (
    has_role('FINANCE')
    OR has_role('ADMIN')
    OR EXISTS (
        SELECT 1 FROM reimbursements r
        WHERE r.id = payments.reimbursement_id
          AND r.employee_id = auth.uid()
    )
);

DROP POLICY IF EXISTS "Finance insert payments" ON payments;
CREATE POLICY "Finance insert payments" ON payments
FOR INSERT TO authenticated
WITH CHECK (
    has_role('FINANCE') OR has_role('ADMIN')
);
