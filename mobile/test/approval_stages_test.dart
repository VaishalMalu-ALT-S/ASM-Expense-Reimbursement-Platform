import 'package:flutter_test/flutter_test.dart';
import 'package:asm_expense/core/utils/money_utils.dart';
import 'package:asm_expense/shared/models/cash_advance.dart';
import 'package:asm_expense/shared/models/expense_claim.dart';
import 'package:asm_expense/shared/workflow/approval_stages.dart';

List<StageState> states(List<WorkflowStage> s) => s.map((x) => x.state).toList();

void main() {
  const c = StageState.completed, cur = StageState.current, p = StageState.pending;

  group('Claim stage timeline', () {
    test('has seven stages from submission to completion', () {
      expect(claimStages(ClaimStatus.lineManagerReview).map((s) => s.label).toList(),
          ['Submitted', 'Line Manager', 'Head of Department', 'Management', 'Finance', 'Payment', 'Completed']);
    });

    test('marks current stage for each review status', () {
      expect(states(claimStages(ClaimStatus.lineManagerReview)), [c, cur, p, p, p, p, p]);
      expect(states(claimStages(ClaimStatus.hodReview)), [c, c, cur, p, p, p, p]);
      expect(states(claimStages(ClaimStatus.sivaReview)), [c, c, c, cur, p, p, p]);
      expect(states(claimStages(ClaimStatus.financeReview)), [c, c, c, c, cur, p, p]);
      expect(states(claimStages(ClaimStatus.approved)), [c, c, c, c, c, cur, p]);
      expect(states(claimStages(ClaimStatus.paid)), everyElement(c));
    });

    test('rejection and correction are shown at the stage where they happened', () {
      expect(states(claimStages(ClaimStatus.rejected, haltedAtStatus: 'SIVA_REVIEW')),
          [c, c, c, StageState.rejected, p, p, p]);
      expect(states(claimStages(ClaimStatus.correctionRequired, haltedAtStatus: 'LINE_MANAGER_REVIEW')),
          [c, StageState.correction, p, p, p, p, p]);
    });

    test('claim settled against an advance is labelled as such', () {
      final s = claimStages(ClaimStatus.settled, settledByAdvance: true);
      expect(states(s), everyElement(c));
      expect(s[5].label, 'Settled against cash advance');
    });

    test('Line Manager submitter starts directly at Head of Department review', () {
      final s = claimStages(ClaimStatus.hodReview, hasLineManager: false, hasHod: true);
      expect(s.map((x) => x.label).toList(),
          ['Submitted', 'Head of Department', 'Management', 'Finance', 'Payment', 'Completed']);
      expect(states(s), [c, cur, p, p, p, p]);
    });

    test('HOD submitter starts directly at Management review', () {
      final s = claimStages(ClaimStatus.sivaReview, hasLineManager: false, hasHod: false);
      expect(s.map((x) => x.label).toList(),
          ['Submitted', 'Management', 'Finance', 'Payment', 'Completed']);
      expect(states(s), [c, cur, p, p, p]);
    });
  });

  group('Cash advance stage timeline', () {
    test('review stage follows current_approval_stage', () {
      expect(states(advanceStages(CashAdvanceStatus.underReview, 'HOD_REVIEW')), [c, c, cur, p, p, p, p]);
      expect(states(advanceStages(CashAdvanceStatus.underReview, 'FINANCE_REVIEW')), [c, c, c, c, cur, p, p]);
    });

    test('approved awaits disbursement; paid awaits settlement; settled completes', () {
      expect(states(advanceStages(CashAdvanceStatus.approved, 'APPROVED')), [c, c, c, c, c, cur, p]);
      expect(states(advanceStages(CashAdvanceStatus.paid, 'COMPLETED')), [c, c, c, c, c, c, cur]);
      expect(states(advanceStages(CashAdvanceStatus.settled, 'COMPLETED')), everyElement(c));
    });

    test('rejected advance shows the rejecting stage', () {
      expect(states(advanceStages(CashAdvanceStatus.rejected, 'REJECTED', haltedAtStage: 'HOD_REVIEW')),
          [c, c, StageState.rejected, p, p, p, p]);
    });
  });

  group('Approval queue visibility (display only)', () {
    bool can(String stage, {String me = 'u-me', String owner = 'u-emp', bool mgmt = false, bool fin = false, bool admin = false}) =>
        canActAtStage(
          stageKey: stage,
          ownerId: owner,
          ownerLineManagerId: 'u-lm',
          ownerHodId: 'u-hod',
          currentUserId: me,
          isManagement: mgmt,
          isFinance: fin,
          isAdmin: admin,
        );

    test('only the assigned approver sees each stage', () {
      expect(can('LINE_MANAGER_REVIEW', me: 'u-lm'), isTrue);
      expect(can('LINE_MANAGER_REVIEW', me: 'u-hod'), isFalse);
      expect(can('HOD_REVIEW', me: 'u-hod'), isTrue);
      expect(can('HOD_REVIEW', me: 'u-lm'), isFalse);
      expect(can('SIVA_REVIEW', mgmt: true), isTrue);
      expect(can('SIVA_REVIEW', fin: true), isFalse);
      expect(can('FINANCE_REVIEW', fin: true), isTrue);
      expect(can('FINANCE_REVIEW', mgmt: true), isFalse);
    });

    test('nobody sees their own item; non-review states are not actionable', () {
      expect(can('FINANCE_REVIEW', me: 'u-emp', owner: 'u-emp', fin: true), isFalse);
      expect(can('LINE_MANAGER_REVIEW', me: 'u-lm', owner: 'u-lm'), isFalse);
      expect(can('APPROVED', fin: true, admin: true), isFalse);
    });
  });

  group('Cash advance balance', () {
    test('remaining balance excludes reconciled and refunded amounts', () {
      final a = CashAdvance(
        id: 'a', advanceNumber: 'ADV-1', employeeId: 'e', amountMinor: 100000, currencyCode: 'AED',
        aedAmountMinor: 100000, purpose: 'p', startDate: DateTime(2026), endDate: DateTime(2026),
        status: CashAdvanceStatus.partiallySettled, reconciledAmountMinor: 80000, returnedAmountMinor: 15000,
        createdAt: DateTime(2026),
      );
      expect(a.remainingBalanceMinor, 5000);
    });

    test('parses current stage and returned amount from server rows', () {
      final a = CashAdvance.fromJson({
        'id': 'a', 'advance_number': 'ADV-2', 'employee_id': 'e', 'amount_minor': 10000, 'currency_code': 'USD',
        'exchange_rate': 3.6725, 'aed_amount_minor': 36725, 'purpose': 'p', 'start_date': '2026-10-01',
        'end_date': '2026-10-03', 'status': 'UNDER_REVIEW', 'current_approval_stage': 'SIVA_REVIEW',
        'returned_amount_minor': 0, 'created_at': '2026-10-01T00:00:00Z',
      });
      expect(a.currentApprovalStage, 'SIVA_REVIEW');
      expect(a.status, CashAdvanceStatus.underReview);
    });

    test('refund amount input is parsed exactly in minor units', () {
      expect(MoneyUtils.parseMinorUnits('200.00'), 20000);
      expect(MoneyUtils.parseMinorUnits('200.001'), isNull);
    });
  });
}
