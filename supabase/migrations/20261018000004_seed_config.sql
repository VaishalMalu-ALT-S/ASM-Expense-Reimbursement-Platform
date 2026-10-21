-- ============================================================================
-- ASM Expense & Reimbursement Platform — Seed Master Configuration Data
-- Migration: 20261018000004_seed_config.sql
-- ============================================================================

-- 1. Base Currencies
INSERT INTO currencies (code, name, symbol, decimals, is_base, is_active) VALUES
('AED', 'United Arab Emirates Dirham', 'AED', 2, true, true),
('USD', 'United States Dollar', '$', 2, false, true),
('EUR', 'Euro', '€', 2, false, true)
ON CONFLICT (code) DO UPDATE SET is_active = true;

-- 2. Initial Configurable Exchange Rates
INSERT INTO exchange_rates (from_currency, to_currency, rate, effective_date, source) VALUES
('USD', 'AED', 3.672500, CURRENT_DATE, 'Central Bank of the UAE Fix'),
('EUR', 'AED', 3.985000, CURRENT_DATE, 'Central Bank of the UAE Fix'),
('AED', 'AED', 1.000000, CURRENT_DATE, 'Base')
ON CONFLICT (from_currency, to_currency, effective_date) DO UPDATE SET rate = EXCLUDED.rate;

-- 3. ASM Master Expense Categories
INSERT INTO expense_categories (code, name, description, requires_receipt, max_limit_minor, is_active) VALUES
('FOOD_DINING', 'Food & Dining', 'Business meals, client hospitality, per-diem sustenance', false, 100000, true),
('TRAVEL_AIRFARE', 'Travel & Airfare', 'Flight bookings, airport transfers, rail travel', true, 500000, true),
('HOTEL_LODGING', 'Hotel & Accommodation', 'Corporate hotel stays during official ASM travel', true, 500000, true),
('FUEL_MILEAGE', 'Fuel & Mileage', 'Official vehicle refueling and business mileage allowance', false, 50000, true),
('TAXI_RIDESHARE', 'Taxi & Rideshare', 'Careem, Uber, local taxi services for business transit', false, 30000, true),
('PARKING_TOLLS', 'Parking & Tolls', 'Salik tolls, airport and client location parking fees', false, 20000, true),
('COMMUNICATIONS', 'Telecommunications', 'International roaming, SIM packs for business trips', true, 50000, true),
('OFFICE_SUPPLIES', 'Office & Field Supplies', 'Consumables, tools, emergency marine spares', true, 200000, true),
('OTHER', 'Other Business Expenses', 'Incidental verified business expenses not categorized', true, 100000, true)
ON CONFLICT (code) DO NOTHING;

-- 4. ASM 20+ Master Departments
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
('CUSTOMER_SVC', 'Customer Service & Client Relations'),
('STRATEGY', 'Strategy & Corporate Growth'),
('AUTONOMOUS', 'Autonomous & Unmanned Vessels')
ON CONFLICT (code) DO NOTHING;

-- 5. Standard Designations
INSERT INTO designations (title, grade) VALUES
('Chief Executive Officer', 'EX-01'),
('Chief Operating Officer', 'EX-02'),
('Chief Financial Officer', 'EX-02'),
('Head of Department', 'M-01'),
('Operations Manager', 'M-02'),
('Finance Manager', 'M-02'),
('Senior Naval Architect', 'P-01'),
('Marine Project Engineer', 'P-02'),
('Procurement Specialist', 'P-03'),
('Senior Accountant', 'P-03'),
('Operations Coordinator', 'O-01'),
('Field Technician', 'O-02'),
('Executive Assistant', 'A-01');

-- 6. Configurable Policies & Business Limits
INSERT INTO policies (code, title, description, is_active) VALUES
('ASM_EXPENSE_POLICY_2026', 'ASM Corporate Expense & Travel Policy', 'Official expense reimbursement and cash advance regulations for Al Seer Marine employees.', true)
ON CONFLICT (code) DO NOTHING;

INSERT INTO policy_rules (policy_id, rule_key, rule_value, description, is_active)
SELECT 
    id, 
    'no_receipt_limit_aed', 
    '{"limit_minor": 50000, "currency": "AED", "description": "Expenses up to and including AED 500 may be claimed without receipt upon justification."}'::jsonb,
    'Maximum individual expense eligible for reimbursement without supporting receipt',
    true
FROM policies WHERE code = 'ASM_EXPENSE_POLICY_2026'
ON CONFLICT (rule_key) DO UPDATE SET rule_value = EXCLUDED.rule_value;

INSERT INTO policy_rules (policy_id, rule_key, rule_value, description, is_active)
SELECT 
    id, 
    'max_claim_limit_aed', 
    '{"limit_minor": 1000000, "currency": "AED", "description": "Maximum claim report ceiling before executive sign-off requirement."}'::jsonb,
    'Standard claim total cap per submission',
    true
FROM policies WHERE code = 'ASM_EXPENSE_POLICY_2026'
ON CONFLICT (rule_key) DO UPDATE SET rule_value = EXCLUDED.rule_value;

INSERT INTO policy_rules (policy_id, rule_key, rule_value, description, is_active)
SELECT 
    id, 
    'receipt_tolerance_aed', 
    '{"tolerance_minor": 0, "currency": "AED", "description": "Zero tolerance strict matching between bills and claimed amount."}'::jsonb,
    'Permitted variance between receipt totals and claimed expense breakup',
    true
FROM policies WHERE code = 'ASM_EXPENSE_POLICY_2026'
ON CONFLICT (rule_key) DO UPDATE SET rule_value = EXCLUDED.rule_value;

-- 7. Master Approval Workflow Configuration
INSERT INTO approval_workflows (name, description, is_default, is_active) VALUES
('ASM Standard 4-Tier Approval Chain', 'Employee -> Line Manager -> HOD -> Siva/Management -> Finance -> Paid', true, true);

INSERT INTO approval_workflow_steps (workflow_id, step_order, step_name, approver_type, target_role)
SELECT id, 1, 'Line Manager Verification', 'LINE_MANAGER'::approver_step_type, 'LINE_MANAGER'::app_role
FROM approval_workflows WHERE name = 'ASM Standard 4-Tier Approval Chain'
UNION ALL
SELECT id, 2, 'Department Manager / HOD Approval', 'HOD'::approver_step_type, 'DEPARTMENT_MANAGER'::app_role
FROM approval_workflows WHERE name = 'ASM Standard 4-Tier Approval Chain'
UNION ALL
SELECT id, 3, 'Management / Siva Final Authorization', 'ROLE'::approver_step_type, 'MANAGEMENT'::app_role
FROM approval_workflows WHERE name = 'ASM Standard 4-Tier Approval Chain'
UNION ALL
SELECT id, 4, 'Finance Settlement & Reimbursement', 'ROLE'::approver_step_type, 'FINANCE'::app_role
FROM approval_workflows WHERE name = 'ASM Standard 4-Tier Approval Chain';
