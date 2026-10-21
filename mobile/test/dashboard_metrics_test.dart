import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asm_expense/app/theme/asm_theme.dart';
import 'package:asm_expense/shared/models/cash_advance.dart';
import 'package:asm_expense/shared/models/expense_claim.dart';
import 'package:asm_expense/shared/widgets/async_states.dart';
import 'package:asm_expense/shared/widgets/spend_summary_chart.dart';
import 'package:asm_expense/shared/widgets/status_badge.dart';
import 'package:asm_expense/shared/workflow/approval_queue.dart';
import 'package:asm_expense/shared/workflow/dashboard_metrics.dart';

ExpenseClaim claim(String status, int total, {int? net, DateTime? date}) => ExpenseClaim(
      id: '$status-$total',
      claimNumber: 'CLM-1',
      employeeId: 'e',
      title: 't',
      purpose: 'p',
      claimDate: date ?? DateTime(2026, 10, 5),
      totalExpenseMinor: total,
      netReimbursementMinor: net ?? total,
      status: ClaimStatus.fromString(status),
      createdAt: DateTime(2026, 10, 5),
    );

CashAdvance advance(String status, int aed, {int reconciled = 0, int returned = 0}) => CashAdvance(
      id: 'a',
      advanceNumber: 'ADV-1',
      employeeId: 'e',
      amountMinor: aed,
      currencyCode: 'AED',
      aedAmountMinor: aed,
      purpose: 'p',
      startDate: DateTime(2026),
      endDate: DateTime(2026),
      status: CashAdvanceStatus.fromString(status),
      reconciledAmountMinor: reconciled,
      returnedAmountMinor: returned,
      createdAt: DateTime(2026),
    );

void main() {
  final now = DateTime(2026, 10, 19);

  group('Dashboard metrics come only from real record states', () {
    final claims = [
      claim('LINE_MANAGER_REVIEW', 10000),
      claim('SIVA_REVIEW', 5000),
      claim('CORRECTION_REQUIRED', 7000),
      claim('APPROVED', 20000, net: 15000),
      claim('PAID', 30000, net: 30000),
      claim('SETTLED', 8000, net: 0),
      claim('CANCELLED', 99900),
      claim('REJECTED', 88800),
      claim('DRAFT', 77700),
    ];
    final m = DashboardMetrics.from(claims, [advance('PAID', 100000, reconciled: 80000), advance('SETTLED', 50000, reconciled: 50000)], now);

    test('in approval counts only review stages (not settled/cancelled/approved/correction)', () {
      expect(m.inReviewCount, 2);
      expect(m.inReviewMinor, 15000);
    });
    test('correction, awaiting payment and reimbursed are separate', () {
      expect(m.correctionCount, 1);
      expect(m.awaitingPaymentCount, 1);
      expect(m.awaitingPaymentMinor, 15000);
      expect(m.paidCount, 1);
      expect(m.paidMinor, 30000);
    });
    test('open advances use the unreconciled balance of paid advances only', () {
      expect(m.openAdvanceCount, 1);
      expect(m.openAdvanceBalanceMinor, 20000);
    });
    test('monthly trend excludes draft, rejected and cancelled claims', () {
      expect(m.monthly.length, 6);
      expect(m.monthly.last.label, 'OCT');
      expect(m.monthly.last.amountMinor, 10000 + 5000 + 7000 + 20000 + 30000 + 8000);
      expect(m.monthly.take(5).every((x) => x.amountMinor == 0), isTrue);
    });
    test('no claims -> no trend data (empty state instead of a chart)', () {
      expect(DashboardMetrics.from(const [], const [], now).hasTrendData, isFalse);
    });
  });

  group('Status badge', () {
    test('maps database values and display names to the same style', () {
      expect(StatusBadge.styleFor('CORRECTION_REQUIRED').fg, AsmTheme.statusWarning);
      expect(StatusBadge.styleFor('Correction Required').fg, AsmTheme.statusWarning);
      expect(StatusBadge.styleFor('Paid').fg, AsmTheme.statusApproved);
      expect(StatusBadge.styleFor('Rejected').fg, AsmTheme.statusRejected);
      expect(StatusBadge.styleFor('Cancelled').fg, AsmTheme.textSecondary);
      expect(StatusBadge.styleFor('Line Manager Review').fg, AsmTheme.statusPending);
    });
    testWidgets('status is conveyed by text and icon, not colour alone', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: StatusBadge(status: 'Correction Required'))));
      expect(find.text('CORRECTION REQUIRED'), findsOneWidget);
      expect(find.byIcon(Icons.edit_note), findsOneWidget);
    });
  });

  group('Shared UI states', () {
    testWidgets('chart renders given values only', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SpendSummaryChart(data: [MonthlyTotal('SEP', 0), MonthlyTotal('OCT', 12345)]))));
      await tester.pumpAndSettle();
      expect(find.text('SEP'), findsOneWidget);
      expect(find.text('123'), findsOneWidget);
    });
    testWidgets('error state offers retry', (tester) async {
      var retried = false;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: StateMessage.error(message: 'Could not load.', onAction: () => retried = true))));
      await tester.tap(find.text('Retry'));
      expect(retried, isTrue);
    });
    testWidgets('list entrance animation is skipped with reduced motion', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(data: MediaQueryData(disableAnimations: true), child: FadeSlideIn(index: 3, child: Text('row'))),
      ));
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
      expect(find.text('row'), findsOneWidget);
    });
  });

  test('queue age is computed from the real submission timestamp', () {
    final item = QueueItem(
      id: '1', number: 'CLM-1', employeeName: 'A', department: null, purpose: 'p', amountMinor: 1, currency: 'AED',
      aedMinor: 1, stageKey: 'LINE_MANAGER_REVIEW', isAdvance: false, submittedAt: DateTime(2026, 10, 10),
    );
    expect(item.ageDays(DateTime(2026, 10, 19)), 9);
  });
}
