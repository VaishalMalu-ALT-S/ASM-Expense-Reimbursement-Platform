import '../models/cash_advance.dart';
import '../models/expense_claim.dart';

enum StageState { completed, current, pending, rejected, correction, cancelled }

class WorkflowStage {
  final String label;
  final StageState state;
  final String? note;

  const WorkflowStage(this.label, this.state, [this.note]);
}

/// Review stages shared by claims and advances, in workflow order.
const List<String> reviewStageKeys = ['LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW'];
const Map<String, String> reviewStageLabels = {
  'LINE_MANAGER_REVIEW': 'Line Manager',
  'HOD_REVIEW': 'Head of Department',
  'SIVA_REVIEW': 'Management',
  'FINANCE_REVIEW': 'Finance',
};

List<WorkflowStage> _build({
  required String firstLabel,
  required String payLabel,
  required String doneLabel,
  required List<String> activeReviewKeys,
  required int position, // index into [first, ...activeReviewKeys, pay, done]
  StageState haltState = StageState.current,
  String? haltNote,
}) {
  final labels = [firstLabel, ...activeReviewKeys.map((k) => reviewStageLabels[k]!), payLabel, doneLabel];
  return [
    for (var i = 0; i < labels.length; i++)
      WorkflowStage(
        labels[i],
        i < position
            ? StageState.completed
            : i == position
                ? haltState
                : StageState.pending,
        i == position ? haltNote : null,
      ),
  ];
}

int _reviewPosition(String? stageKey, List<String> activeReviewKeys) {
  final i = activeReviewKeys.indexOf(stageKey ?? '');
  return i < 0 ? 1 : i + 1;
}

/// Stage view of a claim. [haltedAtStatus] is the review status in which the
/// claim was rejected or returned (previous_status of that approval action).
/// [hasLineManager] and [hasHod] adjust the review chain dynamically so
/// managers submitting claims see their respective next reviewer (e.g. LM -> HOD -> Siva -> Finance).
List<WorkflowStage> claimStages(
  ClaimStatus status, {
  String? haltedAtStatus,
  bool settledByAdvance = false,
  bool hasLineManager = true,
  bool hasHod = true,
}) {
  const first = 'Submitted';
  const pay = 'Payment';
  const done = 'Completed';

  final activeKeys = <String>[
    if (hasLineManager) 'LINE_MANAGER_REVIEW',
    if (hasHod) 'HOD_REVIEW',
    'SIVA_REVIEW',
    'FINANCE_REVIEW',
  ];

  final payPos = 1 + activeKeys.length;
  final allDonePos = payPos + 2;

  int posForReview(String key) {
    final idx = activeKeys.indexOf(key);
    return idx >= 0 ? idx + 1 : 1;
  }

  switch (status) {
    case ClaimStatus.draft:
      return _build(firstLabel: first, payLabel: pay, doneLabel: done, activeReviewKeys: activeKeys, position: 0);
    case ClaimStatus.submitted:
    case ClaimStatus.lineManagerReview:
      return _build(firstLabel: first, payLabel: pay, doneLabel: done, activeReviewKeys: activeKeys, position: posForReview('LINE_MANAGER_REVIEW'));
    case ClaimStatus.hodReview:
      return _build(firstLabel: first, payLabel: pay, doneLabel: done, activeReviewKeys: activeKeys, position: posForReview('HOD_REVIEW'));
    case ClaimStatus.sivaReview:
      return _build(firstLabel: first, payLabel: pay, doneLabel: done, activeReviewKeys: activeKeys, position: posForReview('SIVA_REVIEW'));
    case ClaimStatus.financeReview:
      return _build(firstLabel: first, payLabel: pay, doneLabel: done, activeReviewKeys: activeKeys, position: posForReview('FINANCE_REVIEW'));
    case ClaimStatus.approved:
    case ClaimStatus.reimbursementProcessing:
      return _build(firstLabel: first, payLabel: pay, doneLabel: done, activeReviewKeys: activeKeys, position: payPos);
    case ClaimStatus.paid:
      return _build(firstLabel: first, payLabel: pay, doneLabel: done, activeReviewKeys: activeKeys, position: allDonePos);
    case ClaimStatus.settled:
      return _build(
        firstLabel: first,
        payLabel: settledByAdvance ? 'Settled against cash advance' : pay,
        doneLabel: done,
        activeReviewKeys: activeKeys,
        position: allDonePos,
      );
    case ClaimStatus.rejected:
      return _build(
        firstLabel: first,
        payLabel: pay,
        doneLabel: done,
        activeReviewKeys: activeKeys,
        position: _reviewPosition(haltedAtStatus, activeKeys),
        haltState: StageState.rejected,
        haltNote: 'Rejected',
      );
    case ClaimStatus.correctionRequired:
      return _build(
        firstLabel: first,
        payLabel: pay,
        doneLabel: done,
        activeReviewKeys: activeKeys,
        position: _reviewPosition(haltedAtStatus, activeKeys),
        haltState: StageState.correction,
        haltNote: 'Correction required',
      );
    case ClaimStatus.cancelled:
      return _build(
        firstLabel: first,
        payLabel: pay,
        doneLabel: done,
        activeReviewKeys: activeKeys,
        position: _reviewPosition(haltedAtStatus, activeKeys),
        haltState: StageState.cancelled,
        haltNote: 'Cancelled',
      );
  }
}

/// Stage view of a cash advance (request, four reviews, disbursement, settlement).
List<WorkflowStage> advanceStages(
  CashAdvanceStatus status,
  String? currentStage, {
  String? haltedAtStage,
  bool hasLineManager = true,
  bool hasHod = true,
}) {
  const first = 'Requested';
  const pay = 'Disbursement';
  const done = 'Settlement';

  final activeKeys = <String>[
    if (hasLineManager) 'LINE_MANAGER_REVIEW',
    if (hasHod) 'HOD_REVIEW',
    'SIVA_REVIEW',
    'FINANCE_REVIEW',
  ];

  final payPos = 1 + activeKeys.length;
  final allDonePos = payPos + 2;

  switch (status) {
    case CashAdvanceStatus.draft:
      return _build(firstLabel: first, payLabel: pay, doneLabel: done, activeReviewKeys: activeKeys, position: 0);
    case CashAdvanceStatus.submitted:
    case CashAdvanceStatus.underReview:
      return _build(firstLabel: first, payLabel: pay, doneLabel: done, activeReviewKeys: activeKeys, position: _reviewPosition(currentStage, activeKeys));
    case CashAdvanceStatus.approved:
      return _build(firstLabel: first, payLabel: pay, doneLabel: done, activeReviewKeys: activeKeys, position: payPos);
    case CashAdvanceStatus.paid:
    case CashAdvanceStatus.partiallySettled:
      return _build(
        firstLabel: first,
        payLabel: pay,
        doneLabel: done,
        activeReviewKeys: activeKeys,
        position: payPos + 1,
        haltNote: status == CashAdvanceStatus.partiallySettled ? 'Partially settled' : 'Awaiting expense reconciliation',
      );
    case CashAdvanceStatus.settled:
      return _build(firstLabel: first, payLabel: pay, doneLabel: done, activeReviewKeys: activeKeys, position: allDonePos);
    case CashAdvanceStatus.rejected:
      return _build(
        firstLabel: first,
        payLabel: pay,
        doneLabel: done,
        activeReviewKeys: activeKeys,
        position: _reviewPosition(haltedAtStage, activeKeys),
        haltState: StageState.rejected,
        haltNote: 'Rejected',
      );
    case CashAdvanceStatus.cancelled:
      return _build(
        firstLabel: first,
        payLabel: pay,
        doneLabel: done,
        activeReviewKeys: activeKeys,
        position: haltedAtStage == null ? 1 : _reviewPosition(haltedAtStage, activeKeys),
        haltState: StageState.cancelled,
        haltNote: 'Cancelled',
      );
  }
}

/// Display-only filter mirroring the server's stage authorization, so queues
/// show only items the signed-in user can act on. The server re-checks every action.
bool canActAtStage({
  required String? stageKey,
  required String ownerId,
  required String? ownerLineManagerId,
  required String? ownerHodId,
  required String currentUserId,
  required bool isManagement,
  required bool isFinance,
  required bool isAdmin,
}) {
  if (ownerId == currentUserId) return false;
  if (isAdmin) return reviewStageKeys.contains(stageKey);
  switch (stageKey) {
    case 'LINE_MANAGER_REVIEW':
      return ownerLineManagerId == currentUserId;
    case 'HOD_REVIEW':
      return ownerHodId == currentUserId;
    case 'SIVA_REVIEW':
      return isManagement;
    case 'FINANCE_REVIEW':
      return isFinance;
    default:
      return false;
  }
}
