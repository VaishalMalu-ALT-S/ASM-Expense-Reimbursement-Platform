# ASM Expense & Reimbursement Platform - Project Memory & Handover Document

## 1. Project Overview
The ASM Expense & Reimbursement Platform is an enterprise-grade corporate expense management, receipt digitization, and multi-tier approval system built for Al Seer Marine (ASM).

- Repository: `d:\Vaishal Workspace\ASM Expense`
- Primary Currency: AED (United Arab Emirates Dirham)
- Technology Stack: Flutter (Web/Mobile), Supabase (PostgreSQL, Auth, Storage, Edge Functions), Python FastAPI (NVIDIA Nemotron OCR v2 Service).

---

## 2. Core Architectural Principles
1. Integer Minor Units for Financial Math:
   - All amounts in database and calculations are stored as integer minor units (fils for AED, 100 fils = 1 AED; cents for USD/EUR).
   - Binary floating point calculations for currency are prohibited.
   - Handled on frontend via `MoneyUtils` (`mobile/lib/core/utils/money_utils.dart`).
2. Server-Side Enforcement (Never Trust the Client):
   - Monetary totals, policy rules (AED 500 receipt requirement, AED 10,000 maximum single-claim threshold), and approval permissions are enforced inside PostgreSQL functions and triggers.
3. Clean Corporate Aesthetics:
   - ASM Navy (`#0D253F`), ASM Brand Blue (`#1E56A0`), ASM Accent Gold (`#C5A059`), Neutral Light Slate backgrounds (`#F4F6F9`).
   - Zero emojis anywhere in code, labels, messages, or interface components.

---

## 3. Verified Demo Accounts & Role Hierarchy
All five roles have been provisioned in Supabase Auth and linked to organizational records in `employees` and `employee_roles`.

Password policy: Each account has an individually generated temporary password (recorded in `CREDENTIALS.md` and `temporary_credentials.csv`).

| Role | Name | Corporate Email | Employee Code | Department | Approval Responsibility |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Employee | Ahmed Al Mansoori | `employee@alseermarine.com` | ASM-1001 | Operations | Submit expenses, cash advances, and claims |
| Line Manager | Tariq Al Hammadi | `manager@alseermarine.com` | ASM-1002 | Operations | Tier 1 Claim Approval (`LINE_MANAGER_REVIEW`) |
| Head of Dept (HOD) | Dr. Khalid Al Zaabi | `hod@alseermarine.com` | ASM-2001 | Operations | Tier 2 Department Approval (`HOD_REVIEW`) |
| Management Approver | Siva | `management@alseermarine.com` | ASM-0101 | Exec Management | Tier 3 Management Approval (`SIVA_REVIEW`) |
| Finance Controller | Fatima Al Mazrouei | `finance@alseermarine.com` | ASM-3001 | Finance | Tier 4 Audit & Bank Settlement (`FINANCE_REVIEW`) |
| System Admin | Saeed Al Qubaisi | `admin@alseermarine.com` | ASM-0001 | Administration | Policy thresholds, audit logs, user management |

Organizational links:
- Ahmed Al Mansoori's `line_manager_id` points to Tariq Al Hammadi.
- Ahmed Al Mansoori's `hod_id` points to Dr. Khalid Al Zaabi.
- Operations department `hod_employee_id` points to Dr. Khalid Al Zaabi.
- Script for re-provisioning demo roles: `provision_roles.py`.

### 3.1 Original Employee Dataset (Imported from Company Data)
All 18 original staff members from corporate HR records are active in Supabase Auth, `employees`, and `employee_roles`.
Users can log in with either their raw numeric Emp ID (e.g. `37317`) or full email (`37317@alseermarine.com`).
Passwords have been rotated to unique temporary credentials per account in `CREDENTIALS.md`.

| Emp ID | Full Name | Department | Primary Role | Sign-in Email |
| :--- | :--- | :--- | :--- | :--- |
| 37317 | Meharoof KottileValappil | Marine Operations & Fleet (OPERATIONS) | EMPLOYEE | `37317@alseermarine.com` |
| 44266 | Roldan De Vera | Marine Operations & Fleet (OPERATIONS) | EMPLOYEE | `44266@alseermarine.com` |
| 23833 | Murugan Selvaraj | IML PPM (IMLPPM) | EMPLOYEE | `23833@alseermarine.com` |
| 48359 | Simon Joseph Frederick Davis | IML PPM (IMLPPM) | LINE_MANAGER | `48359@alseermarine.com` |
| 34451 | Vivek Shripad Kulkarni | IML PPM (IMLPPM) | EMPLOYEE | `34451@alseermarine.com` |
| 23775 | Toufeeq Jeelani | IML PPM (IMLPPM) | EMPLOYEE | `23775@alseermarine.com` |
| 38135 | Hernan Je Margarico | IML PPM (IMLPPM) | EMPLOYEE | `38135@alseermarine.com` |
| 43726 | Musthaque Aramullan Valiyamadathil | IML PPM (IMLPPM) | EMPLOYEE | `43726@alseermarine.com` |
| 45237 | Roelito Baltazar | IML PPM (IMLPPM) | EMPLOYEE | `45237@alseermarine.com` |
| 47451 | Ravindu Vichakshana Rathnayake Rathnayake Mudiyanselage | IML PPM (IMLPPM) | EMPLOYEE | `47451@alseermarine.com` |
| 48752 | Piotr Zbigniew Targowski | ICG Supply Chain Management (ICG.SCM) | LINE_MANAGER | `48752@alseermarine.com` |
| 48690 | Muhammad Raheel Arif Sami | ICG Supply Chain Management (ICG.SCM) | EMPLOYEE | `48690@alseermarine.com` |
| 29018 | Srikanth Kathula | ICG Finance (ICG.FIN) | FINANCE | `29018@alseermarine.com` |
| 24436 | Murtuza Ali Syed | ICG Finance (ICG.FIN) | FINANCE | `24436@alseermarine.com` |
| 47619 | Jessica Peters | ICG Finance (ICG.FIN) | FINANCE | `47619@alseermarine.com` |
| 42421 | Prashant Wagadre | ICG Finance (ICG.FIN) | FINANCE | `42421@alseermarine.com` |
| 48407 | Nishadi Dilhari Thalangodalage | ICG Finance (ICG.FIN) | FINANCE | `48407@alseermarine.com` |
| 50312 | Sebin Vadakkemelathil Thankachan | ASM Integration (ASM.Integration) | EMPLOYEE | `50312@alseermarine.com` |

- Import script: `import_original_employees.py`.

---

## 4. Multi-Stage Approval Workflow
1. Submission:
   Employee submits an expense claim via `create_claim_screen.dart`.
   Trigger/RPC `submit_claim_for_approval` validates receipt requirements and locks status to `LINE_MANAGER_REVIEW`.
2. Tier 1 - Line Manager Review:
   Manager logs in, visits `/approvals` (`manager_approval_screen.dart`), and reviews pending claims.
   Manager approves; RPC `process_approval_action` transitions status to `HOD_REVIEW`.
3. Tier 2 - Department Head (HOD) Review:
   HOD logs in, opens `/approvals`, and approves.
   Status transitions to `FINANCE_REVIEW`.
4. Tier 3 - Finance Reimbursement & Payment:
   Finance Controller logs in, opens `/finance/reimbursements` (`finance_reimbursement_screen.dart`).
   Finance records payment reference and executes settlement via `record_reimbursement_payment`.
   Claim transitions to `SETTLED`.
5. Same-approver escalation (migration 0012, product-owner decision):
   If the HOD already approved the request at an earlier stage (or is the requester), the HOD stage
   is skipped and routed to Management. If every Management holder already approved / is the
   requester, the Management stage is routed to Finance. Finance review is never skipped. Stages
   with no approver configured are not skipped. Each skip is audited (`CLAIM_STAGE_ESCALATED`,
   `ADVANCE_STAGE_ESCALATED`).
6. Admin emergency override (migration 0012, product-owner decision):
   Admin may act at a stage where they are not the designated approver only with a mandatory
   reason; the action is audited as `ADMIN_APPROVAL_OVERRIDE`. Admin as a designated approver acts
   normally. Self-approval and the one-approval-per-person rule still apply to Admin.

---

## 5. System Architecture & Directories

```
ASM Expense/
|-- .env                                  # Live Supabase, NVIDIA API keys, and demo credentials
|-- .env.example                          # Environment template
|-- .cursorrules                          # AI configuration rules for Cursor IDE
|-- PROJECT_MEMORY.md                     # This handover document
|-- CREDENTIALS.md                        # Complete credentials reference for all accounts
|-- PRODUCTION_READINESS_AUDIT.md         # Production readiness audit report
|-- import_original_employees.py          # Script used to import original staff into Supabase
|-- provision_roles.py                    # Script used to provision Supabase auth users & roles
|-- ASM_EXPENSE_MASTER_DEVELOPMENT_SPEC.md# Functional specification
|-- ASM_DETAILED_SYSTEM_ARCHITECTURE.md   # Architectural design specification
|-- docs/
|   `-- architecture/
|       |-- DESIGN_SYSTEM.md              # Palette, typography, and UI tokens
|       |-- ERD.md                        # Entity relationship definitions
|       `-- IMPLEMENTATION_SUMMARY.md     # Architecture implementation summary
|-- mobile/                               # Flutter Frontend Client (Web & Mobile)
|   |-- lib/
|   |   |-- app/
|   |   |   |-- router/app_router.dart    # GoRouter routing table
|   |   |   `-- theme/asm_theme.dart      # Official color tokens and component styling
|   |   |-- core/
|   |   |   |-- network/supabase_service.dart # Central repository for DB, auth, and RPCs
|   |   |   |-- services/receipt_extractor.dart # Multi-tier OCR receipt processing
|   |   |   `-- utils/money_utils.dart    # Financial minor-unit integer calculation utility
|   |   |-- features/
|   |   |   |-- advances/                 # Cash advances request and balance tracking
|   |   |   |-- approvals/                # Manager and HOD approval queue
|   |   |   |-- auth/login_screen.dart    # Login screen with 1-click demo role selector
|   |   |   |-- claims/                   # Claim creation, list, and detail view
|   |   |   |-- dashboard/                # Main analytics and pending summary dashboard
|   |   |   |-- expenses/                 # Single expense entry with no-receipt policy check
|   |   |   |-- receipts/scan_receipt_screen.dart # Receipt upload, OCR, and field extraction
|   |   |   |-- reimbursements/           # Finance settlement and payment processing
|   |   |   `-- reports/                  # Expense reporting and filtering
|   |   `-- shared/
|   |       |-- models/                   # Domain models (Employee, Expense, Claim, etc.)
|   |       `-- widgets/enterprise_shell.dart # Desktop side nav + top bar + profile indicator
|   `-- test/
|       `-- money_utils_test.dart         # Unit tests validating integer financial calculations
|-- services/
|   `-- unlimited_ocr/
|       |-- app.py                        # FastAPI microservice for NVIDIA Nemotron OCR v2
|       `-- requirements.txt              # FastAPI, uvicorn, requests, pillow
`-- supabase/
    |-- functions/
    |   `-- process-receipt-ocr/          # Deno Edge function for OCR processing
    `-- migrations/
        |-- 20261018000001_initial_schema.sql         # Base PostgreSQL schema
        |-- 20261018000002_rls_policies.sql           # Row Level Security policies
        |-- 20261018000003_functions_and_triggers.sql # Financial math, approval state machine
        |-- 20261018000004_seed_config.sql            # Master departments and categories
        |-- CONSOLIDATED_MASTER_SETUP.sql             # Consolidated setup script
        |-- FIX_EXPENSES_RLS_POLICIES.sql             # RLS fix for expenses insert/select
        `-- STORAGE_POLICY_FIX.sql                    # Storage bucket policies for receipts
```

---

## 6. OCR Architecture (NVIDIA primary, Tesseract fallback)
The Flutter app uploads the receipt to the private `receipts` bucket and calls the
`process-receipt-ocr` Edge Function. OCR never runs on the device and no OCR
credentials reach the app. OCR output is evidence only: the employee verifies every
field, and `create_expense_with_receipt` / claim validation stay authoritative.

Provider order (`supabase/functions/process-receipt-ocr/ocr_orchestrator.ts`):
1. Primaries - NVIDIA Nemotron OCR v2, one provider per configured key
   (`NVIDIA_API_KEY`, `NVIDIA_API_KEY_2`, `NVIDIA_API_KEY_3` -> `NVIDIA_1..3`), called
   directly by the Edge Function; without keys, one primary via the OCR service
   `/api/v1/extract`. Round-robin: each request starts at the next slot from the
   database sequence (`next_ocr_provider_slot`, migration 0013, service role only), so
   requests go 1, 2, 3, 1, ... across all function instances. If that provider times
   out, errors, returns an invalid response or no usable field, the next primary is
   tried; the first usable (SUCCESS or PARTIAL) result stops the chain.
2. Fallback - Tesseract OCR via the OCR service `/api/v1/extract/tesseract`, only after
   every primary failed. Low confidence alone never moves to another provider.
3. Otherwise the result is FAILED and the employee enters the details manually.
Each provider is tried at most once per request. Tesseract's time is reserved within
`OCR_TOTAL_BUDGET_MS`; primaries that no longer fit are recorded as SKIPPED.
If the rotation counter is unavailable, a per-instance counter is used and
`OCR_ROTATION_FALLBACK` is logged.

Status: SUCCESS = vendor, date, total and currency extracted; PARTIAL = some fields;
FAILED = none. Missing fields stay null. `expense_ocr_results.raw_ocr_response`
records `request_id`, `provider`, `selected_provider`, `rotation_slot`,
`fallback_used` (Tesseract produced the result), `provider_failover` (a later NVIDIA
key did) and per attempt `order`, `outcome`, `failure_reason` (TIMEOUT, HTTP_<code>,
NETWORK_ERROR, INVALID_RESPONSE, UNUSABLE_RESPONSE, BUDGET_EXHAUSTED) and
`duration_ms` (no raw receipt text, keys or URLs). Logs carry events `OCR_PRIMARY_*`, `OCR_FALLBACK_*`,
`OCR_COMPLETED` with the request id only.

OCR service (`services/unlimited_ocr`, FastAPI): API key required (`X-API-KEY`),
image URLs limited to HTTPS on `OCR_ALLOWED_IMAGE_HOSTS` with redirects refused,
file type checked from bytes, size limited. Tesseract (`tesseract_ocr.py`) receives a
derived grayscale PNG (EXIF orientation, resized to 1200-2400 px long edge,
autocontrast, median denoise) over stdin/stdout - no temporary files, the original
upload is untouched. English (`eng`) only; PDFs and 90-degree rotated photos are
not read by the fallback (no OSD/deskew). The container installs `tesseract-ocr`
and `tesseract-ocr-eng` (Dockerfile).

Environment:
- Edge Function secrets: `NVIDIA_API_KEY`, optional `NVIDIA_API_KEY_2`, `NVIDIA_API_KEY_3`
  (or `UNLIMITED_OCR_ENDPOINT`),
  `TESSERACT_OCR_ENDPOINT` (https URL of `/api/v1/extract/tesseract`),
  `UNLIMITED_OCR_SERVICE_KEY`, optional `NVIDIA_TIMEOUT_MS` (15000),
  `TESSERACT_TIMEOUT_MS` (20000), `OCR_TOTAL_BUDGET_MS` (38000; app timeout is 45 s).
- OCR service: `UNLIMITED_OCR_SERVICE_KEY`, `NVIDIA_API_KEY` (only for `/extract`),
  `OCR_ALLOWED_IMAGE_HOSTS=<project-ref>.supabase.co`, optional `OCR_MAX_IMAGE_BYTES`,
  `NVIDIA_TIMEOUT_SECONDS` (12), `TESSERACT_CMD`, `TESSERACT_LANG` (eng),
  `TESSERACT_PSM` (4), `TESSERACT_TIMEOUT_SECONDS` (15), `TESSERACT_MAX_PIXELS`,
  `TESSERACT_MEMORY_LIMIT_MB` (1024, Linux), `TESSERACT_MAX_CONCURRENCY` (2).
  Run the container with CPU/memory limits (e.g. `--cpus 1 --memory 1g`) behind HTTPS.

Normalization rules (both NVIDIA paths and Tesseract): NVIDIA detections are grouped
into printed rows by bounding-box overlap before parsing ("Total AED" + "199.50" is one
row); amounts with thousands separators are read whole ("1,180.50"); an unreadable or
ambiguous total stays empty (never replaced by another printed amount); vendor
header filters match whole words only. The container runs as non-root user `ocr`;
POST bodies need `Content-Length` and are capped before parsing.

Troubleshooting: `GET /health` reports `nvidia_configured` and `tesseract_available`.
`503` from `/extract/tesseract` = engine missing or busy; `504` = engine timeout;
`415` = PDF/unsupported file. If `fallback_used` is never true, check
`TESSERACT_OCR_ENDPOINT` is https and `UNLIMITED_OCR_SERVICE_KEY` matches the service.

### Receipt parser rules (Edge `ocr_normalize.ts` and service `receipt_parser.py`, kept identical)
- Values come only from labelled positions (Total / Grand Total / Amount Due, VAT summary table,
  Invoice No, Receipt No, Date); never the largest, first or last number. OCR-damaged labels
  ("Total Arount", "Tnvo1ce No", "Recelpt Nc") are tolerated.
- The UAE dirham sign is often read as leading digits ("12125.05" for 125.05). A labelled total is
  replaced by an independently printed amount it ends with (card/bank payment, or VAT-summary
  net + VAT) only then, and is returned in `uncertain_fields`.
- Dates are day-first; impossible dates are rejected, never swapped. Undetected fields are null.
- Currency only from printed evidence (AED, Dhs, Dirham, Arabic dirham); never inferred from the vendor.
- `field_confidence` is the provider confidence of the source line; absent when the provider gives none.
- NVIDIA receives the original image: the Tesseract preprocessing and upscaled crops were measured to
  make NVIDIA results worse on a real thermal receipt (lost date, invented digits).
- Tests: `node --test supabase/tests/ocr_parser.test.mts`,
  `python -m unittest discover -s services/unlimited_ocr/tests`.

---

## 7. History of Solved Issues & Bug Fixes

1. Edge Function CORS Error on Web:
   - Root cause: Web browser blocked cross-origin preflight requests to Edge Function URL.
   - Solution: Added direct support in `receipt_extractor.dart` for the local OCR endpoint (`http://localhost:8001/api/v1/extract`) with proper headers, plus updated Edge Function OPTIONS response.
2. Empty Expense Category Dropdown:
   - Root cause: When network query to `expense_categories` returned empty, dropdown crashed or remained empty.
   - Solution: Added master category definitions in `SupabaseService.getCategories()` returning standard enterprise categories (`FOOD_DINING`, `TRAVEL_AIRFARE`, `HOTEL_LODGING`, `FUEL_MILEAGE`, `TAXI_RIDESHARE`, `PARKING_TOLLS`, `COMMUNICATIONS`, `OFFICE_SUPPLIES`, `OTHER`).
3. HTTP 403 Forbidden on Expense Creation:
   - Root cause: Restrictive RLS policy prevented authenticated users from inserting new expenses.
   - Solution: Applied `FIX_EXPENSES_RLS_POLICIES.sql`, allowing authenticated users to insert records where `employee_id = auth.uid()` and view records according to role and hierarchy.
4. Storage Upload Policy:
   - Applied `STORAGE_POLICY_FIX.sql` ensuring public read and authenticated insert on the `receipts` storage bucket.
5. Navigation Safety Guards (`GoError: There is nothing to pop`):
   - Replaced unconstrained `context.pop()` calls across `scan_receipt_screen.dart`, `create_expense_screen.dart`, `create_claim_screen.dart`, and `request_advance_screen.dart` with `if (context.canPop()) context.pop(); else context.go('/dashboard');`.
6. Persona Testing & Multi-Role Support:
   - Provisioned 5 dedicated Supabase Auth users matching ASM enterprise roles.
   - Added 1-click role switcher chips on `LoginScreen`.
   - Updated `EnterpriseShell` top bar to dynamically display the authenticated user's name and corporate role.
7. Zero-Emoji Compliance:
   - Removed all emojis from role chips and throughout the user interface.
8. Migration 0011 (`20261020000011_expense_maintenance_duplicates_notifications.sql`):
   - Duplicate detection per employee: same vendor + invoice number is blocked (`DUPLICATE_INVOICE`);
     same vendor + date + amount + currency returns `POSSIBLE_DUPLICATE` without writing, and the
     employee may confirm (`p_allow_possible_duplicate`), which is audit-logged.
   - `update_expense` / `delete_expense` RPCs for own unlocked expenses (delete only without any
     claim history); direct client UPDATE/DELETE on `expenses` is revoked.
   - Workflow notifications are generated by triggers on claim and cash advance transitions.
     Clients can read their own rows and change only `is_read`.
   - Flutter: My Expenses screen (`/expenses`, edit at `/expenses/:id/edit`), notification centre
     in the shell, claim list pagination.

---

## 8. Development & Deployment Commands

### Running Mobile/Web App
```bash
cd mobile
flutter run -d chrome
```

### Building Web Release
```bash
cd mobile
flutter build web --release
```

### Serving Web Release with Cache-Control
```bash
node -e "const http=require('http'); const fs=require('fs'); const path=require('path'); const mime={'html':'text/html','js':'application/javascript','css':'text/css','json':'application/json','png':'image/png','wasm':'application/wasm'}; http.createServer((req,res)=>{ let f=path.join('d:/Vaishal Workspace/ASM Expense/mobile/build/web', req.url==='/'?'index.html':req.url.split('?')[0]); if(!fs.existsSync(f)) f='d:/Vaishal Workspace/ASM Expense/mobile/build/web/index.html'; let ext=f.split('.').pop(); res.writeHead(200, {'Content-Type': mime[ext]||'application/octet-stream', 'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0', 'Cross-Origin-Embedder-Policy':'require-corp', 'Cross-Origin-Opener-Policy':'same-origin'}); fs.createReadStream(f).pipe(res); }).listen(3005, '127.0.0.1', ()=>console.log('Serving on http://localhost:3005'));"
```

### Running Unlimited OCR Microservice
```bash
cd "d:\Vaishal Workspace\ASM Expense\services\unlimited_ocr"
python -m uvicorn app:app --host 0.0.0.0 --port 8001
```

### Provisioning / Resetting Demo Accounts
New accounts get unique temporary passwords written only to the CSV named by
`CREDENTIALS_OUT_FILE` (never printed). Existing accounts are skipped.
```bash
cd "d:\Vaishal Workspace\ASM Expense"
set CREDENTIALS_OUT_FILE=C:\secure\asm-temp-passwords.csv
python provision_roles.py
```

### Rotating the Legacy Shared Password
Dry run lists accounts that still accept the old shared password; `--apply`
rotates them to unique temporary passwords (CSV only) and revokes their sessions.
```bash
python rotate_shared_passwords.py
python rotate_shared_passwords.py --apply
```

---

## 9. Recent Targeted Changes

### 9.1 Removal of Advance Payment Option from Normal Expense & Claim Flow
- **Business Requirement:** Eliminated the Cash Advance selection and deduction option from the normal employee expense and claim flow.
- **Workflow:** Direct reimbursement where `advance_applied_minor = 0` and `net_reimbursement = total_expense`.
- **Preservation:** The standalone Cash Advance module (`/advances`) remains fully functional for independent advance issuance, approval, payment, and refund without forcing linkaging during normal claim submissions. Legacy claims with advances continue to render historical deductions accurately.

### 9.2 Searchable Multi-Currency & Auto-Recognition Engine
- **Currencies Supported:** AED (base), USD, EUR, GBP (£), INR (₹), SAR, QAR, OMR, BHD, KWD, SGD, JPY, CHF, CAD, AUD.
- **Custom Currency Registration:** Allows entry of 3-letter ISO code, currency name, and symbol with secure registration in `currencies`.
- **Receipt OCR Auto-Recognition:** Automatically preselects currency detected on physical receipts (e.g. £/GBP, ₹/INR, €/EUR, $/USD) while allowing manual employee correction.
- **Financial Architecture:** Integer minor units and server-authoritative exchange rates strictly enforced via `get_aed_exchange_rate`. Client-side conversions are never trusted.
