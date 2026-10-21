import 'package:flutter_test/flutter_test.dart';
import 'package:asm_expense/shared/models/app_notification.dart';
import 'package:asm_expense/shared/models/expense.dart';

Expense _expense({String id = 'e1', bool locked = false}) => Expense(
      id: id,
      employeeId: 'u1',
      categoryId: 'c1',
      amountMinor: 1000,
      currencyCode: 'AED',
      aedAmountMinor: 1000,
      expenseDate: DateTime(2026, 10, 1),
      vendor: 'Vendor',
      description: 'Purpose',
      isLocked: locked,
    );

ExpenseClaimLink _link(String status, {bool active = true, String expenseId = 'e1'}) => ExpenseClaimLink(
      expenseId: expenseId,
      claimId: 'k1',
      claimNumber: 'CLM-1',
      claimStatus: status,
      isActive: active,
    );

AppNotification _note(String entityType, String event) => AppNotification(
      id: 'n1',
      title: 't',
      body: 'b',
      eventType: event,
      entityType: entityType,
      entityId: 'x1',
      isRead: false,
      createdAt: DateTime(2026, 10, 1),
    );

void main() {
  group('ExpenseMaintenance', () {
    test('unattached expense can be edited and deleted', () {
      final m = ExpenseMaintenance.of(_expense(), const []);
      expect(m.canEdit, isTrue);
      expect(m.canDelete, isTrue);
      expect(m.activeClaim, isNull);
    });

    test('locked expense can be neither edited nor deleted', () {
      final m = ExpenseMaintenance.of(_expense(locked: true), const []);
      expect(m.canEdit, isFalse);
      expect(m.canDelete, isFalse);
    });

    test('expense in a claim under review cannot be edited', () {
      final m = ExpenseMaintenance.of(_expense(), [_link('LINE_MANAGER_REVIEW')]);
      expect(m.canEdit, isFalse);
      expect(m.canDelete, isFalse);
      expect(m.activeClaim?.claimNumber, 'CLM-1');
    });

    test('expense in a correction-required claim is editable but kept for history', () {
      final m = ExpenseMaintenance.of(_expense(), [_link('CORRECTION_REQUIRED')]);
      expect(m.canEdit, isTrue);
      expect(m.canDelete, isFalse);
    });

    test('released link from a rejected claim blocks delete only', () {
      final m = ExpenseMaintenance.of(_expense(), [_link('REJECTED', active: false)]);
      expect(m.canEdit, isTrue);
      expect(m.canDelete, isFalse);
      expect(m.activeClaim, isNull);
    });

    test('links of other expenses are ignored', () {
      final m = ExpenseMaintenance.of(_expense(), [_link('LINE_MANAGER_REVIEW', expenseId: 'other')]);
      expect(m.canEdit, isTrue);
      expect(m.canDelete, isTrue);
    });

    test('ExpenseClaimLink parses nested claim and release state', () {
      final l = ExpenseClaimLink.fromJson({
        'expense_id': 'e1',
        'claim_id': 'k1',
        'released_at': '2026-10-01T00:00:00Z',
        'expense_claims': {'claim_number': 'CLM-9', 'status': 'REJECTED'},
      });
      expect(l.isActive, isFalse);
      expect(l.claimNumber, 'CLM-9');
      expect(l.claimStatus, 'REJECTED');
    });
  });

  group('AppNotification.route', () {
    test('approval requests open the approval queue', () {
      expect(_note('expense_claim', 'CLAIM_APPROVAL_REQUIRED').route, '/approvals');
    });
    test('owner claim events open the claim', () {
      expect(_note('expense_claim', 'CLAIM_REJECTED').route, '/claims/x1');
    });
    test('finance payment events open the settlement screen', () {
      expect(_note('expense_claim', 'REIMBURSEMENT_PAYMENT_REQUIRED').route, '/finance/reimbursements');
      expect(_note('cash_advance', 'ADVANCE_DISBURSEMENT_REQUIRED').route, '/finance/reimbursements');
    });
    test('advance events open the advance', () {
      expect(_note('cash_advance', 'ADVANCE_APPROVAL_REQUIRED').route, '/advances/x1');
    });
    test('unknown entity has no route', () {
      expect(_note('something_else', 'X').route, isNull);
    });
  });
}
