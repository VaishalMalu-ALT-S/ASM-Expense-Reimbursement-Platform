import 'package:intl/intl.dart';
import '../models/cash_advance.dart';
import '../models/expense_claim.dart';
import '../widgets/spend_summary_chart.dart';

/// Employee dashboard figures derived from the user's own claims and advances
/// exactly as stored (server-computed totals); nothing is estimated.
class DashboardMetrics {
  static const inReviewStatuses = {
    ClaimStatus.submitted,
    ClaimStatus.lineManagerReview,
    ClaimStatus.hodReview,
    ClaimStatus.sivaReview,
    ClaimStatus.financeReview,
  };
  static const awaitingPaymentStatuses = {ClaimStatus.approved, ClaimStatus.reimbursementProcessing};
  static const excludedFromTrend = {ClaimStatus.draft, ClaimStatus.cancelled, ClaimStatus.rejected};

  final int inReviewCount;
  final int inReviewMinor;
  final int correctionCount;
  final int awaitingPaymentCount;
  final int awaitingPaymentMinor;
  final int paidCount;
  final int paidMinor;
  final int openAdvanceCount;
  final int openAdvanceBalanceMinor;
  final List<MonthlyTotal> monthly;

  const DashboardMetrics._({
    required this.inReviewCount,
    required this.inReviewMinor,
    required this.correctionCount,
    required this.awaitingPaymentCount,
    required this.awaitingPaymentMinor,
    required this.paidCount,
    required this.paidMinor,
    required this.openAdvanceCount,
    required this.openAdvanceBalanceMinor,
    required this.monthly,
  });

  bool get hasTrendData => monthly.any((m) => m.amountMinor > 0);

  factory DashboardMetrics.from(List<ExpenseClaim> claims, List<CashAdvance> advances, DateTime now, {int months = 6}) {
    final inReview = claims.where((c) => inReviewStatuses.contains(c.status));
    final awaiting = claims.where((c) => awaitingPaymentStatuses.contains(c.status));
    final paid = claims.where((c) => c.status == ClaimStatus.paid);
    final openAdvances = advances.where((a) =>
        (a.status == CashAdvanceStatus.paid || a.status == CashAdvanceStatus.partiallySettled) && a.remainingBalanceMinor > 0);

    final monthly = <MonthlyTotal>[];
    for (var i = months - 1; i >= 0; i--) {
      final start = DateTime(now.year, now.month - i, 1);
      final end = DateTime(start.year, start.month + 1, 1);
      final total = claims
          .where((c) => !excludedFromTrend.contains(c.status) && !c.claimDate.isBefore(start) && c.claimDate.isBefore(end))
          .fold<int>(0, (s, c) => s + c.totalExpenseMinor);
      monthly.add(MonthlyTotal(DateFormat('MMM').format(start).toUpperCase(), total));
    }

    int sum(Iterable<ExpenseClaim> list, int Function(ExpenseClaim) f) => list.fold<int>(0, (s, c) => s + f(c));
    return DashboardMetrics._(
      inReviewCount: inReview.length,
      inReviewMinor: sum(inReview, (c) => c.totalExpenseMinor),
      correctionCount: claims.where((c) => c.status == ClaimStatus.correctionRequired).length,
      awaitingPaymentCount: awaiting.length,
      awaitingPaymentMinor: sum(awaiting, (c) => c.netReimbursementMinor),
      paidCount: paid.length,
      paidMinor: sum(paid, (c) => c.netReimbursementMinor),
      openAdvanceCount: openAdvances.length,
      openAdvanceBalanceMinor: openAdvances.fold<int>(0, (s, a) => s + a.remainingBalanceMinor),
      monthly: monthly,
    );
  }
}
