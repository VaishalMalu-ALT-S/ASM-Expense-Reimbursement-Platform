enum ClaimStatus {
  draft,
  submitted,
  lineManagerReview,
  hodReview,
  sivaReview,
  financeReview,
  approved,
  reimbursementProcessing,
  paid,
  settled,
  rejected,
  correctionRequired,
  cancelled;

  static ClaimStatus fromString(String status) {
    switch (status.toUpperCase()) {
      case 'SUBMITTED':
        return ClaimStatus.submitted;
      case 'LINE_MANAGER_REVIEW':
        return ClaimStatus.lineManagerReview;
      case 'HOD_REVIEW':
        return ClaimStatus.hodReview;
      case 'SIVA_REVIEW':
        return ClaimStatus.sivaReview;
      case 'FINANCE_REVIEW':
        return ClaimStatus.financeReview;
      case 'APPROVED':
        return ClaimStatus.approved;
      case 'REIMBURSEMENT_PROCESSING':
        return ClaimStatus.reimbursementProcessing;
      case 'PAID':
        return ClaimStatus.paid;
      case 'SETTLED':
        return ClaimStatus.settled;
      case 'REJECTED':
        return ClaimStatus.rejected;
      case 'CORRECTION_REQUIRED':
        return ClaimStatus.correctionRequired;
      case 'CANCELLED':
        return ClaimStatus.cancelled;
      case 'DRAFT':
      default:
        return ClaimStatus.draft;
    }
  }

  String get displayName {
    switch (this) {
      case ClaimStatus.draft:
        return 'Draft';
      case ClaimStatus.submitted:
        return 'Submitted';
      case ClaimStatus.lineManagerReview:
        return 'Line Manager Review';
      case ClaimStatus.hodReview:
        return 'HOD Review';
      case ClaimStatus.sivaReview:
        return 'Management Review';
      case ClaimStatus.financeReview:
        return 'Finance Review';
      case ClaimStatus.approved:
        return 'Approved';
      case ClaimStatus.reimbursementProcessing:
        return 'Reimbursement Processing';
      case ClaimStatus.paid:
        return 'Paid';
      case ClaimStatus.settled:
        return 'Settled';
      case ClaimStatus.rejected:
        return 'Rejected';
      case ClaimStatus.correctionRequired:
        return 'Correction Required';
      case ClaimStatus.cancelled:
        return 'Cancelled';
    }
  }
}

class ExpenseClaim {
  final String id;
  final String claimNumber;
  final String employeeId;
  final String? employeeName;
  final String title;
  final String purpose;
  final DateTime claimDate;
  final String? cashAdvanceId;
  final int advanceAppliedMinor;
  final int totalExpenseMinor;
  final int netReimbursementMinor;
  final ClaimStatus status;
  final String validationStatus;
  final String? validationNotes;
  final DateTime? submittedAt;
  final DateTime? approvedAt;
  final DateTime createdAt;

  const ExpenseClaim({
    required this.id,
    required this.claimNumber,
    required this.employeeId,
    this.employeeName,
    required this.title,
    required this.purpose,
    required this.claimDate,
    this.cashAdvanceId,
    this.advanceAppliedMinor = 0,
    this.totalExpenseMinor = 0,
    this.netReimbursementMinor = 0,
    required this.status,
    this.validationStatus = 'PENDING',
    this.validationNotes,
    this.submittedAt,
    this.approvedAt,
    required this.createdAt,
  });

  factory ExpenseClaim.fromJson(Map<String, dynamic> json) {
    return ExpenseClaim(
      id: json['id'] as String,
      claimNumber: json['claim_number'] as String? ?? 'CLM-PENDING',
      employeeId: json['employee_id'] as String,
      employeeName: json['employees'] != null ? json['employees']['full_name'] as String? : null,
      title: json['title'] as String? ?? '',
      purpose: json['purpose'] as String? ?? '',
      claimDate: DateTime.parse(json['claim_date'] as String),
      cashAdvanceId: json['cash_advance_id'] as String?,
      advanceAppliedMinor: (json['advance_applied_minor'] as num?)?.toInt() ?? 0,
      totalExpenseMinor: (json['total_expense_minor'] as num?)?.toInt() ?? 0,
      netReimbursementMinor: (json['net_reimbursement_minor'] as num?)?.toInt() ?? 0,
      status: ClaimStatus.fromString(json['status'] as String? ?? 'DRAFT'),
      validationStatus: json['validation_status'] as String? ?? 'PENDING',
      validationNotes: json['validation_notes'] as String?,
      submittedAt: json['submitted_at'] != null ? DateTime.parse(json['submitted_at'] as String) : null,
      approvedAt: json['approved_at'] != null ? DateTime.parse(json['approved_at'] as String) : null,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
