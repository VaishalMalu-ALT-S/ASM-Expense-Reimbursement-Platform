enum CashAdvanceStatus {
  draft,
  submitted,
  underReview,
  approved,
  rejected,
  paid,
  partiallySettled,
  settled,
  cancelled;

  static CashAdvanceStatus fromString(String status) {
    switch (status.toUpperCase()) {
      case 'SUBMITTED':
        return CashAdvanceStatus.submitted;
      case 'UNDER_REVIEW':
        return CashAdvanceStatus.underReview;
      case 'APPROVED':
        return CashAdvanceStatus.approved;
      case 'REJECTED':
        return CashAdvanceStatus.rejected;
      case 'PAID':
        return CashAdvanceStatus.paid;
      case 'PARTIALLY_SETTLED':
        return CashAdvanceStatus.partiallySettled;
      case 'SETTLED':
        return CashAdvanceStatus.settled;
      case 'CANCELLED':
        return CashAdvanceStatus.cancelled;
      case 'DRAFT':
      default:
        return CashAdvanceStatus.draft;
    }
  }

  String get displayName {
    switch (this) {
      case CashAdvanceStatus.draft:
        return 'Draft';
      case CashAdvanceStatus.submitted:
        return 'Submitted';
      case CashAdvanceStatus.underReview:
        return 'Under Review';
      case CashAdvanceStatus.approved:
        return 'Approved';
      case CashAdvanceStatus.rejected:
        return 'Rejected';
      case CashAdvanceStatus.paid:
        return 'Paid';
      case CashAdvanceStatus.partiallySettled:
        return 'Partially Settled';
      case CashAdvanceStatus.settled:
        return 'Settled';
      case CashAdvanceStatus.cancelled:
        return 'Cancelled';
    }
  }
}

class CashAdvance {
  final String id;
  final String advanceNumber;
  final String employeeId;
  final int amountMinor;
  final String currencyCode;
  final double exchangeRate;
  final int aedAmountMinor;
  final String purpose;
  final DateTime startDate;
  final DateTime endDate;
  final CashAdvanceStatus status;
  final int reconciledAmountMinor;
  final int returnedAmountMinor;
  final String? currentApprovalStage;
  final DateTime? approvedAt;
  final DateTime? paidAt;
  final DateTime createdAt;

  const CashAdvance({
    required this.id,
    required this.advanceNumber,
    required this.employeeId,
    required this.amountMinor,
    required this.currencyCode,
    this.exchangeRate = 1.0,
    required this.aedAmountMinor,
    required this.purpose,
    required this.startDate,
    required this.endDate,
    required this.status,
    this.reconciledAmountMinor = 0,
    this.returnedAmountMinor = 0,
    this.currentApprovalStage,
    this.approvedAt,
    this.paidAt,
    required this.createdAt,
  });

  /// Balance not yet applied to approved claims or refunded (excludes
  /// reservations by claims still under review, which the server tracks).
  int get remainingBalanceMinor => aedAmountMinor - reconciledAmountMinor - returnedAmountMinor;

  factory CashAdvance.fromJson(Map<String, dynamic> json) {
    return CashAdvance(
      id: json['id'] as String,
      advanceNumber: json['advance_number'] as String? ?? 'ADV-PENDING',
      employeeId: json['employee_id'] as String,
      amountMinor: (json['amount_minor'] as num).toInt(),
      currencyCode: json['currency_code'] as String? ?? 'AED',
      exchangeRate: (json['exchange_rate'] as num?)?.toDouble() ?? 1.0,
      aedAmountMinor: (json['aed_amount_minor'] as num).toInt(),
      purpose: json['purpose'] as String? ?? '',
      startDate: DateTime.parse(json['start_date'] as String),
      endDate: DateTime.parse(json['end_date'] as String),
      status: CashAdvanceStatus.fromString(json['status'] as String? ?? 'DRAFT'),
      reconciledAmountMinor: (json['reconciled_amount_minor'] as num?)?.toInt() ?? 0,
      returnedAmountMinor: (json['returned_amount_minor'] as num?)?.toInt() ?? 0,
      currentApprovalStage: json['current_approval_stage'] as String?,
      approvedAt: json['approved_at'] != null ? DateTime.parse(json['approved_at'] as String) : null,
      paidAt: json['paid_at'] != null ? DateTime.parse(json['paid_at'] as String) : null,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
