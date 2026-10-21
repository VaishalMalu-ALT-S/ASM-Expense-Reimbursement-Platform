import '../../core/auth/auth_notifier.dart';
import '../../core/network/supabase_service.dart';
import '../models/cash_advance.dart';
import '../models/expense_claim.dart';
import 'approval_stages.dart';

class QueueItem {
  final String id;
  final String number;
  final String employeeName;
  final String? department;
  final String purpose;
  final int amountMinor;
  final String currency;
  final int aedMinor;
  final String stageKey;
  final bool isAdvance;
  final DateTime? submittedAt;

  const QueueItem({
    required this.id,
    required this.number,
    required this.employeeName,
    required this.department,
    required this.purpose,
    required this.amountMinor,
    required this.currency,
    required this.aedMinor,
    required this.stageKey,
    required this.isAdvance,
    required this.submittedAt,
  });

  /// Whole days since submission ("age" of the request).
  int? ageDays(DateTime now) => submittedAt == null ? null : now.difference(submittedAt!.toLocal()).inDays;
}

class ApprovalQueue {
  final List<QueueItem> claims;
  final List<QueueItem> advances;

  const ApprovalQueue(this.claims, this.advances);
}

const _ownerSelect = 'full_name, line_manager_id, hod_id, departments!employees_department_id_fkey(name)';

/// Claims and advances the signed-in user can act on at their current stage,
/// oldest first. Display filter only; every action is authorized server-side.
Future<ApprovalQueue> loadApprovalQueue({bool managementOnly = false}) async {
  final client = SupabaseService().client;
  final me = SupabaseService().currentUserId ?? '';
  final auth = AuthNotifier().state;

  bool canAct(String stage, String ownerId, Map<String, dynamic>? owner) {
    if (managementOnly && stage != 'SIVA_REVIEW') return false;
    return canActAtStage(
      stageKey: stage,
      ownerId: ownerId,
      ownerLineManagerId: owner?['line_manager_id'] as String?,
      ownerHodId: owner?['hod_id'] as String?,
      currentUserId: me,
      isManagement: auth.isManagement,
      isFinance: auth.isFinance,
      isAdmin: auth.isAdmin,
    );
  }

  String? dept(Map<String, dynamic>? owner) => (owner?['departments'] as Map<String, dynamic>?)?['name'] as String?;

  final claimRows = await client
      .from('expense_claims')
      .select('*, employees($_ownerSelect)')
      .inFilter('status', reviewStageKeys)
      .order('submitted_at', ascending: true);
  final advanceRows = await client
      .from('cash_advances')
      .select('*, employees!cash_advances_employee_id_fkey($_ownerSelect)')
      .eq('status', 'UNDER_REVIEW')
      .order('created_at', ascending: true);

  // Exclude requests the current reviewer has already approved in this cycle
  final Set<String> myApprovedClaimIds = {};
  final Set<String> myApprovedAdvIds = {};
  if (me.isNotEmpty) {
    try {
      final myClaimActions = await client
          .from('approval_actions')
          .select('claim_id')
          .eq('actor_id', me)
          .eq('action', 'APPROVE');
      for (final a in (myClaimActions as List)) {
        final cid = a['claim_id'] as String?;
        if (cid != null) myApprovedClaimIds.add(cid);
      }
    } catch (_) {}

    try {
      final myAdvActions = await client
          .from('advance_approval_actions')
          .select('advance_id')
          .eq('actor_id', me)
          .eq('action', 'APPROVE');
      for (final a in (myAdvActions as List)) {
        final aid = a['advance_id'] as String?;
        if (aid != null) myApprovedAdvIds.add(aid);
      }
    } catch (_) {}
  }

  final claims = <QueueItem>[];
  for (final row in (claimRows as List).cast<Map<String, dynamic>>()) {
    final claim = ExpenseClaim.fromJson(row);
    if (myApprovedClaimIds.contains(claim.id)) continue;
    final owner = row['employees'] as Map<String, dynamic>?;
    final stage = row['status'] as String;
    if (!canAct(stage, claim.employeeId, owner)) continue;
    claims.add(QueueItem(
      id: claim.id,
      number: claim.claimNumber,
      employeeName: claim.employeeName ?? 'Employee',
      department: dept(owner),
      purpose: '${claim.title} - ${claim.purpose}',
      amountMinor: claim.totalExpenseMinor,
      currency: 'AED',
      aedMinor: claim.totalExpenseMinor,
      stageKey: stage,
      isAdvance: false,
      submittedAt: claim.submittedAt,
    ));
  }
  final advances = <QueueItem>[];
  for (final row in (advanceRows as List).cast<Map<String, dynamic>>()) {
    final adv = CashAdvance.fromJson(row);
    if (myApprovedAdvIds.contains(adv.id)) continue;
    final owner = row['employees'] as Map<String, dynamic>?;
    final stage = adv.currentApprovalStage ?? '';
    if (!canAct(stage, adv.employeeId, owner)) continue;
    advances.add(QueueItem(
      id: adv.id,
      number: adv.advanceNumber,
      employeeName: owner?['full_name'] as String? ?? 'Employee',
      department: dept(owner),
      purpose: adv.purpose,
      amountMinor: adv.amountMinor,
      currency: adv.currencyCode,
      aedMinor: adv.aedAmountMinor,
      stageKey: stage,
      isAdvance: true,
      submittedAt: adv.createdAt,
    ));
  }
  return ApprovalQueue(claims, advances);
}
