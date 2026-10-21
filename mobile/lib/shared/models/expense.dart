class ExpenseCategory {
  final String id;
  final String code;
  final String name;
  final String? description;
  final bool requiresReceipt;
  final int? maxLimitMinor;

  const ExpenseCategory({
    required this.id,
    required this.code,
    required this.name,
    this.description,
    this.requiresReceipt = true,
    this.maxLimitMinor,
  });

  factory ExpenseCategory.fromJson(Map<String, dynamic> json) {
    return ExpenseCategory(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      requiresReceipt: json['requires_receipt'] as bool? ?? true,
      maxLimitMinor: json['max_limit_minor'] as int?,
    );
  }
}

class Expense {
  final String id;
  final String employeeId;
  final String categoryId;
  final String? categoryName;
  final int amountMinor;
  final String currencyCode;
  final double exchangeRate;
  final int aedAmountMinor;
  final DateTime expenseDate;
  final String vendor;
  final String? invoiceNumber;
  final int taxAmountMinor;
  final String description;
  final bool hasReceipt;
  final String? noReceiptReason;
  final bool isLocked;
  final String? receiptStoragePath;

  const Expense({
    required this.id,
    required this.employeeId,
    required this.categoryId,
    this.categoryName,
    required this.amountMinor,
    required this.currencyCode,
    this.exchangeRate = 1.0,
    required this.aedAmountMinor,
    required this.expenseDate,
    required this.vendor,
    this.invoiceNumber,
    this.taxAmountMinor = 0,
    required this.description,
    this.hasReceipt = true,
    this.noReceiptReason,
    this.isLocked = false,
    this.receiptStoragePath,
  });

  factory Expense.fromJson(Map<String, dynamic> json) {
    return Expense(
      id: json['id'] as String,
      employeeId: json['employee_id'] as String,
      categoryId: json['category_id'] as String,
      categoryName: json['expense_categories'] != null ? json['expense_categories']['name'] as String? : null,
      amountMinor: (json['amount_minor'] as num).toInt(),
      currencyCode: json['currency_code'] as String? ?? 'AED',
      exchangeRate: (json['exchange_rate'] as num?)?.toDouble() ?? 1.0,
      aedAmountMinor: (json['aed_amount_minor'] as num).toInt(),
      expenseDate: DateTime.parse(json['expense_date'] as String),
      vendor: json['vendor'] as String? ?? '',
      invoiceNumber: json['invoice_number'] as String?,
      taxAmountMinor: (json['tax_amount_minor'] as num?)?.toInt() ?? 0,
      description: json['description'] as String? ?? '',
      hasReceipt: json['has_receipt'] as bool? ?? true,
      noReceiptReason: json['no_receipt_reason'] as String?,
      isLocked: json['is_locked'] as bool? ?? false,
      receiptStoragePath: json['receipt_storage_path'] as String?,
    );
  }
}

/// A claim an expense is (or was) attached to.
class ExpenseClaimLink {
  final String expenseId;
  final String claimId;
  final String? claimNumber;
  final String? claimStatus;
  final bool isActive;

  const ExpenseClaimLink({
    required this.expenseId,
    required this.claimId,
    this.claimNumber,
    this.claimStatus,
    required this.isActive,
  });

  factory ExpenseClaimLink.fromJson(Map<String, dynamic> json) {
    final claim = json['expense_claims'] as Map?;
    return ExpenseClaimLink(
      expenseId: json['expense_id'] as String,
      claimId: json['claim_id'] as String,
      claimNumber: claim?['claim_number'] as String?,
      claimStatus: claim?['status'] as String?,
      isActive: json['released_at'] == null,
    );
  }
}

/// What the employee may still do with an expense. Mirrors the server rules in
/// update_expense / delete_expense; the server remains authoritative.
class ExpenseMaintenance {
  final bool canEdit;
  final bool canDelete;
  final ExpenseClaimLink? activeClaim;

  const ExpenseMaintenance({required this.canEdit, required this.canDelete, this.activeClaim});

  static const _editableClaimStatuses = {'DRAFT', 'CORRECTION_REQUIRED'};

  factory ExpenseMaintenance.of(Expense expense, Iterable<ExpenseClaimLink> links) {
    final own = links.where((l) => l.expenseId == expense.id).toList();
    ExpenseClaimLink? active;
    for (final l in own) {
      if (l.isActive) {
        active = l;
        break;
      }
    }
    final activeBlocksEdit = active != null && !_editableClaimStatuses.contains(active.claimStatus);
    return ExpenseMaintenance(
      canEdit: !expense.isLocked && !activeBlocksEdit,
      canDelete: !expense.isLocked && own.isEmpty,
      activeClaim: active,
    );
  }
}
