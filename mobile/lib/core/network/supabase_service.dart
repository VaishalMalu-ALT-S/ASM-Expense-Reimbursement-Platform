import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../shared/models/employee.dart';
import '../../shared/models/expense.dart';
import '../../shared/models/expense_claim.dart';
import '../../shared/models/cash_advance.dart';
import '../../shared/models/app_notification.dart';

/// Central Supabase Repository managing authentication, state, and server calls.
class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  SupabaseClient get client => Supabase.instance.client;

  bool get isAuthenticated => client.auth.currentSession != null;
  String? get currentUserId => client.auth.currentUser?.id;

  /// Sign in with corporate email and password
  Future<AuthResponse> signIn(String email, String password) async {
    return await client.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  /// Sign out
  Future<void> signOut() async {
    await client.auth.signOut();
  }

  /// Fetch current authenticated employee profile and associated roles
  Future<Employee?> getCurrentEmployee() async {
    final uid = currentUserId;
    if (uid == null) return null;

    try {
      final res = await client
          .from('employees')
          .select('*, departments!employees_department_id_fkey(name), designations(title)')
          .eq('id', uid)
          .maybeSingle();

      if (res == null) return null;

      final roleRes = await client
          .from('employee_roles')
          .select('role')
          .eq('employee_id', uid);

      final roles = (roleRes as List)
          .map((r) => AppRole.fromString(r['role'] as String))
          .toList();

      if (roles.isEmpty) {
        roles.add(AppRole.employee);
      }

      return Employee.fromJson(res, roles);
    } catch (e) {
      debugPrint('Error fetching employee profile: $e');
      return null;
    }
  }

  /// Fetch active expense categories
  Future<List<ExpenseCategory>> getCategories() async {
    try {
      final res = await client
          .from('expense_categories')
          .select()
          .eq('is_active', true)
          .order('name');
      return (res as List).map((c) => ExpenseCategory.fromJson(c)).toList();
    } catch (e) {
      debugPrint('Expense categories unavailable: $e');
      return const [];
    }
  }

  /// Fetch current user's expenses
  Future<List<Expense>> getMyExpenses() async {
    final uid = currentUserId;
    if (uid == null) return [];

    final res = await client
        .from('expenses')
        .select('*, expense_categories(name)')
        .eq('employee_id', uid)
        .order('created_at', ascending: false);

    return (res as List).map((e) => Expense.fromJson(e)).toList();
  }

  /// Fetch all expenses visible to the authenticated user under Supabase RLS.
  /// For employees, returns own expenses; for managers, includes direct reports;
  /// for HOD/Management/Finance, includes department/company expenses.
  Future<List<Expense>> getVisibleExpenses() async {
    final res = await client
        .from('expenses')
        .select('*, expense_categories(name)')
        .order('created_at', ascending: false);

    return (res as List).map((e) => Expense.fromJson(e)).toList();
  }

  /// Create an expense (and link its receipt + OCR result) in one server
  /// transaction. Exchange rate and AED amount are computed server-side.
  /// Reusing [idempotencyKey] on retry returns the original expense.
  Future<Map<String, dynamic>> createExpense({
    required String idempotencyKey,
    required String categoryId,
    required int amountMinor,
    required String currencyCode,
    required DateTime expenseDate,
    required String vendor,
    String? invoiceNumber,
    int taxAmountMinor = 0,
    required String description,
    String? noReceiptReason,
    String? receiptStoragePath,
    String? receiptFileName,
    int? receiptTotalMinor,
    bool allowPossibleDuplicate = false,
  }) async {
    final params = <String, dynamic>{
      'p_idempotency_key': idempotencyKey,
      'p_category_id': categoryId,
      'p_amount_minor': amountMinor,
      'p_currency_code': currencyCode,
      'p_expense_date': expenseDate.toIso8601String().split('T')[0],
      'p_vendor': vendor,
      'p_description': description,
      'p_invoice_number': invoiceNumber,
      'p_tax_amount_minor': taxAmountMinor,
      'p_no_receipt_reason': noReceiptReason,
      'p_receipt_storage_path': receiptStoragePath,
      'p_receipt_file_name': receiptFileName,
      'p_receipt_total_minor': receiptTotalMinor,
    };
    // Only sent after the employee confirms a POSSIBLE_DUPLICATE warning.
    if (allowPossibleDuplicate) params['p_allow_possible_duplicate'] = true;
    final res = await client.rpc('create_expense_with_receipt', params: params);
    return Map<String, dynamic>.from(res as Map);
  }

  /// Single expense of the current user, or null when not visible.
  Future<Expense?> getExpense(String expenseId) async {
    final res = await client
        .from('expenses')
        .select('*, expense_categories(name)')
        .eq('id', expenseId)
        .maybeSingle();
    return res == null ? null : Expense.fromJson(res);
  }

  /// Edit an unlocked expense. For receipted expenses the receipt total is
  /// updated in the same server transaction.
  Future<Map<String, dynamic>> updateExpense({
    required String expenseId,
    required String categoryId,
    required int amountMinor,
    required String currencyCode,
    required DateTime expenseDate,
    required String vendor,
    required String description,
    String? invoiceNumber,
    int taxAmountMinor = 0,
    String? noReceiptReason,
    int? receiptTotalMinor,
  }) async {
    final res = await client.rpc('update_expense', params: {
      'p_expense_id': expenseId,
      'p_category_id': categoryId,
      'p_amount_minor': amountMinor,
      'p_currency_code': currencyCode,
      'p_expense_date': expenseDate.toIso8601String().split('T')[0],
      'p_vendor': vendor,
      'p_description': description,
      'p_invoice_number': invoiceNumber,
      'p_tax_amount_minor': taxAmountMinor,
      'p_no_receipt_reason': noReceiptReason,
      'p_receipt_total_minor': receiptTotalMinor,
    });
    return Map<String, dynamic>.from(res as Map);
  }

  /// Delete an expense that has never been part of a claim.
  Future<Map<String, dynamic>> deleteExpense(String expenseId) async {
    final res = await client.rpc('delete_expense', params: {'p_expense_id': expenseId});
    return Map<String, dynamic>.from(res as Map);
  }

  /// Claim links for the given expenses (active and released), newest first.
  Future<List<ExpenseClaimLink>> getExpenseClaimLinks(List<String> expenseIds) async {
    if (expenseIds.isEmpty) return const [];
    final res = await client
        .from('claim_expenses')
        .select('expense_id, claim_id, released_at, expense_claims(claim_number, status)')
        .inFilter('expense_id', expenseIds)
        .order('added_at', ascending: false);
    return (res as List).map((r) => ExpenseClaimLink.fromJson(Map<String, dynamic>.from(r as Map))).toList();
  }

  /// Create a claim, attach expenses and submit it for approval atomically.
  /// Totals are computed server-side; reusing [idempotencyKey] on retry
  /// returns the original claim instead of creating a duplicate.
  Future<Map<String, dynamic>> createAndSubmitClaim({
    required String idempotencyKey,
    required String title,
    required String purpose,
    required List<String> expenseIds,
    String? cashAdvanceId,
  }) async {
    final res = await client.rpc('create_and_submit_claim', params: {
      'p_idempotency_key': idempotencyKey,
      'p_title': title,
      'p_purpose': purpose,
      'p_expense_ids': expenseIds,
      'p_cash_advance_id': cashAdvanceId,
    });
    return Map<String, dynamic>.from(res as Map);
  }

  /// Fetch user's claims
  Future<List<ExpenseClaim>> getMyClaims() async {
    final uid = currentUserId;
    if (uid == null) return [];

    final res = await client
        .from('expense_claims')
        .select('*, employees(full_name)')
        .eq('employee_id', uid)
        .order('created_at', ascending: false);

    return (res as List).map((c) => ExpenseClaim.fromJson(c)).toList();
  }

  /// Fetch all claims visible to the authenticated user under Supabase RLS.
  /// For employees, returns own claims; for managers, includes direct reports;
  /// for HOD/Management/Finance, includes department/company claims.
  Future<List<ExpenseClaim>> getVisibleClaims() async {
    final res = await client
        .from('expense_claims')
        .select('*, employees(full_name)')
        .order('created_at', ascending: false);

    return (res as List).map((c) => ExpenseClaim.fromJson(c)).toList();
  }

  /// One page of the user's claims, newest first.
  Future<List<ExpenseClaim>> getMyClaimsPage({required int offset, int limit = 50}) async {
    final uid = currentUserId;
    if (uid == null) return [];
    final res = await client
        .from('expense_claims')
        .select('*, employees(full_name)')
        .eq('employee_id', uid)
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    return (res as List).map((c) => ExpenseClaim.fromJson(c)).toList();
  }

  /// Latest in-app notifications for the current user (RLS limits to own rows).
  Future<List<AppNotification>> getNotifications({int limit = 50}) async {
    final res = await client
        .from('notifications')
        .select()
        .order('created_at', ascending: false)
        .limit(limit);
    return (res as List).map((n) => AppNotification.fromJson(Map<String, dynamic>.from(n as Map))).toList();
  }

  Future<int> getUnreadNotificationCount() async {
    final res = await client
        .from('notifications')
        .select('id')
        .eq('is_read', false)
        .count(CountOption.exact);
    return res.count;
  }

  Future<void> markNotificationsRead(List<String> ids) async {
    if (ids.isEmpty) return;
    await client.from('notifications').update({'is_read': true}).inFilter('id', ids);
  }

  /// Resubmit a claim returned for correction with its corrected expense set
  /// and advance. Revalidation and totals run server-side in one transaction.
  Future<Map<String, dynamic>> resubmitCorrectedClaim({
    required String claimId,
    required String idempotencyKey,
    required List<String> expenseIds,
    String? cashAdvanceId,
    String? title,
    String? purpose,
  }) async {
    final res = await client.rpc('resubmit_corrected_claim', params: {
      'p_claim_id': claimId,
      'p_idempotency_key': idempotencyKey,
      'p_expense_ids': expenseIds,
      'p_cash_advance_id': cashAdvanceId,
      'p_title': title,
      'p_purpose': purpose,
    });
    return Map<String, dynamic>.from(res as Map);
  }

  /// Expense ids that are actively attached to a claim, mapped to that claim.
  Future<Map<String, String>> getActiveClaimLinks(List<String> expenseIds) async {
    if (expenseIds.isEmpty) return {};
    final res = await client
        .from('claim_expenses')
        .select('expense_id, claim_id')
        .isFilter('released_at', null)
        .inFilter('expense_id', expenseIds);
    return {
      for (final row in (res as List)) row['expense_id'] as String: row['claim_id'] as String,
    };
  }

  /// Fetch user's cash advances
  Future<List<CashAdvance>> getMyAdvances() async {
    final uid = currentUserId;
    if (uid == null) return [];

    final res = await client
        .from('cash_advances')
        .select()
        .eq('employee_id', uid)
        .order('created_at', ascending: false);

    return (res as List).map((a) => CashAdvance.fromJson(a)).toList();
  }

  /// Fetch all cash advances visible to the authenticated user under Supabase RLS.
  Future<List<CashAdvance>> getVisibleAdvances() async {
    final res = await client
        .from('cash_advances')
        .select()
        .order('created_at', ascending: false);

    return (res as List).map((a) => CashAdvance.fromJson(a)).toList();
  }

  /// Request a cash advance. Exchange rate and AED amount are computed
  /// server-side; reusing [idempotencyKey] on retry returns the original request.
  Future<Map<String, dynamic>> createCashAdvance({
    required String idempotencyKey,
    required int amountMinor,
    required String currencyCode,
    required String purpose,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final res = await client.rpc('request_cash_advance', params: {
      'p_amount_minor': amountMinor,
      'p_currency_code': currencyCode,
      'p_purpose': purpose,
      'p_start_date': startDate.toIso8601String().split('T')[0],
      'p_end_date': endDate.toIso8601String().split('T')[0],
      'p_idempotency_key': idempotencyKey,
    });
    return Map<String, dynamic>.from(res as Map);
  }

  /// Short-lived signed URL for a receipt; storage policies decide access.
  Future<String?> receiptSignedUrl(String storagePath) async {
    try {
      return await client.storage.from('receipts').createSignedUrl(storagePath, 300);
    } catch (_) {
      return null;
    }
  }

  /// Cancel an expense claim
  Future<bool> cancelExpenseClaim(String claimId, String reason) async {
    final res = await client.rpc('cancel_expense_claim', params: {
      'p_claim_id': claimId,
      'p_cancellation_reason': reason,
    });
    return res != null && res['success'] == true;
  }

  /// Review cash advance (Option 2: LM -> HOD -> Siva/Management -> Finance)
  Future<Map<String, dynamic>> reviewCashAdvance({
    required String advanceId,
    required String action, // 'APPROVE' or 'REJECT'
    String? comments,
  }) async {
    final res = await client.rpc('review_cash_advance', params: {
      'p_advance_id': advanceId,
      'p_action': action,
      'p_comments': comments,
    });
    return Map<String, dynamic>.from(res as Map);
  }

  /// Record cash advance payment disbursement (Finance only)
  Future<Map<String, dynamic>> recordCashAdvancePayment({
    required String advanceId,
    required String paymentReference,
    String paymentMethod = 'BANK_TRANSFER',
    String? notes,
  }) async {
    final res = await client.rpc('record_cash_advance_payment', params: {
      'p_advance_id': advanceId,
      'p_payment_reference': paymentReference,
      'p_payment_method': paymentMethod,
      'p_notes': notes,
    });
    return Map<String, dynamic>.from(res as Map);
  }

  /// Record leftover cash advance refund (Option A: Finance only)
  Future<Map<String, dynamic>> recordCashAdvanceRefund({
    required String advanceId,
    required int refundAmountMinor,
    required String refundReference,
    DateTime? refundDate,
    String paymentMethod = 'BANK_TRANSFER',
    String? notes,
    String? idempotencyKey,
  }) async {
    final params = <String, dynamic>{
      'p_advance_id': advanceId,
      'p_refund_amount_minor': refundAmountMinor,
      'p_refund_reference': refundReference,
      'p_refund_date': (refundDate ?? DateTime.now()).toIso8601String().split('T')[0],
      'p_payment_method': paymentMethod,
      'p_notes': notes,
    };
    if (idempotencyKey != null) {
      params['p_idempotency_key'] = idempotencyKey;
    }
    final res = await client.rpc('record_cash_advance_refund', params: params);
    return Map<String, dynamic>.from(res as Map);
  }

  /// Cancel cash advance request (Requester or Admin before payment)
  Future<Map<String, dynamic>> cancelCashAdvance({
    required String advanceId,
    required String reason,
  }) async {
    final res = await client.rpc('cancel_cash_advance', params: {
      'p_advance_id': advanceId,
      'p_cancellation_reason': reason,
    });
    return Map<String, dynamic>.from(res as Map);
  }

  // ==========================================================================
  // ADMIN GOVERNANCE & CONTROL SUITE
  // ==========================================================================

  /// Fetch all employees with department, designation, and roles
  Future<List<Employee>> getAllEmployeesWithRoles() async {
    try {
      final res = await client
          .from('employees')
          .select('*, departments!employees_department_id_fkey(name), designations(title)')
          .order('full_name');

      final roleRes = await client.from('employee_roles').select('employee_id, role');
      final Map<String, List<AppRole>> employeeRolesMap = {};

      for (final r in (roleRes as List)) {
        final empId = r['employee_id'] as String;
        final role = AppRole.fromString(r['role'] as String);
        employeeRolesMap.putIfAbsent(empId, () => []).add(role);
      }

      return (res as List).map((e) {
        final empId = e['id'] as String;
        final roles = employeeRolesMap[empId] ?? [AppRole.employee];
        return Employee.fromJson(e, roles);
      }).toList();
    } catch (e) {
      debugPrint('Error fetching all employees: $e');
      return [];
    }
  }

  /// Update an employee's assigned roles in employee_roles
  Future<bool> updateEmployeeRoles(String employeeId, List<AppRole> newRoles) async {
    try {
      // 1. Delete existing roles
      await client.from('employee_roles').delete().eq('employee_id', employeeId);

      // 2. Insert new roles
      final rolesToInsert = newRoles.map((role) {
        String roleStr;
        switch (role) {
          case AppRole.admin:
            roleStr = 'ADMIN';
            break;
          case AppRole.finance:
            roleStr = 'FINANCE';
            break;
          case AppRole.management:
            roleStr = 'MANAGEMENT';
            break;
          case AppRole.departmentManager:
            roleStr = 'DEPARTMENT_MANAGER';
            break;
          case AppRole.lineManager:
            roleStr = 'LINE_MANAGER';
            break;
          case AppRole.employee:
            roleStr = 'EMPLOYEE';
            break;
        }
        return {
          'employee_id': employeeId,
          'role': roleStr,
        };
      }).toList();

      if (rolesToInsert.isNotEmpty) {
        await client.from('employee_roles').insert(rolesToInsert);
      }

      return true;
    } catch (e) {
      debugPrint('Error updating employee roles: $e');
      return false;
    }
  }

  /// Toggle employee active status
  Future<bool> toggleEmployeeActive(String employeeId, bool isActive) async {
    try {
      await client.from('employees').update({'is_active': isActive}).eq('id', employeeId);
      return true;
    } catch (e) {
      debugPrint('Error updating employee status: $e');
      return false;
    }
  }

  /// Fetch system audit logs
  Future<List<Map<String, dynamic>>> getAuditLogs({int limit = 60}) async {
    try {
      final res = await client
          .from('audit_logs')
          .select('*, employees:actor_user_id(full_name, email, employee_code)')
          .order('created_at', ascending: false)
          .limit(limit);

      return (res as List).map((l) => Map<String, dynamic>.from(l as Map)).toList();
    } catch (e) {
      debugPrint('Error fetching audit logs: $e');
      return [];
    }
  }

  /// Fetch all pending claims company-wide for Admin inspection/override
  Future<List<Map<String, dynamic>>> getAllPendingClaimsCompanyWide() async {
    try {
      final res = await client
          .from('expense_claims')
          .select('*, employees:employee_id(full_name, employee_code, email)')
          .inFilter('status', ['LINE_MANAGER_REVIEW', 'HOD_REVIEW', 'SIVA_REVIEW', 'FINANCE_REVIEW'])
          .order('created_at', ascending: false);

      return (res as List).map((c) => Map<String, dynamic>.from(c as Map)).toList();
    } catch (e) {
      debugPrint('Error fetching company-wide pending claims: $e');
      return [];
    }
  }

  /// Fetch all pending advances company-wide for Admin inspection/override
  Future<List<Map<String, dynamic>>> getAllPendingAdvancesCompanyWide() async {
    try {
      final res = await client
          .from('cash_advances')
          .select('*, employees:employee_id(full_name, employee_code, email)')
          .inFilter('status', [
            'LINE_MANAGER_REVIEW',
            'HOD_REVIEW',
            'SIVA_REVIEW',
            'FINANCE_REVIEW',
            'APPROVED_PENDING_DISBURSEMENT'
          ])
          .order('created_at', ascending: false);

      return (res as List).map((a) => Map<String, dynamic>.from(a as Map)).toList();
    } catch (e) {
      debugPrint('Error fetching company-wide pending advances: $e');
      return [];
    }
  }

  /// Fetch all active policy rules
  Future<List<Map<String, dynamic>>> getAllPolicyRules() async {
    try {
      final res = await client
          .from('policy_rules')
          .select('*, policies(title, code)')
          .order('rule_key');

      return (res as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
    } catch (e) {
      debugPrint('Error fetching policy rules: $e');
      return [];
    }
  }

  /// Toggle category active status
  Future<bool> toggleCategoryActive(String categoryId, bool isActive) async {
    try {
      await client.from('expense_categories').update({'is_active': isActive}).eq('id', categoryId);
      return true;
    } catch (e) {
      debugPrint('Error updating category status: $e');
      return false;
    }
  }
}
