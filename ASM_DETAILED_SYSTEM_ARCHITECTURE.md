# ASM Expense & Reimbursement Platform
## Detailed System Architecture

**Organization:** Al Seer Marine (ASM)  
**Client:** Flutter Mobile App  
**Backend:** Supabase  
**Database:** PostgreSQL  
**Storage:** Supabase Storage  
**OCR:** Unlimited-OCR / approved OCR provider  
**AI:** GroqCloud / approved AI provider  
**Deployment:** Private enterprise application

---

## 1. Executive Architecture

The platform manages employee cash advances, business expenses, receipt OCR, claim validation, configurable approval workflows, Finance reimbursement, payment tracking, notifications, reporting, and audit history.

```text
                         ASM USERS
                            |
        +-------------------+-------------------+
        |                   |                   |
     Employees          Approvers          Finance/Admin
        |                   |                   |
        +-------------------+-------------------+
                            |
                            v
              +---------------------------+
              |     FLUTTER MOBILE APP    |
              |                           |
              | Login / Dashboard         |
              | Cash Advance              |
              | Expenses                  |
              | Receipt Scan / Upload     |
              | OCR Verification          |
              | Claims                    |
              | Notifications             |
              | Reimbursement Status      |
              +-------------+-------------+
                            |
                         HTTPS/TLS
                            |
                            v
              +---------------------------+
              |       SUPABASE AUTH        |
              | Identity / Session / JWT  |
              +-------------+-------------+
                            |
                            v
              +---------------------------+
              | SUPABASE EDGE FUNCTIONS   |
              |                           |
              | Expense Service            |
              | OCR Service                |
              | Claim Service              |
              | Policy Engine              |
              | Approval Engine            |
              | Cash Advance Service       |
              | Reimbursement Service      |
              | Notification Service       |
              | Reporting / Audit          |
              +------+---------------+----+
                     |               |
                     v               v
             +---------------+  +---------------+
             |  PostgreSQL   |  |   Storage     |
             |               |  | Private bills|
             | Employees     |  | Secure docs  |
             | Expenses      |  +---------------+
             | Claims        |
             | Advances      |
             | Approvals     |
             | Payments      |
             | Policies      |
             | Audit Logs    |
             +-------+-------+
                     |
             +-------+--------+
             |                |
             v                v
      +-------------+  +-------------+
      | Unlimited   |  | GroqCloud   |
      | OCR         |  | AI          |
      +-------------+  +-------------+
```

---

# 2. Architecture Layers

## Layer 1 — Client

### Flutter Mobile

Used primarily by employees and optionally approvers.

Responsibilities:

- Login and session handling
- Employee profile
- Cash advance request
- Expense creation
- Receipt capture/upload
- OCR verification
- Claim creation/submission
- Approval status
- Notifications
- Reimbursement history

The Flutter client is **not a security boundary**. It must never contain privileged API keys or business-rule bypasses.

### Finance/Admin Web Portal

Recommended separate web application for:

- Claim queue
- Employee management
- Department management
- Approval configuration
- Cash advance review
- Reimbursement processing
- Payment tracking
- Reports
- Exports
- Policy configuration
- Audit review

---

# 3. Authentication and Authorization

```text
User
 |
 v
Flutter Login
 |
 v
Supabase Auth
 |
 v
Authenticated Session
 |
 v
JWT / Access Token
 |
 v
Backend Authorization
 |
 +--> Role validation
 +--> Employee ownership
 +--> Approval scope
 +--> Department scope
 |
 v
PostgreSQL RLS
```

Authentication answers **who the user is**.

Authorization answers **what the user can do**.

Recommended roles:

```text
EMPLOYEE
LINE_MANAGER
DEPARTMENT_MANAGER
MANAGEMENT
FINANCE
ADMIN
```

Roles and approval assignments must be stored in the database, not hardcoded in Flutter.

---

# 4. Core Database Architecture

```text
IDENTITY
  users
  employees
  departments
  designations
  cost_centers

CONFIGURATION
  expense_categories
  currencies
  exchange_rates
  policies
  policy_rules
  approval_workflows
  approval_workflow_steps

FINANCIAL
  cash_advances
  expenses
  expense_receipts
  expense_ocr_results
  expense_claims
  claim_expenses
  reimbursements
  payments

WORKFLOW
  approvals
  notifications
  audit_logs
```

## Relationship

```text
DEPARTMENT
    |
    +----< EMPLOYEE
              |
              +----< CASH_ADVANCE
              |
              +----< EXPENSE
              |
              +----< EXPENSE_CLAIM
              |
              +----< NOTIFICATION
              |
              +----< AUDIT_LOG

EXPENSE
    |
    +----< EXPENSE_RECEIPT
    |
    +----1 EXPENSE_OCR_RESULT

EXPENSE_CLAIM
    |
    +----< CLAIM_EXPENSE
    |
    +----< APPROVAL
    |
    +----1 REIMBURSEMENT

CURRENCY
    |
    +----< EXPENSE
    +----< CASH_ADVANCE
    +----< EXCHANGE_RATE
```

---

# 5. Employee Master Data

Recommended employee record:

```text
employee_id
employee_code
full_name
email
phone
department_id
designation_id
line_manager_id
hod_id
cost_center_id
role
status
joining_date
created_at
updated_at
```

ASM employee IDs and names supplied by the client should be imported into the production database.

The system must support changing managers, departments and roles without modifying application source code.

---

# 6. Expense Architecture

## Expense Creation

```text
Employee
   |
   v
Add Expense
   |
   +--> Category
   +--> Amount
   +--> Currency
   +--> Date
   +--> Description
   +--> Vendor
   +--> Receipt
   |
   v
Save Draft
```

Suggested categories:

```text
Food
Travel
Hotel
Fuel
Taxi
Parking
Other
```

The final list should be driven by ASM policy.

---

# 7. Receipt and OCR Architecture

OCR is an extraction assistant, not the financial source of truth.

```text
Take Photo / Upload
        |
        v
Flutter File Validation
        |
        v
Private Supabase Storage
        |
        v
Secure OCR Edge Function
        |
        v
Unlimited-OCR
        |
        v
Raw OCR Result
        |
        v
Structured Extraction
        |
        +--> Vendor
        +--> Invoice Number
        +--> Date
        +--> Subtotal
        +--> VAT
        +--> Total
        +--> Currency
        |
        v
Store OCR Result
        |
        v
Employee Verification
        |
   +----+----+
   |         |
 Edit      Confirm
   |         |
   +----+----+
        |
        v
Confirmed Expense
```

The employee must be able to correct OCR output.

OCR must never automatically approve or submit a financial claim.

---

# 8. Receipt Validation

Example:

```text
Advance = AED 1,000

Food       = AED 300
Travel     = AED 200
Hotel      = AED 400
Other      = AED 100
-----------------------
Breakup    = AED 1,000

Receipt totals:
300 + 200 + 400 + 100
= AED 1,000

RESULT = VALID
```

Mismatch:

```text
Breakup total = AED 1,000
Receipt total = AED 900

RESULT = MISMATCH

System:
- Shows difference
- Flags the claim
- Prevents final submission
- Requests correction
```

Any permitted rounding tolerance should be configurable.

---

# 9. No-Receipt Policy

Current discussed rule:

```text
Expense <= AED 500
    |
    +--> May be claimed without receipt

Expense > AED 500
    |
    +--> Receipt normally required
```

This must be configurable:

```text
no_receipt_limit_aed = 500
receipt_required_above_limit = true
```

A no-receipt claim should require:

- Reason
- Business purpose
- Employee declaration
- Appropriate approval
- Audit entry

Final ASM policy must be confirmed before production.

---

# 10. Multi-Currency Architecture

Initial currencies:

```text
AED
USD
EUR
```

Every financial transaction should preserve:

```text
original_amount
original_currency
exchange_rate
aed_equivalent
exchange_rate_date
exchange_rate_source
```

Example:

```text
USD 100
Exchange Rate = 3.6725
AED Equivalent = 367.25
```

Original amount and currency must never be lost.

For exact financial calculations, use integer minor units rather than binary floating-point values.

---

# 11. Cash Advance Architecture

```text
Employee
   |
   v
Cash Advance Request
   |
   +--> Amount
   +--> Currency
   +--> Purpose
   +--> Expected Date
   +--> Business Reason
   |
   v
Policy Validation
   |
   v
Approval Workflow
   |
   v
Finance Processing
   |
   v
Advance Paid
   |
   v
Employee Uses Advance
   |
   v
Expenses Submitted
   |
   v
Reconciliation
```

Suggested statuses:

```text
DRAFT
SUBMITTED
UNDER_REVIEW
APPROVED
REJECTED
PAID
PARTIALLY_SETTLED
SETTLED
CANCELLED
```

---

# 12. Claim Architecture

A claim groups expenses into a reimbursement request.

```text
Employee
   |
   v
Create Claim
   |
   v
Select Expenses
   |
   v
Calculate Total
   |
   v
Validate Receipts
   |
   v
Validate Policy
   |
   v
Validate Currency
   |
   v
Reconcile Advance
   |
   v
Submit Claim
```

Claim statuses:

```text
DRAFT
SUBMITTED
LINE_MANAGER_REVIEW
HOD_REVIEW
SIVA_REVIEW
FINANCE_REVIEW
APPROVED
REIMBURSEMENT_PROCESSING
PAID
SETTLED
REJECTED
CORRECTION_REQUIRED
CANCELLED
```

---

# 13. Approval Architecture

Initial hierarchy:

```text
Employee
   |
   v
Line Manager
   |
   v
Department Manager / HOD
   |
   v
Siva / Management
   |
   v
Finance
   |
   v
Reimbursement
```

The hierarchy must be configurable through database configuration.

Never hardcode a personal name into approval logic.

## Approval state machine

```text
             +-------+
             | DRAFT |
             +---+---+
                 |
               Submit
                 |
                 v
        +-------------------+
        | LINE MANAGER      |
        +---------+---------+
                  |
          +-------+-------+
          |               |
        Reject          Approve
          |               |
          v               v
      REJECTED       +-----------+
                     | HOD REVIEW|
                     +-----+-----+
                           |
                   +-------+-------+
                   |               |
                 Reject          Approve
                   |               |
                   v               v
               REJECTED     +-------------+
                             | MANAGEMENT  |
                             +------+------+
                                    |
                            +-------+-------+
                            |               |
                          Reject          Approve
                            |               |
                            v               v
                        REJECTED       +---------+
                                       | FINANCE |
                                       +----+----+
                                            |
                                            v
                                      REIMBURSEMENT
                                            |
                                            v
                                           PAID
```

Correction path:

```text
Any Review
    |
    v
CORRECTION_REQUIRED
    |
    v
Employee Edits
    |
    v
Resubmit
    |
    v
Workflow Continues/Restarts
```

---

# 14. Approval Security

The backend must prevent:

- Self-approval
- Unauthorized manager approval
- Skipping approval levels
- Changing approval history
- Changing approved financial values without re-approval
- Privilege escalation
- Direct client-side status manipulation

Approval record:

```text
approver_id
claim_id
approval_level
action
comments
timestamp
previous_status
new_status
request_id
```

---

# 15. Advance Reconciliation

Example 1:

```text
Advance = AED 1,000
Expenses = AED 900

Difference = AED 100
```

The system records the outstanding AED 100 settlement according to ASM policy.

Example 2:

```text
Advance = AED 2,000
Expenses = AED 2,520

Additional reimbursement = AED 520
```

The additional amount remains subject to approval and policy.

The exact treatment of unused/excess advances must be confirmed by ASM Finance.

---

# 16. Reimbursement Architecture

```text
Final Approval
     |
     v
Finance Queue
     |
     v
Finance Review
     |
     v
Create Reimbursement
     |
     v
Process Payment
     |
     v
Record Payment Reference
     |
     v
Mark Claim PAID
     |
     v
Notify Employee
```

Suggested fields:

```text
id
claim_id
employee_id
approved_amount
paid_amount
currency
aed_amount
payment_method
payment_reference
payment_date
processed_by
status
created_at
updated_at
```

---

# 17. Finance Portal Architecture

```text
Finance/Admin Login
       |
       v
Dashboard
       |
       +--> Pending Claims
       +--> Approved Claims
       +--> Paid Claims
       +--> Advances
       +--> Outstanding Settlements
       |
       v
Search / Filter
       |
       v
Claim Detail
       |
       +--> Employee
       +--> Expenses
       +--> Receipts
       +--> OCR
       +--> Approval History
       +--> Advance
       +--> Validation
       |
       v
Finance Action
       |
       +--> Correction
       +--> Reject
       +--> Reimburse
       +--> Mark Paid
```

Filters:

```text
Employee ID
Employee Name
Department
Claim ID
Category
Currency
Date Range
Status
Approval Stage
Payment Status
```

---

# 18. Supabase Storage

Receipt files must be private.

Recommended logical structure:

```text
receipts/
  {employee_id}/
    {claim_id}/
      receipt_001.jpg
      receipt_002.jpg
      receipt_003.pdf
```

Controls:

- Private bucket
- No public receipt URLs
- Short-lived signed URLs
- File-type validation
- File-size limits
- Secure generated filenames
- Image processing limits
- Malware scanning where available
- Authorization before access

---

# 19. Backend / Edge Functions

Recommended secure functions:

```text
create-cash-advance
submit-cash-advance
create-expense
process-receipt-ocr
validate-expense
create-claim
validate-claim
submit-claim
process-approval
request-correction
process-reimbursement
mark-payment
send-notification
generate-report
export-report
admin-update-policy
admin-update-workflow
```

Privileged API keys must exist only in server-side secrets.

---

# 20. Deterministic Financial Engine

The following must never depend on an LLM:

```text
Expense totals
Receipt reconciliation
Currency conversion
Policy limits
Receipt requirements
Approval routing
Approval authorization
Claim status
Payment status
Advance reconciliation
```

AI may assist with:

```text
OCR extraction
Receipt classification
Natural-language explanation
Search assistance
Anomaly suggestions
```

AI must never:

```text
Approve claims
Reject claims autonomously
Change payment amounts
Bypass policy
Change approval hierarchy
Mark payments as complete
```

---

# 21. GroqCloud AI Boundary

```text
Flutter
   |
   v
Secure Backend Function
   |
   v
GroqCloud API
   |
   v
Structured Response
   |
   v
Backend Schema Validation
   |
   v
Business Validation
   |
   v
Application
```

AI API keys must never be embedded in Flutter.

AI responses are untrusted input.

Prompt injection protection is required for receipt/OCR/user-provided content.

---

# 22. Notification Architecture

Events:

```text
Claim Submitted
Approval Required
Claim Approved
Claim Rejected
Correction Required
Cash Advance Approved
Cash Advance Rejected
Payment Processed
Settlement Required
```

```text
Business Event
      |
      v
Notification Service
      |
      +--> In-App
      +--> Push
      +--> Email if configured
```

Notifications should expose only the minimum necessary financial information.

---

# 23. Reporting

Reports:

```text
Monthly Expense
Employee Expense
Department Expense
Category
Pending Claims
Approved Claims
Paid Claims
Cash Advance
Outstanding Settlement
Currency
Reimbursement
```

Exports:

```text
CSV
Excel
PDF
```

Reports must use backend authorization and must not expose data outside the user's scope.

---

# 24. Row Level Security

Supabase RLS must be enabled for all sensitive tables.

```text
EMPLOYEE
  -> Own profile
  -> Own expenses
  -> Own claims
  -> Own receipts
  -> Own advances
  -> Own notifications

LINE MANAGER
  -> Assigned employee claims
  -> Assigned approval actions

HOD
  -> Department scope

MANAGEMENT
  -> Configured organization scope

FINANCE
  -> Finance/reimbursement scope

ADMIN
  -> Authorized administration scope
```

RLS is mandatory; hiding UI buttons is not security.

---

# 25. Trust Boundary

```text
UNTRUSTED
+----------------------------------+
| Flutter                          |
| User input                       |
| Receipt image                    |
| OCR text                         |
+----------------+-----------------+
                 |
                 | TLS
                 v
TRUSTED
+----------------------------------+
| Edge Functions                   |
| Authentication                  |
| Authorization                   |
| Validation                      |
| Policy Engine                   |
| Workflow Engine                 |
+----------------+-----------------+
                 |
                 v
TRUSTED DATA
+----------------------------------+
| PostgreSQL                       |
| Private Storage                  |
| Audit Logs                       |
+----------------+-----------------+
                 |
                 v
CONTROLLED EXTERNAL SERVICES
+----------------------------------+
| OCR Provider                     |
| GroqCloud                        |
| Notification Provider            |
+----------------------------------+
```

---

# 26. Security Architecture

Mandatory controls:

```text
TLS/HTTPS
Supabase Auth
JWT/session validation
PostgreSQL RLS
Backend authorization
Private storage
Signed URLs
Secret management
Input validation
Output validation
Rate limiting
Idempotency
Audit logging
Secure error handling
Dependency scanning
Secret scanning
Environment separation
```

Never expose:

```text
Supabase service-role key
Groq API key
OCR secret
Database administrator credentials
Production secrets
```

---

# 27. Audit Architecture

Important events:

```text
Expense Created
Expense Edited
Receipt Uploaded
OCR Processed
Claim Submitted
Claim Approved
Claim Rejected
Correction Requested
Advance Approved
Advance Paid
Reimbursement Created
Payment Processed
Policy Changed
Role Changed
Approval Workflow Changed
```

Audit fields:

```text
id
actor_id
actor_role
action
entity_type
entity_id
old_value
new_value
timestamp
request_id
metadata
```

Audit records for financial events should be immutable.

---

# 28. Transaction Integrity

Critical financial operations must be atomic.

```text
BEGIN TRANSACTION

Validate Claim
Validate Expenses
Validate Receipts
Validate Policy
Create Approval
Update Claim Status
Create Audit Entry
Create Notification

COMMIT
```

If a critical operation fails:

```text
ROLLBACK
```

This prevents partially submitted claims.

---

# 29. Idempotency

Financially sensitive operations should be idempotent.

```text
Request
   |
   v
Create Reimbursement
   |
   X network retry
   |
   v
Same Request Again
   |
   v
Idempotency Key
   |
   v
Existing Result Returned
```

Apply to:

```text
Claim submission
Reimbursement creation
Payment processing
OCR jobs
Notifications
```

---

# 30. Complete Employee Journey

```text
LOGIN
  |
  v
HOME
  |
  +---------------------+
  |                     |
  v                     v
CASH ADVANCE          EXPENSE
  |                     |
  v                     v
REQUEST               CREATE
  |                     |
  v                     v
APPROVAL              RECEIPT
  |                     |
  |                     v
  |                    OCR
  |                     |
  |                     v
  |                  VERIFY
  |                     |
  +----------+----------+
             |
             v
        CREATE CLAIM
             |
             v
       VALIDATE TOTALS
             |
             v
       VALIDATE RECEIPTS
             |
             v
      RECONCILE ADVANCE
             |
             v
           SUBMIT
             |
             v
       LINE MANAGER
             |
             v
            HOD
             |
             v
        MANAGEMENT
             |
             v
          FINANCE
             |
             v
       REIMBURSEMENT
             |
             v
            PAID
```

---

# 31. End-to-End Receipt Flow

```text
Receipt
  |
  v
Flutter
  |
  v
File Validation
  |
  v
Private Storage
  |
  v
OCR Function
  |
  v
Unlimited-OCR
  |
  v
Structured OCR
  |
  v
Employee Verification
  |
  v
Expense
  |
  v
Claim
  |
  v
Receipt Reconciliation
  |
  v
Approval
```

---

# 32. Production Environment

Separate:

```text
DEVELOPMENT
    |
    v
TESTING
    |
    v
STAGING
    |
    v
PRODUCTION
```

Each environment should have separate:

- Supabase project
- Database
- Storage
- Secrets
- API credentials
- Test data

Production employee data should not be copied into development without explicit authorization.

---

# 33. Deployment

```text
Developer
   |
   v
Git Repository
   |
   v
CI/CD
   |
   +------------------+
   |                  |
   v                  v
Flutter Build      Supabase
   |                  |
   v                  +--> Migrations
Android AAB           +--> Edge Functions
                      +--> RLS
                      +--> Storage policies
```

Recommended ASM production distribution:

```text
Flutter AAB
   |
   v
ASM IT / MDM
   |
   v
Managed Google Play
or approved enterprise distribution
   |
   v
ASM Employees
```

Pilot:

```text
Signed APK
   |
   v
10-20 pilot users
   |
   v
Feedback
   |
   v
Production AAB
```

---

# 34. Observability

Monitor:

```text
Application errors
API errors
Database errors
OCR failures
AI failures
Authentication failures
Slow requests
Storage failures
Notification failures
Payment failures
```

Use request/correlation IDs.

Never log:

```text
Passwords
Access tokens
API keys
Unnecessary receipt contents
Sensitive personal information
```

---

# 35. Performance

Use:

```text
Pagination
Lazy loading
Image compression
Thumbnails
Database indexes
Server-side filtering
Async OCR
Async notifications
Caching for static configuration
```

Large receipts should not be repeatedly downloaded.

---

# 36. Recommended Flutter Project Structure

```text
mobile/
  lib/
    core/
      config/
      security/
      network/
      routing/
      theme/
      utils/

    features/
      auth/
      dashboard/
      profile/
      expenses/
      receipts/
      claims/
      advances/
      approvals/
      notifications/
      reimbursement/
      reports/
      settings/

    shared/
```

Backend:

```text
supabase/
  migrations/
  functions/
    create-expense/
    process-ocr/
    validate-claim/
    submit-claim/
    process-approval/
    process-reimbursement/
    notifications/
    reports/
    admin/
```

Documentation:

```text
docs/
  architecture/
  api/
  security/
  deployment/
  business-rules/
```

---

# 37. Development Phases

## Phase 1 — Foundation

```text
Flutter
Supabase
Auth
Database
RLS
Environment configuration
Base UI
```

## Phase 2 — Employee Expenses

```text
Profile
Dashboard
Categories
Expense creation
Receipt upload
History
```

## Phase 3 — OCR

```text
OCR integration
Structured extraction
Verification
Receipt validation
```

## Phase 4 — Claims

```text
Claim creation
Expense grouping
Validation
Submission
History
```

## Phase 5 — Approval

```text
Line Manager
HOD
Management
Correction
Rejection
Audit
```

## Phase 6 — Cash Advance

```text
Request
Approval
Payment
Reconciliation
Settlement
```

## Phase 7 — Finance

```text
Finance dashboard
Reimbursement
Payment tracking
Reports
Exports
```

## Phase 8 — Hardening

```text
Security
RLS
Authorization
Performance
Failure recovery
Duplicate requests
Audit testing
```

## Phase 9 — Pilot

```text
10-20 ASM users
Sample bills
Realistic workflows
Policy confirmation
Bug fixing
```

## Phase 10 — Production

```text
Production accounts
Production database
Production storage
Production secrets
Signed AAB
Enterprise distribution
Monitoring
Backup
Support process
```

---

# 38. Testing Architecture

## Unit Tests

```text
Totals
Currency conversion
Receipt matching
Policy limits
No-receipt rules
Advance reconciliation
Status transitions
```

## Integration Tests

```text
Auth -> Database
Expense -> OCR
Expense -> Claim
Claim -> Approval
Approval -> Finance
Finance -> Payment
```

## Security Tests

```text
IDOR
Privilege escalation
RLS bypass
Storage bypass
Self-approval
Unauthorized approval
Token misuse
Secret exposure
```

## Workflow Tests

```text
Happy path
Reject
Correction
Resubmit
Cancel
Payment
Settlement
```

---

# 39. Mandatory Security Rules

```text
1. Never expose service-role keys in Flutter.
2. Never expose Groq/OCR secrets in Flutter.
3. Never trust client-provided employee_id.
4. Never trust client-provided role.
5. Never trust client-provided approval level.
6. Never allow client-side approval bypass.
7. Calculate final financial values server-side.
8. Keep receipt storage private.
9. Enforce PostgreSQL RLS.
10. Prevent self-approval.
11. Preserve financial history.
12. Audit financial and approval events.
13. Validate every uploaded file.
14. Treat OCR and AI output as untrusted.
15. Keep financial decisions deterministic.
16. Keep approval rules configurable.
17. Keep production secrets outside Git.
18. Do not use production employee data in development without authorization.
19. Use transactions for critical financial operations.
20. Use idempotency for duplicate-sensitive operations.
```

---

# 40. Final Production Architecture

```text
                              ASM USERS
                                  |
       +--------------------------+--------------------------+
       |                          |                          |
       v                          v                          v
   EMPLOYEES                  APPROVERS                 FINANCE/ADMIN
       |                          |                          |
       +--------------------------+--------------------------+
                                  |
                                  v
                 +--------------------------------+
                 |       FLUTTER MOBILE APP       |
                 +----------------+---------------+
                                  |
                               HTTPS
                                  |
                                  v
                 +--------------------------------+
                 |          SUPABASE AUTH         |
                 +----------------+---------------+
                                  |
                                  v
                 +--------------------------------+
                 |      EDGE FUNCTIONS / API      |
                 |                                |
                 | Expense | OCR | Claim          |
                 | Policy | Approval | Advance    |
                 | Reimbursement | Notification   |
                 | Reports | Audit | Admin        |
                 +------------+----------+--------+
                              |          |
                              v          v
                    +-------------+ +-------------+
                    | PostgreSQL  | |   Storage   |
                    +------+------+ +-------------+
                           |
                 +---------+---------+
                 |                   |
                 v                   v
           Unlimited-OCR        GroqCloud
                 |                   |
                 +---------+---------+
                           |
                           v
                 VALIDATION + WORKFLOW
                           |
                           v
                       FINANCE
                           |
                           v
                    REIMBURSEMENT
                           |
                           v
                         PAID
```

---

# 41. Supporting Documentation

- Supabase Flutter Quickstart: https://supabase.com/docs/guides/getting-started/quickstarts/flutter
- Supabase Documentation: https://supabase.com/docs/
- Supabase Row Level Security: https://supabase.com/docs/guides/database/postgres/row-level-security
- Supabase Storage: https://supabase.com/docs/guides/storage
- Supabase Edge Functions: https://supabase.com/docs/guides/functions
- Groq Structured Outputs: https://console.groq.com/docs/structured-outputs
- Groq API Documentation: https://console.groq.com/docs
- Zoho Expense: https://www.zoho.com/in/expense/
- Zoho Expense Help: https://www.zoho.com/in/expense/help/
- Zoho Expense — How It Works: https://www.zoho.com/in/expense/help/getting-started/how-zoho-expense-works/
- Zoho Expense — AI Features: https://www.zoho.com/in/expense/help/admin/ai-features/

---

# 42. Pre-Production Confirmation Checklist

Before production development is finalized, ASM must confirm:

```text
[ ] Employee master data
[ ] Department structure
[ ] Designations
[ ] Line manager mapping
[ ] HOD mapping
[ ] Approval hierarchy
[ ] AED 10,000 limit and its scope
[ ] AED 500 no-receipt rule
[ ] Advance settlement treatment
[ ] Excess-expense treatment
[ ] Currency conversion source
[ ] Receipt retention period
[ ] OCR provider approval
[ ] AI provider/data-processing approval
[ ] Authentication / SSO requirement
[ ] MDM / Managed Google Play requirement
[ ] Finance payment process
[ ] Production account ownership
[ ] Security review
[ ] Pilot approval
```

---

## Architecture Principle

The platform should remain **secure, configurable, auditable, and human-verifiable**.

The mobile application handles user interaction. Supabase provides identity, database, storage and backend functions. The backend owns financial validation and workflow decisions. OCR and AI assist users but never become the authority for financial approval. PostgreSQL RLS and server-side authorization enforce access control. Every important financial and approval action is auditable.

This architecture is the baseline for implementing the ASM production system in Flutter + Supabase while keeping ASM-specific policies configurable.
