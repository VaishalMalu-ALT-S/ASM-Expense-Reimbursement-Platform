# ASM Expense & Reimbursement Platform — Master System Architecture Plan

**Organization:** Al Seer Marine (ASM)  
**Document:** Master System Architecture Plan & Technical Blueprint  
**Standard:** Production-Grade Enterprise Platform  
**Target Architecture:** Flutter (Android/Mobile First) + Supabase (PostgreSQL, Storage, Auth, Edge Functions) + GroqCloud AI / Unlimited-OCR Backend Workers  

---

## 1. Executive Summary & Architectural Invariants

The ASM Expense & Reimbursement Platform is a mission-critical financial system managing employee travel, petty cash advances, business expenses, receipt OCR, claim reconciliation, hierarchical approval routing, and Finance settlement.

### Non-Negotiable Invariants:
1. **Never Trust the Client:** The Flutter client is an untrusted presentation layer. Zero business rule, role enforcement, status transition, or financial calculation is permitted solely on the client.
2. **Deterministic Financial Math:** Financial values use **integer minor units** (e.g., AED `100.50` = `10050 fils`) and strictly deterministic database/backend calculations. AI or floating-point arithmetic is prohibited for financial sums.
3. **No-Emoji & Corporate Enterprise Aesthetics:** Professional enterprise UI strictly adhering to ASM corporate styling—no emojis, no robot icons, no decorative gradients, and no fake demo data.
4. **Configurable Policy Engine:** Limits (e.g., `no_receipt_limit = 500 AED`, `max_claim_limit = 10000 AED`), approval chains, and currencies are dynamic database-driven configurations, never hardcoded in Dart.
5. **Least Privilege & Total Auditability:** Multi-tenant/scope Row Level Security (RLS) on all database tables and private storage buckets. Every state transition and financial action creates an immutable audit log entry.
6. **No Secret Leaks:** Supabase service-role keys, Groq API keys, and OCR credentials reside strictly inside backend Edge Functions/server environments.

---

## 2. Comparative Analysis & Reconciliation of Master Specs

Both `ASM_EXPENSE_MASTER_DEVELOPMENT_SPEC.md` and `ASM_DETAILED_SYSTEM_ARCHITECTURE.md` have been fully cross-referenced:
- **Approval Chain:** Employee → Line Manager → Department Manager / HOD → Siva / Management → Finance → Reimbursement / Paid.
- **Advance Reconciliation:** 
  - If Expenses < Advance: Balance owed recorded as outstanding settlement.
  - If Expenses > Advance: Incremental reimbursement approved and queued for payment.
- **Validation Engine:** Strict validation of individual expenses, bill matching, and receipt reconciliation against total claim amount. Mismatches prevent final submission unless allowed by configured policy tolerances.
- **Unconfirmed Rules Configured as Database Policies:**
  - `no_receipt_limit_aed`: Configured default `500.00` AED.
  - `max_claim_limit_aed`: Configured default `10000.00` AED (scoped dynamically to individual claim or expense).
  - `receipt_tolerance_aed`: Configured default `0.00` AED (exact matching).

---

## 3. Normalized Database Schema (PostgreSQL 15+)

The database is structured into 4 core functional domains:
1. **Identity & Org Master:** `departments`, `designations`, `cost_centers`, `employees`, `employee_roles`.
2. **System & Financial Policy Configuration:** `currencies`, `exchange_rates`, `expense_categories`, `policies`, `policy_rules`, `approval_workflows`, `approval_workflow_steps`.
3. **Core Financial & Expense Ledger:** `cash_advances`, `expenses`, `expense_receipts`, `expense_ocr_results`, `expense_claims`, `claim_expenses`, `reimbursements`, `payments`.
4. **Workflow, Governance & Audit:** `approval_instances`, `approval_actions`, `notifications`, `audit_logs`.

*(Full SQL DDL is provided in `supabase/migrations/20261018000001_initial_schema.sql`)*

---

## 4. State Machine & Transition Rules

### 4.1 Claim State Machine
```text
[ DRAFT ]
   │
   ▼ (validate_claim)
[ SUBMITTED ]
   │
   ▼
[ LINE_MANAGER_REVIEW ] ──(request_correction)──► [ CORRECTION_REQUIRED ]
   │                                                         │
   ▼ (approve)                                               ▼ (resubmit)
[ HOD_REVIEW ] ──────────(request_correction)────────► [ LINE_MANAGER_REVIEW ]
   │
   ▼ (approve)
[ SIVA_REVIEW ] ─────────(request_correction)────────► [ LINE_MANAGER_REVIEW ]
   │
   ▼ (approve)
[ FINANCE_REVIEW ] ──────(request_correction)────────► [ LINE_MANAGER_REVIEW ]
   │
   ▼ (finance_approve)
[ APPROVED ]
   │
   ▼ (initiate_payment)
[ REIMBURSEMENT_PROCESSING ]
   │
   ▼ (record_payment)
[ PAID ] ──► [ SETTLED ]

* Note: At any review step, an authorized reviewer can transition to [ REJECTED ] with mandatory reason.
* At DRAFT or SUBMITTED, the employee can transition to [ CANCELLED ].
```

### 4.2 Cash Advance State Machine
```text
[ DRAFT ] ──► [ SUBMITTED ] ──► [ UNDER_REVIEW ] ──► [ APPROVED ] ──► [ PAID ]
                                       │                   │
                                       ▼                   ▼
                                  [ REJECTED ]        [ RECONCILING ]
                                                           │
                                                           ▼
                                                       [ SETTLED ]
```

---

## 5. Security & Row Level Security (RLS) Matrix

| Table | SELECT | INSERT | UPDATE | DELETE |
| :--- | :--- | :--- | :--- | :--- |
| `employees` | Own record, or Manager/HOD/Finance/Admin | Admin only | Admin or self (limited fields: phone) | Admin (soft-delete) |
| `expenses` | Owner, or Approver if part of active claim, or Finance/Admin | Owner (when not locked in submitted claim) | Owner (only if `DRAFT` or `CORRECTION_REQUIRED`) | Owner (only if `DRAFT`) |
| `expense_receipts` | Owner, assigned approvers, Finance | Owner | Owner (draft only) | Owner (draft only) |
| `expense_claims` | Owner, active step approver, Finance, Admin | Owner | Owner (draft/correction), Reviewer (status via function) | Owner (draft only) |
| `cash_advances` | Owner, assigned approvers, Finance | Owner | Owner (draft only), Reviewer via secure function | Owner (draft only) |
| `approval_actions` | Claim owner, Reviewers in chain, Finance, Admin | Assigned Approver via server function | None (Immutable) | Prohibited |
| `reimbursements` | Claim owner, Finance, Admin | Finance, Admin | Finance, Admin | Prohibited |
| `payments` | Claim owner, Finance, Admin | Finance, Admin | None (Immutable) | Prohibited |
| `audit_logs` | Admin, Compliance, Finance (read-only) | System/Trigger only | Prohibited | Prohibited |

---

## 6. Project Directory Architecture

```text
d:\Vaishal Workspace\ASM Expense\
├── docs/
│   ├── architecture/
│   │   ├── MASTER_SYSTEM_ARCHITECTURE.md
│   │   └── ERD.md
│   ├── business-rules/
│   │   └── ASM_BUSINESS_RULES.md
│   └── security/
│       └── RLS_SECURITY_MODEL.md
├── supabase/
│   ├── migrations/
│   │   ├── 20261018000001_initial_schema.sql
│   │   ├── 20261018000002_rls_policies.sql
│   │   ├── 20261018000003_functions_and_triggers.sql
│   │   └── 20261018000004_seed_config.sql
│   ├── functions/
│   │   ├── _shared/
│   │   │   ├── cors.ts
│   │   │   ├── auth.ts
│   │   │   └── validation.ts
│   │   ├── process-receipt-ocr/
│   │   ├── validate-claim/
│   │   ├── submit-claim/
│   │   ├── process-approval/
│   │   └── record-payment/
│   └── config.toml
├── mobile/ (Flutter Application)
│   ├── lib/
│   │   ├── app/
│   │   │   ├── app.dart
│   │   │   ├── router/
│   │   │   └── theme/
│   │   ├── core/
│   │   │   ├── config/
│   │   │   ├── constants/
│   │   │   ├── errors/
│   │   │   ├── network/
│   │   │   ├── security/
│   │   │   └── utils/
│   │   ├── features/
│   │   │   ├── auth/
│   │   │   ├── dashboard/
│   │   │   ├── profile/
│   │   │   ├── advances/
│   │   │   ├── expenses/
│   │   │   ├── receipts/
│   │   │   ├── claims/
│   │   │   ├── approvals/
│   │   │   ├── reimbursements/
│   │   │   ├── notifications/
│   │   │   └── reports/
│   │   ├── shared/
│   │   │   ├── widgets/
│   │   │   └── models/
│   │   └── main.dart
│   ├── test/
│   ├── pubspec.yaml
│   └── analysis_options.yaml
└── .env.example
```

---

## 7. 25-Step Phased Implementation Roadmap

- [x] **Step 1:** Complete analysis of master specification and architecture documents.
- [x] **Step 2:** Formulate and publish Master Architecture Blueprint and directory plan.
- [ ] **Step 3:** Generate complete Database ERD and Schema Specification.
- [ ] **Step 4:** Implement Supabase SQL Migrations (DDL, Constraints, Enums, Foreign Keys).
- [ ] **Step 5:** Implement comprehensive PostgreSQL Row Level Security (RLS) policies and Storage Security.
- [ ] **Step 6:** Implement Database Triggers, Deterministic Financial Functions, Audit Logging, and State Machine Guards.
- [ ] **Step 7:** Populate Seed Data (ASM Departments, Designations, Currencies, Policies, Workflows, Admin Accounts).
- [ ] **Step 8:** Scaffold Flutter Enterprise Architecture (Clean Architecture, Repositories, Riverpod State Management, GoRouter, Corporate Design System).
- [ ] **Step 9:** Build Authentication, Session Persistence, Role Resolution, and Secure Route Guards.
- [ ] **Step 10:** Build Employee Profile and Enterprise Dashboard.
- [ ] **Step 11:** Implement Expense Creation Module (Manual Entry, Currency Minor Units, Multi-Currency Conversion).
- [ ] **Step 12:** Implement Secure Receipt Upload to Private Supabase Storage with Signed URLs and Client Validation.
- [ ] **Step 13:** Implement Backend Edge Function for OCR Integration (Unlimited-OCR / Provider Adapter).
- [ ] **Step 14:** Implement OCR Verification Screen (Human Review & Correction, Mandatory Override).
- [ ] **Step 15:** Implement Configurable No-Receipt Policy Validation (Threshold Enforcement).
- [ ] **Step 16:** Build Claim Creation, Expense Grouping, and Deterministic Breakdown Validation Engine.
- [ ] **Step 17:** Implement Cash Advance Lifecycle & Automated Advance Reconciliation Engine.
- [ ] **Step 18:** Build Multi-Tier Approval Workflow Engine (Line Manager → HOD → Siva → Finance).
- [ ] **Step 19:** Implement Rejection, Correction Requests, and Resubmission Cycles.
- [ ] **Step 20:** Implement Finance Portal & Reimbursement Engine (Payment Recording, Idempotency Protection, Settlement).
- [ ] **Step 21:** Build Real-time In-App Notifications and Notification Center.
- [ ] **Step 22:** Implement Corporate Expense Reporting & Analytics (Employee, Department, Category).
- [ ] **Step 23:** Build Admin Configuration Interface (Policies, Workflows, Categories, Limits).
- [ ] **Step 24:** Write Unit, Widget, Integration, and Security Test Suites.
- [ ] **Step 25:** Complete Security Hardening, Verification Checklist, and Production Deployment Package.
