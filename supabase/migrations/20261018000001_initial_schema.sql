-- ============================================================================
-- ASM Expense & Reimbursement Platform — Master Database Schema
-- Migration: 20261018000001_initial_schema.sql
-- PostgreSQL 15+ compatible with Supabase Auth & Storage
-- ============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- 1. ENUMS
-- ============================================================================
CREATE TYPE app_role AS ENUM (
    'EMPLOYEE',
    'LINE_MANAGER',
    'DEPARTMENT_MANAGER',
    'MANAGEMENT',
    'FINANCE',
    'ADMIN'
);

CREATE TYPE cash_advance_status AS ENUM (
    'DRAFT',
    'SUBMITTED',
    'UNDER_REVIEW',
    'APPROVED',
    'REJECTED',
    'PAID',
    'PARTIALLY_SETTLED',
    'SETTLED',
    'CANCELLED'
);

CREATE TYPE claim_status AS ENUM (
    'DRAFT',
    'SUBMITTED',
    'LINE_MANAGER_REVIEW',
    'HOD_REVIEW',
    'SIVA_REVIEW',
    'FINANCE_REVIEW',
    'APPROVED',
    'REIMBURSEMENT_PROCESSING',
    'PAID',
    'SETTLED',
    'REJECTED',
    'CORRECTION_REQUIRED',
    'CANCELLED'
);

CREATE TYPE reimbursement_status AS ENUM (
    'PENDING',
    'PROCESSING',
    'PAID',
    'CANCELLED'
);

CREATE TYPE approval_action_type AS ENUM (
    'APPROVE',
    'REJECT',
    'REQUEST_CORRECTION',
    'FORWARD'
);

CREATE TYPE approver_step_type AS ENUM (
    'LINE_MANAGER',
    'HOD',
    'SPECIFIC_EMPLOYEE',
    'ROLE'
);

-- ============================================================================
-- 2. IDENTITY & ORGANIZATION MASTER DOMAIN
-- ============================================================================

CREATE TABLE IF NOT EXISTS departments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(150) NOT NULL,
    hod_employee_id UUID, -- Foreign key added after employees table
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

-- Add circular foreign key for departments.hod_employee_id
ALTER TABLE departments 
ADD CONSTRAINT fk_departments_hod 
FOREIGN KEY (hod_employee_id) REFERENCES employees(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS employee_roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    role app_role NOT NULL,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    granted_by UUID REFERENCES employees(id),
    UNIQUE (employee_id, role)
);

-- ============================================================================
-- 3. CONFIGURATION, CURRENCIES & POLICY DOMAIN
-- ============================================================================

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
    max_limit_minor BIGINT, -- In minor units (fils/cents)
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

-- ============================================================================
-- 4. FINANCIAL & EXPENSE LEDGER DOMAIN
-- ============================================================================

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
    is_locked BOOLEAN NOT NULL DEFAULT false, -- Set true once included in submitted claim
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_no_receipt_reason CHECK (has_receipt = true OR (has_receipt = false AND no_receipt_reason IS NOT NULL AND length(trim(no_receipt_reason)) > 0))
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

-- ============================================================================
-- 5. WORKFLOW, NOTIFICATIONS & AUDIT DOMAIN
-- ============================================================================

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

-- ============================================================================
-- 6. INDEXES FOR PERFORMANCE & LOOKUPS
-- ============================================================================
CREATE INDEX IF NOT EXISTS idx_employees_department ON employees(department_id);
CREATE INDEX IF NOT EXISTS idx_employees_line_manager ON employees(line_manager_id);
CREATE INDEX IF NOT EXISTS idx_employees_hod ON employees(hod_id);
CREATE INDEX IF NOT EXISTS idx_employee_roles_role ON employee_roles(employee_id, role);

CREATE INDEX IF NOT EXISTS idx_expenses_employee ON expenses(employee_id);
CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(expense_date);
CREATE INDEX IF NOT EXISTS idx_expenses_category ON expenses(category_id);

CREATE INDEX IF NOT EXISTS idx_claims_employee ON expense_claims(employee_id);
CREATE INDEX IF NOT EXISTS idx_claims_status ON expense_claims(status);
CREATE INDEX IF NOT EXISTS idx_claims_date ON expense_claims(claim_date);

CREATE INDEX IF NOT EXISTS idx_cash_advances_employee ON cash_advances(employee_id);
CREATE INDEX IF NOT EXISTS idx_cash_advances_status ON cash_advances(status);

CREATE INDEX IF NOT EXISTS idx_approval_instances_claim ON approval_instances(claim_id);
CREATE INDEX IF NOT EXISTS idx_approval_actions_claim ON approval_actions(claim_id);

CREATE INDEX IF NOT EXISTS idx_notifications_recipient ON notifications(recipient_id, is_read);
CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON audit_logs(entity_type, entity_id);
