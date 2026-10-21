-- ============================================================================
-- ASM Expense & Reimbursement Platform — Master Consolidated Database Setup
-- Run this in your Supabase SQL Editor:
-- https://supabase.com/dashboard/project/vrnqemqzmklrjpssneng/sql/new
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1. ENUMS
DO $$ BEGIN
    CREATE TYPE app_role AS ENUM (
        'EMPLOYEE', 'LINE_MANAGER', 'DEPARTMENT_MANAGER', 'MANAGEMENT', 'FINANCE', 'ADMIN'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE cash_advance_status AS ENUM (
        'DRAFT', 'SUBMITTED', 'UNDER_REVIEW', 'APPROVED', 'REJECTED', 'PAID', 'PARTIALLY_SETTLED', 'SETTLED', 'CANCELLED'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE claim_status AS ENUM (
        'DRAFT', 'SUBMITTED', 'LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW', 'APPROVED', 'REIMBURSEMENT_PROCESSING', 'PAID', 'SETTLED', 'REJECTED', 'CORRECTION_REQUIRED', 'CANCELLED'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE reimbursement_status AS ENUM (
        'PENDING', 'PROCESSING', 'PAID', 'CANCELLED'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE approval_action_type AS ENUM (
        'APPROVE', 'REJECT', 'REQUEST_CORRECTION', 'FORWARD'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE approver_step_type AS ENUM (
        'LINE_MANAGER', 'HOD', 'SPECIFIC_EMPLOYEE', 'ROLE'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- 2. MASTER RELATIONAL TABLES
CREATE TABLE IF NOT EXISTS departments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(150) NOT NULL,
    hod_employee_id UUID,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS designations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(150) NOT NULL,
    grade VARCHAR(50),
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cost_centers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(150) NOT NULL,
    department_id UUID REFERENCES departments(id) ON DELETE SET NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS employees (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    employee_code VARCHAR(50) UNIQUE NOT NULL,
    full_name VARCHAR(200) NOT NULL,
    email VARCHAR(200) UNIQUE NOT NULL,
    phone VARCHAR(50),
    department_id UUID REFERENCES departments(id) ON DELETE RESTRICT,
    designation_id UUID REFERENCES designations(id) ON DELETE SET NULL,
    line_manager_id UUID REFERENCES employees(id) ON DELETE SET NULL,
    hod_id UUID REFERENCES employees(id) ON DELETE SET NULL,
    cost_center_id UUID REFERENCES cost_centers(id) ON DELETE SET NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    joining_date DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DO $$ BEGIN
    ALTER TABLE departments 
    ADD CONSTRAINT fk_departments_hod 
    FOREIGN KEY (hod_employee_id) REFERENCES employees(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN null; END $$;

CREATE TABLE IF NOT EXISTS employee_roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    role app_role NOT NULL,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    granted_by UUID REFERENCES employees(id),
    UNIQUE (employee_id, role)
);

CREATE TABLE IF NOT EXISTS currencies (
    code CHAR(3) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    symbol VARCHAR(10) NOT NULL,
    decimals INT NOT NULL DEFAULT 2,
    is_base BOOLEAN NOT NULL DEFAULT false,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS exchange_rates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_currency CHAR(3) NOT NULL REFERENCES currencies(code),
    to_currency CHAR(3) NOT NULL REFERENCES currencies(code),
    rate NUMERIC(18, 6) NOT NULL CHECK (rate > 0),
    effective_date DATE NOT NULL,
    source VARCHAR(100) NOT NULL DEFAULT 'ASM Finance Default',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (from_currency, to_currency, effective_date)
);

CREATE TABLE IF NOT EXISTS expense_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(150) NOT NULL,
    description TEXT,
    requires_receipt BOOLEAN NOT NULL DEFAULT true,
    max_limit_minor BIGINT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code VARCHAR(50) UNIQUE NOT NULL,
    title VARCHAR(200) NOT NULL,
    description TEXT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS policy_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id UUID NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
    rule_key VARCHAR(100) UNIQUE NOT NULL,
    rule_value JSONB NOT NULL,
    description TEXT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS approval_workflows (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(150) NOT NULL,
    description TEXT,
    is_default BOOLEAN NOT NULL DEFAULT false,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS approval_workflow_steps (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workflow_id UUID NOT NULL REFERENCES approval_workflows(id) ON DELETE CASCADE,
    step_order INT NOT NULL,
    step_name VARCHAR(100) NOT NULL,
    approver_type approver_step_type NOT NULL,
    target_role app_role,
    target_employee_id UUID REFERENCES employees(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(workflow_id, step_order)
);

CREATE TABLE IF NOT EXISTS cash_advances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    advance_number VARCHAR(50) UNIQUE NOT NULL,
    employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
    currency_code CHAR(3) NOT NULL REFERENCES currencies(code),
    exchange_rate NUMERIC(18, 6) NOT NULL DEFAULT 1.0,
    aed_amount_minor BIGINT NOT NULL CHECK (aed_amount_minor > 0),
    purpose TEXT NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    status cash_advance_status NOT NULL DEFAULT 'DRAFT',
    reconciled_amount_minor BIGINT NOT NULL DEFAULT 0,
    approved_by UUID REFERENCES employees(id),
    approved_at TIMESTAMPTZ,
    paid_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_advance_dates CHECK (end_date >= start_date)
);

CREATE TABLE IF NOT EXISTS expenses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    category_id UUID NOT NULL REFERENCES expense_categories(id) ON DELETE RESTRICT,
    amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
    currency_code CHAR(3) NOT NULL REFERENCES currencies(code),
    exchange_rate NUMERIC(18, 6) NOT NULL DEFAULT 1.0,
    aed_amount_minor BIGINT NOT NULL CHECK (aed_amount_minor > 0),
    expense_date DATE NOT NULL,
    vendor VARCHAR(200) NOT NULL,
    invoice_number VARCHAR(100),
    tax_amount_minor BIGINT NOT NULL DEFAULT 0,
    description TEXT NOT NULL,
    has_receipt BOOLEAN NOT NULL DEFAULT true,
    no_receipt_reason TEXT,
    is_locked BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS expense_receipts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    expense_id UUID NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
    storage_path VARCHAR(500) NOT NULL,
    original_file_name VARCHAR(255) NOT NULL,
    file_size_bytes INT NOT NULL CHECK (file_size_bytes > 0),
    mime_type VARCHAR(100) NOT NULL,
    uploaded_by UUID NOT NULL REFERENCES employees(id),
    uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS expense_ocr_results (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    expense_id UUID NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
    receipt_id UUID REFERENCES expense_receipts(id) ON DELETE SET NULL,
    raw_ocr_response JSONB,
    extracted_vendor VARCHAR(200),
    extracted_invoice_number VARCHAR(100),
    extracted_date DATE,
    extracted_total_minor BIGINT,
    extracted_tax_minor BIGINT,
    extracted_currency CHAR(3) REFERENCES currencies(code),
    confidence_score NUMERIC(5, 4),
    is_verified_by_user BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS expense_claims (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_number VARCHAR(50) UNIQUE NOT NULL,
    employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    title VARCHAR(200) NOT NULL,
    purpose TEXT NOT NULL,
    claim_date DATE NOT NULL DEFAULT CURRENT_DATE,
    cash_advance_id UUID REFERENCES cash_advances(id) ON DELETE SET NULL,
    advance_applied_minor BIGINT NOT NULL DEFAULT 0,
    total_expense_minor BIGINT NOT NULL DEFAULT 0,
    net_reimbursement_minor BIGINT NOT NULL DEFAULT 0,
    status claim_status NOT NULL DEFAULT 'DRAFT',
    validation_status VARCHAR(50) NOT NULL DEFAULT 'PENDING',
    validation_notes TEXT,
    submitted_at TIMESTAMPTZ,
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS claim_expenses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id UUID NOT NULL REFERENCES expense_claims(id) ON DELETE CASCADE,
    expense_id UUID NOT NULL REFERENCES expenses(id) ON DELETE RESTRICT,
    added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (claim_id, expense_id)
);

CREATE TABLE IF NOT EXISTS reimbursements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id UUID UNIQUE NOT NULL REFERENCES expense_claims(id) ON DELETE RESTRICT,
    employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
    amount_minor BIGINT NOT NULL CHECK (amount_minor >= 0),
    currency_code CHAR(3) NOT NULL REFERENCES currencies(code),
    aed_amount_minor BIGINT NOT NULL CHECK (aed_amount_minor >= 0),
    status reimbursement_status NOT NULL DEFAULT 'PENDING',
    processed_by UUID REFERENCES employees(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reimbursement_id UUID NOT NULL REFERENCES reimbursements(id) ON DELETE RESTRICT,
    payment_reference VARCHAR(100) UNIQUE NOT NULL,
    idempotency_key VARCHAR(100) UNIQUE NOT NULL,
    payment_method VARCHAR(50) NOT NULL DEFAULT 'BANK_TRANSFER',
    paid_amount_minor BIGINT NOT NULL CHECK (paid_amount_minor > 0),
    payment_date DATE NOT NULL,
    recorded_by UUID NOT NULL REFERENCES employees(id),
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS approval_instances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id UUID NOT NULL REFERENCES expense_claims(id) ON DELETE CASCADE,
    current_step_order INT NOT NULL DEFAULT 1,
    current_approver_id UUID REFERENCES employees(id),
    current_approver_role app_role,
    status VARCHAR(50) NOT NULL DEFAULT 'IN_PROGRESS',
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS approval_actions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    approval_instance_id UUID NOT NULL REFERENCES approval_instances(id) ON DELETE CASCADE,
    claim_id UUID NOT NULL REFERENCES expense_claims(id) ON DELETE CASCADE,
    step_order INT NOT NULL,
    actor_id UUID NOT NULL REFERENCES employees(id),
    action approval_action_type NOT NULL,
    previous_status claim_status NOT NULL,
    new_status claim_status NOT NULL,
    comments TEXT,
    action_timestamp TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_id UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    title VARCHAR(200) NOT NULL,
    body TEXT NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    entity_type VARCHAR(50) NOT NULL,
    entity_id UUID NOT NULL,
    is_read BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    actor_role VARCHAR(50),
    action VARCHAR(100) NOT NULL,
    entity_type VARCHAR(50) NOT NULL,
    entity_id UUID NOT NULL,
    old_values JSONB,
    new_values JSONB,
    ip_address VARCHAR(45),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. STORAGE BUCKET FOR RECEIPTS
INSERT INTO storage.buckets (id, name, public)
VALUES ('receipts', 'receipts', false)
ON CONFLICT (id) DO NOTHING;

-- 4. SEED CONFIGURATION DATA
INSERT INTO currencies (code, name, symbol, decimals, is_base, is_active) VALUES
('AED', 'United Arab Emirates Dirham', 'AED', 2, true, true),
('USD', 'United States Dollar', '$', 2, false, true),
('EUR', 'Euro', '€', 2, false, true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO exchange_rates (from_currency, to_currency, rate, effective_date, source) VALUES
('USD', 'AED', 3.672500, CURRENT_DATE, 'Central Bank of the UAE Fix'),
('EUR', 'AED', 3.985000, CURRENT_DATE, 'Central Bank of the UAE Fix'),
('AED', 'AED', 1.000000, CURRENT_DATE, 'Base')
ON CONFLICT (from_currency, to_currency, effective_date) DO NOTHING;

INSERT INTO expense_categories (code, name, description, requires_receipt, max_limit_minor, is_active) VALUES
('FOOD_DINING', 'Food & Dining', 'Business meals, client hospitality', false, 100000, true),
('TRAVEL_AIRFARE', 'Travel & Airfare', 'Flight bookings, transfers', true, 500000, true),
('HOTEL_LODGING', 'Hotel & Accommodation', 'Corporate hotel stays', true, 500000, true),
('FUEL_MILEAGE', 'Fuel & Mileage', 'Official vehicle refueling', false, 50000, true),
('TAXI_RIDESHARE', 'Taxi & Rideshare', 'Careem, Uber, taxi services', false, 30000, true),
('PARKING_TOLLS', 'Parking & Tolls', 'Salik tolls, parking fees', false, 20000, true),
('COMMUNICATIONS', 'Telecommunications', 'Roaming, SIM packs', true, 50000, true),
('OFFICE_SUPPLIES', 'Office & Supplies', 'Consumables, marine spares', true, 200000, true),
('OTHER', 'Other Expenses', 'Verified business expenses', true, 100000, true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO departments (code, name) VALUES
('EXEC_MGMT', 'Executive Management'),
('FINANCE', 'Finance & Accounting'),
('PROCUREMENT', 'Procurement & Supply Chain'),
('LEGAL', 'Legal & Compliance'),
('YACHTS', 'Yachts Commercial & Charter'),
('BOAT_BUILDING', 'Boat Building & Composites'),
('SALES_MKTG', 'Sales & Business Development'),
('HR', 'Human Resources & Talent'),
('IT', 'Information Technology & Systems'),
('OPERATIONS', 'Marine Operations & Fleet'),
('TECH_SERVICES', 'Technical & Engineering Services'),
('PROJECTS', 'Marine Projects & Refit'),
('ADMIN', 'General Administration'),
('HSE', 'Health, Safety & Environment'),
('MAINTENANCE', 'Yard & Vessel Maintenance'),
('LOGISTICS', 'Logistics & Freight Transport'),
('WAREHOUSE', 'Warehouse & Material Stores'),
('CUSTOMER_SVC', 'Customer Service & Relations'),
('STRATEGY', 'Strategy & Growth'),
('AUTONOMOUS', 'Autonomous & Unmanned Vessels')
ON CONFLICT (code) DO NOTHING;

INSERT INTO policies (code, title, description, is_active) VALUES
('ASM_EXPENSE_POLICY_2026', 'ASM Corporate Expense Policy', 'Official expense reimbursement and advance regulations.', true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO policy_rules (policy_id, rule_key, rule_value, description, is_active)
SELECT id, 'no_receipt_limit_aed', '{"limit_minor": 50000, "currency": "AED"}'::jsonb, 'No-receipt limit (AED 500)', true
FROM policies WHERE code = 'ASM_EXPENSE_POLICY_2026'
ON CONFLICT (rule_key) DO NOTHING;

INSERT INTO policy_rules (policy_id, rule_key, rule_value, description, is_active)
SELECT id, 'max_claim_limit_aed', '{"limit_minor": 1000000, "currency": "AED"}'::jsonb, 'Max claim cap (AED 10,000)', true
FROM policies WHERE code = 'ASM_EXPENSE_POLICY_2026'
ON CONFLICT (rule_key) DO NOTHING;

-- 5. SERVER-SIDE DETERMINISTIC FUNCTIONS
CREATE OR REPLACE FUNCTION recalculate_claim_totals(p_claim_id UUID)
RETURNS VOID AS $$
DECLARE
    v_total_expense_minor BIGINT := 0;
    v_advance_applied_minor BIGINT := 0;
    v_net_reimbursement_minor BIGINT := 0;
    v_advance_id UUID;
    v_advance_balance BIGINT := 0;
BEGIN
    SELECT COALESCE(SUM(e.aed_amount_minor), 0)
    INTO v_total_expense_minor
    FROM claim_expenses ce
    JOIN expenses e ON ce.expense_id = e.id
    WHERE ce.claim_id = p_claim_id;

    SELECT cash_advance_id INTO v_advance_id
    FROM expense_claims WHERE id = p_claim_id;

    IF v_advance_id IS NOT NULL THEN
        SELECT (aed_amount_minor - reconciled_amount_minor)
        INTO v_advance_balance
        FROM cash_advances WHERE id = v_advance_id;

        IF v_advance_balance < 0 THEN v_advance_balance := 0; END IF;

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

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

    PERFORM recalculate_claim_totals(p_claim_id);
    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id;

    IF v_claim.total_expense_minor <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'EMPTY_CLAIM', 'message', 'Claim must contain at least one expense.');
    END IF;

    SELECT (rule_value->>'limit_minor')::BIGINT INTO v_no_receipt_limit 
    FROM policy_rules WHERE rule_key = 'no_receipt_limit_aed';
    IF v_no_receipt_limit IS NULL THEN v_no_receipt_limit := 50000; END IF;

    SELECT (rule_value->>'limit_minor')::BIGINT INTO v_max_claim_limit 
    FROM policy_rules WHERE rule_key = 'max_claim_limit_aed';
    IF v_max_claim_limit IS NULL THEN v_max_claim_limit := 1000000; END IF;

    IF v_claim.total_expense_minor > v_max_claim_limit THEN
        RETURN jsonb_build_object(
            'success', false, 'code', 'MAX_CLAIM_LIMIT_EXCEEDED', 
            'message', 'Total claim exceeds AED ' || (v_max_claim_limit / 100)::text
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
            'success', false, 'code', 'RECEIPT_REQUIRED',
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

    UPDATE expenses SET is_locked = true WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id);

    UPDATE expense_claims
    SET status = v_next_status, validation_status = 'PASSED', submitted_at = now(), updated_at = now()
    WHERE id = p_claim_id;

    INSERT INTO approval_instances (claim_id, current_step_order, current_approver_id, current_approver_role, status, started_at)
    VALUES (p_claim_id, 1, v_first_approver_id, 'LINE_MANAGER', 'IN_PROGRESS', now())
    RETURNING id INTO v_instance_id;

    RETURN jsonb_build_object('success', true, 'code', 'CLAIM_SUBMITTED', 'status', v_next_status);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
BEGIN
    SELECT * INTO v_claim FROM expense_claims WHERE id = p_claim_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CLAIM_NOT_FOUND', 'message', 'Claim not found.');
    END IF;

    IF v_claim.employee_id = v_user_id THEN
        RETURN jsonb_build_object('success', false, 'code', 'SELF_APPROVAL_FORBIDDEN', 'message', 'Self-approval is forbidden.');
    END IF;

    SELECT * INTO v_employee FROM employees WHERE id = v_claim.employee_id;
    SELECT * INTO v_instance FROM approval_instances WHERE claim_id = p_claim_id AND status = 'IN_PROGRESS' ORDER BY started_at DESC LIMIT 1;

    IF p_action = 'REJECT' THEN
        UPDATE expense_claims SET status = 'REJECTED', updated_at = now() WHERE id = p_claim_id;
        UPDATE approval_instances SET status = 'REJECTED', completed_at = now() WHERE id = v_instance.id;
        UPDATE expenses SET is_locked = false WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id);
        RETURN jsonb_build_object('success', true, 'status', 'REJECTED');
    END IF;

    IF p_action = 'REQUEST_CORRECTION' THEN
        UPDATE expense_claims SET status = 'CORRECTION_REQUIRED', validation_notes = p_comments, updated_at = now() WHERE id = p_claim_id;
        UPDATE approval_instances SET status = 'CORRECTION_REQUIRED' WHERE id = v_instance.id;
        UPDATE expenses SET is_locked = false WHERE id IN (SELECT expense_id FROM claim_expenses WHERE claim_id = p_claim_id);
        RETURN jsonb_build_object('success', true, 'status', 'CORRECTION_REQUIRED');
    END IF;

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

        IF v_next_status = 'APPROVED' THEN
            UPDATE expense_claims SET status = 'APPROVED', approved_at = now(), updated_at = now() WHERE id = p_claim_id;
            UPDATE approval_instances SET status = 'APPROVED', completed_at = now() WHERE id = v_instance.id;

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
                        WHEN (reconciled_amount_minor + v_claim.advance_applied_minor) >= aed_amount_minor THEN 'SETTLED'::cash_advance_status
                        ELSE 'PARTIALLY_SETTLED'::cash_advance_status
                    END,
                    updated_at = now()
                WHERE id = v_claim.cash_advance_id;
            END IF;
        ELSE
            UPDATE expense_claims SET status = v_next_status, updated_at = now() WHERE id = p_claim_id;
            UPDATE approval_instances 
            SET current_step_order = current_step_order + 1,
                current_approver_id = v_next_approver,
                current_approver_role = v_next_role
            WHERE id = v_instance.id;
        END IF;

        RETURN jsonb_build_object('success', true, 'status', v_next_status);
    END IF;

    RETURN jsonb_build_object('success', false, 'code', 'UNSUPPORTED_ACTION', 'message', 'Action not supported.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
    SELECT id INTO v_payment_id FROM payments WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object('success', true, 'code', 'IDEMPOTENT_SUCCESS', 'payment_id', v_payment_id);
    END IF;

    SELECT * INTO v_reimb FROM reimbursements WHERE id = p_reimbursement_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Reimbursement not found.');
    END IF;

    INSERT INTO payments (
        reimbursement_id, payment_reference, idempotency_key, payment_method, paid_amount_minor, payment_date, recorded_by, notes
    ) VALUES (
        p_reimbursement_id, p_payment_reference, p_idempotency_key, p_payment_method, v_reimb.amount_minor, CURRENT_DATE, v_user_id, p_notes
    ) RETURNING id INTO v_payment_id;

    UPDATE reimbursements SET status = 'PAID', processed_by = v_user_id, updated_at = now() WHERE id = p_reimbursement_id;
    UPDATE expense_claims SET status = 'PAID', updated_at = now() WHERE id = v_reimb.claim_id;

    RETURN jsonb_build_object('success', true, 'code', 'PAYMENT_RECORDED', 'payment_id', v_payment_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
