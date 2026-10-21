# ASM Expense & Reimbursement — Enterprise Design System Specification

## 1. Visual Language & Information Architecture Synthesis

Based on the attached enterprise reference screenshots (Zoho Expense, SAP Concur benchmarks, Modern Financial SaaS App UI):

### A. Enterprise Desktop / Web Architecture (Screenshots 1 & 2)
- **Top Utility Header (`#0F1E36` / `#0D253F`)**:
  - Left: Clean text-based ASM Identity (`AL SEER MARINE` + `Expense`)
  - Center: Global compact search bar (`Ctrl+K` style, rounded-sm, neutral background)
  - Right: Quick Action `+`, Notification bell badge, Organization switcher (`Al Seer Marine`), User profile pill.
- **Left Collapsible Navigation Sidebar**:
  - Compact icon + label vertical navigation.
  - Active state: Subtle brand fill (`#1E3A5F` / `#2563EB`) with clean left indicator bar.
  - Distinct sections: Main Navigation (Dashboard, Expenses, Claims, Advances, Approvals, Reimbursements, Reports) and Settings/Admin view.
- **Main Content Canvas (`#F8FAFC` / Surface Light)**:
  - 24px grid gutter, 16px card paddings, subtle 1px border (`#E2E8F0`).
  - Dual layout: **Spend Summary Line Chart** alongside **Overall Summary Financial KPIs**.
  - Secondary grid: **Pending Trips / Claims Approvals** queue + **Unreported Advances** ledger cards.

### B. Mobile Enterprise Architecture (Screenshots 3 & 4)
- **Compact Header & Status Card**:
  - Dark Navy slate hero card containing Report ID (`#CLM-0001`), Total Amount in high-contrast bold typography (`AED 4,589.80`), and micro status pill (`SUBMITTED`).
  - Approver chips showing assigned reviewer and pending step.
- **Tabbed Segmented Content (`Expenses` | `Comments` | `History`)**:
  - Clean underlined tab switcher with neutral active state.
- **Receipt & Expense Row Items**:
  - Thumbnail receipt preview on left.
  - Category, vendor, date, and micro-status badge.
  - High visual hierarchy bold amount on right.
- **Persistent Bottom Action Bar**:
  - Sticky full-width primary action button (`Approve report` / `Submit Claim`).
  - Bottom Navigation bar with elevated central action button (`+`).

---

## 2. Tokenized Color & Style Standards

| Token | Hex / Value | Usage |
| :--- | :--- | :--- |
| `primaryNavy` | `#0D253F` | Primary corporate brand, AppBars, headers, primary buttons |
| `darkBackground` | `#091624` | Top utility headers, hero report card backgrounds |
| `accentGold` | `#C5A059` | Al Seer Marine corporate accent |
| `surfaceBackground` | `#F8FAFC` | Light neutral page canvas |
| `surfaceCard` | `#FFFFFF` | Content containers, cards, tables |
| `borderLight` | `#E2E8F0` | Card borders, dividers, table cell lines |
| `textHeading` | `#0F172A` | Page titles, KPI numbers, vendor names |
| `textBody` | `#334155` | Regular content, input fields |
| `textMuted` | `#64748B` | Labels, captions, dates, invoice numbers |
| `statusPending` | `#D97706` | Awaiting review, pending action badges |
| `statusApproved` | `#059669` | Approved, reimbursed, settled badges |
| `statusRejected` | `#DC2626` | Rejected, over-limit, error alerts |
| `statusInfo` | `#2563EB` | Active claim, in-progress step |

---

## 3. Screen Inventory & Implementation Mapping

1. **Responsive Shell (`EnterpriseShell`)**:
   - Web/Desktop: Top Header + Left Navigation Sidebar + Content Canvas.
   - Mobile: Mobile AppBar + Bottom Navigation (`Home`, `Expenses`, `+`, `Claims`, `Approvals`).
2. **Dashboard (`DashboardScreen`)**:
   - Executive Spend KPI cards (Total Spent, Pending Approvals, Awaiting Reimbursement, Active Advances).
   - Interactive Spend Summary Chart with custom painter line chart matching reference.
   - Pending Approvals List and Recent Expenses Ledger.
3. **Expense Claims Hub (`ClaimDetailScreen` & `CreateClaimScreen`)**:
   - Hero Report Card with total amount, status badge, and reviewer metadata.
   - Segmented Tabs: `Expenses`, `Approval Flow`, `Reconciliation`.
   - Vertical Step Timeline (`Line Manager` -> `HOD` -> `Management` -> `Finance`).
4. **Receipt Scanner & OCR (`ScanReceiptScreen`)**:
   - Side-by-side or stacked receipt thumbnail preview with clean field verification.
5. **Manager Approvals Queue (`ManagerApprovalScreen`)**:
   - Filterable pending review queue with one-click actions (`Approve`, `Correction`, `Reject`).
6. **Finance Reimbursement Portal (`FinanceReimbursementScreen`)**:
   - Professional ledger table with bank transfer settlement workflows.
