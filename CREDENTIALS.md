# ASM Expense & Reimbursement Platform - User Credentials

Standard corporate password for all demo accounts and staff:
```
Password123!
```

---

## 1. Corporate Workflow Accounts (6 Roles)
Used for testing the end-to-end multi-tier approval workflow (Submission -> Line Manager -> HOD -> Management -> Finance -> Settlement).

| Role | Name | Corporate Email | Password | Primary Workflow Responsibility |
| :--- | :--- | :--- | :--- | :--- |
| Employee | Ahmed Al Mansoori | `employee@alseermarine.com` | `Password123!` | Create expenses, upload receipts, submit claims |
| Line Manager | Tariq Al Hammadi | `manager@alseermarine.com` | `Password123!` | Tier 1 line manager review on `/approvals` |
| Head of Dept (HOD) | Dr. Khalid Al Zaabi | `hod@alseermarine.com` | `Password123!` | Tier 2 department review on `/approvals` |
| Management Approver | Siva | `management@alseermarine.com` | `Password123!` | Tier 3 executive review on `/approvals` |
| Finance Controller | Fatima Al Mazrouei | `finance@alseermarine.com` | `Password123!` | Tier 4 audit & bank payout on `/finance/reimbursements` |
| System Admin | Saeed Al Qubaisi | `admin@alseermarine.com` | `Password123!` | Policy thresholds, audit reports on `/reports` |

---

## 2. Original Company Staff Directory (18 Employees)
Imported directly from official company records. You can log in using either the raw numeric Emp ID (e.g. `37317`) or full email.

| Emp ID | Employee Full Name | Department | Primary Role | Login Username / Email | Password |
| :--- | :--- | :--- | :--- | :--- | :--- |
| 37317 | Meharoof KottileValappil | Marine Operations & Fleet (OPERATIONS) | Employee | `37317` or `37317@alseermarine.com` | `Password123!` |
| 44266 | Roldan De Vera | Marine Operations & Fleet (OPERATIONS) | Employee | `44266` or `44266@alseermarine.com` | `Password123!` |
| 23833 | Murugan Selvaraj | IML PPM (IMLPPM) | Employee | `23833` or `23833@alseermarine.com` | `Password123!` |
| 48359 | Simon Joseph Frederick Davis | IML PPM (IMLPPM) | Line Manager | `48359` or `48359@alseermarine.com` | `Password123!` |
| 34451 | Vivek Shripad Kulkarni | IML PPM (IMLPPM) | Employee | `34451` or `34451@alseermarine.com` | `Password123!` |
| 23775 | Toufeeq Jeelani | IML PPM (IMLPPM) | Employee | `23775` or `23775@alseermarine.com` | `Password123!` |
| 38135 | Hernan Je Margarico | IML PPM (IMLPPM) | Employee | `38135` or `38135@alseermarine.com` | `Password123!` |
| 43726 | Musthaque Aramullan Valiyamadathil | IML PPM (IMLPPM) | Employee | `43726` or `43726@alseermarine.com` | `Password123!` |
| 45237 | Roelito Baltazar | IML PPM (IMLPPM) | Employee | `45237` or `45237@alseermarine.com` | `Password123!` |
| 47451 | Ravindu Vichakshana Rathnayake | IML PPM (IMLPPM) | Employee | `47451` or `47451@alseermarine.com` | `Password123!` |
| 48752 | Piotr Zbigniew Targowski | ICG Supply Chain Management (ICG.SCM) | Line Manager | `48752` or `48752@alseermarine.com` | `Password123!` |
| 48690 | Muhammad Raheel Arif Sami | ICG Supply Chain Management (ICG.SCM) | Employee | `48690` or `48690@alseermarine.com` | `Password123!` |
| 29018 | Srikanth Kathula | ICG Finance (ICG.FIN) | Finance | `29018` or `29018@alseermarine.com` | `Password123!` |
| 24436 | Murtuza Ali Syed | ICG Finance (ICG.FIN) | Finance | `24436` or `24436@alseermarine.com` | `Password123!` |
| 47619 | Jessica Peters | ICG Finance (ICG.FIN) | Finance | `47619` or `47619@alseermarine.com` | `Password123!` |
| 42421 | Prashant Wagadre | ICG Finance (ICG.FIN) | Finance | `42421` or `42421@alseermarine.com` | `Password123!` |
| 48407 | Nishadi Dilhari Thalangodalage | ICG Finance (ICG.FIN) | Finance | `48407` or `48407@alseermarine.com` | `Password123!` |
| 50312 | Sebin Vadakkemelathil Thankachan | ASM Integration (ASM.Integration) | Employee | `50312` or `50312@alseermarine.com` | `Password123!` |

---

## 3. Web Access Details
- Local Web URL: `http://localhost:3005`
- Sign-In Hint: The username field accepts either the numeric Emp ID (e.g. `37317`) or full email (`37317@alseermarine.com`).
- Fast Testing: Quick 1-click fill buttons are available directly on the login card.
