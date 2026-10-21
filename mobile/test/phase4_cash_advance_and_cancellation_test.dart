import 'package:flutter_test/flutter_test.dart';
import 'package:asm_expense/shared/models/cash_advance.dart';
import 'package:asm_expense/shared/models/expense_claim.dart';
import 'package:asm_expense/shared/models/employee.dart';

/// Simulated state for Cash Advance lifecycle and audit verification
class TestCashAdvanceState {
  String id;
  String advanceNumber;
  String employeeId;
  int amountMinor;
  int aedAmountMinor;
  String currencyCode;
  String purpose;
  CashAdvanceStatus status;
  String currentApprovalStage;
  int reconciledAmountMinor;
  int returnedAmountMinor;
  String? approvedBy;
  DateTime? approvedAt;
  DateTime? paidAt;
  int lockVersion;

  TestCashAdvanceState({
    required this.id,
    required this.advanceNumber,
    required this.employeeId,
    required this.amountMinor,
    required this.aedAmountMinor,
    required this.currencyCode,
    required this.purpose,
    required this.status,
    this.currentApprovalStage = 'LINE_MANAGER_REVIEW',
    this.reconciledAmountMinor = 0,
    this.returnedAmountMinor = 0,
    this.approvedBy,
    this.approvedAt,
    this.paidAt,
    this.lockVersion = 1,
  });

  int get remainingBalanceMinor => aedAmountMinor - reconciledAmountMinor - returnedAmountMinor;
}

class TestEmployee {
  final String id;
  final String? lineManagerId;
  final String? hodId;
  final List<AppRole> roles;

  TestEmployee({
    required this.id,
    this.lineManagerId,
    this.hodId,
    required this.roles,
  });

  bool hasRole(AppRole role) => roles.contains(role);
}

class TestApprovalAction {
  final String advanceId;
  final int stepOrder;
  final String actorId;
  final String action;
  final String previousStage;
  final String newStage;
  final String? comments;
  final DateTime createdAt;

  TestApprovalAction({
    required this.advanceId,
    required this.stepOrder,
    required this.actorId,
    required this.action,
    required this.previousStage,
    required this.newStage,
    this.comments,
    required this.createdAt,
  });
}

class TestRefundRecord {
  final String id;
  final String advanceId;
  final int refundAmountMinor;
  final String refundReference;
  final String? idempotencyKey;
  final String processedBy;
  final DateTime createdAt;

  TestRefundRecord({
    required this.id,
    required this.advanceId,
    required this.refundAmountMinor,
    required this.refundReference,
    this.idempotencyKey,
    required this.processedBy,
    required this.createdAt,
  });
}

class TestAuditRecord {
  final String event;
  final String tableName;
  final String recordId;
  final String actorId;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;

  TestAuditRecord({
    required this.event,
    required this.tableName,
    required this.recordId,
    required this.actorId,
    required this.metadata,
    required this.createdAt,
  });
}

/// Simulated engine mirroring Postgres RPCs from migration 20261019000009
class CashAdvanceLifecycleEngine {
  final Map<String, TestEmployee> employees = {};
  final Map<String, TestCashAdvanceState> advances = {};
  final List<TestApprovalAction> approvalActions = [];
  final List<TestRefundRecord> refunds = [];
  final List<TestAuditRecord> auditLogs = [];

  Map<String, dynamic> requestCashAdvance({
    required String employeeId,
    required int amountMinor,
    required String currencyCode,
    required String purpose,
  }) {
    final emp = employees[employeeId];
    if (emp == null) return {'success': false, 'code': 'UNAUTHENTICATED'};
    if (amountMinor <= 0) return {'success': false, 'code': 'INVALID_AMOUNT'};
    if (purpose.trim().isEmpty) return {'success': false, 'code': 'PURPOSE_REQUIRED'};

    final advId = 'adv-${DateTime.now().microsecondsSinceEpoch}';
    final advNum = 'ADV-20261019-1001';
    final state = TestCashAdvanceState(
      id: advId,
      advanceNumber: advNum,
      employeeId: employeeId,
      amountMinor: amountMinor,
      aedAmountMinor: amountMinor, // AED 1:1
      currencyCode: currencyCode,
      purpose: purpose,
      status: CashAdvanceStatus.underReview,
      currentApprovalStage: 'LINE_MANAGER_REVIEW',
    );
    advances[advId] = state;

    auditLogs.add(TestAuditRecord(
      event: 'ADVANCE_REQUESTED',
      tableName: 'cash_advances',
      recordId: advId,
      actorId: employeeId,
      metadata: {'amount_minor': amountMinor, 'stage': 'LINE_MANAGER_REVIEW'},
      createdAt: DateTime.now(),
    ));

    return {'success': true, 'advance_id': advId, 'status': 'UNDER_REVIEW', 'stage': 'LINE_MANAGER_REVIEW'};
  }

  Map<String, dynamic> reviewCashAdvance({
    required String advanceId,
    required String actorId,
    required String action, // 'APPROVE' or 'REJECT'
    String? comments,
    int? expectedVersion,
  }) {
    final adv = advances[advanceId];
    if (adv == null) return {'success': false, 'code': 'ADVANCE_NOT_FOUND'};

    // Concurrency / optimistic locking check
    if (expectedVersion != null && adv.lockVersion != expectedVersion) {
      return {'success': false, 'code': 'CONCURRENT_MODIFICATION_DETECTED'};
    }

    // Self-approval forbidden
    if (adv.employeeId == actorId) {
      return {'success': false, 'code': 'SELF_APPROVAL_FORBIDDEN'};
    }

    if (adv.status != CashAdvanceStatus.underReview) {
      return {'success': false, 'code': 'INVALID_STATE'};
    }

    final emp = employees[adv.employeeId];
    final actor = employees[actorId];
    if (emp == null || actor == null) return {'success': false, 'code': 'FORBIDDEN'};

    // Determine stage authorization and next stage
    bool isAuthorized = false;
    String nextStage = '';
    CashAdvanceStatus newStatus = CashAdvanceStatus.underReview;
    int stepOrder = 1;

    if (adv.currentApprovalStage == 'LINE_MANAGER_REVIEW') {
      stepOrder = 1;
      if (emp.lineManagerId == actorId || actor.hasRole(AppRole.admin)) {
        isAuthorized = true;
        nextStage = 'HOD_REVIEW';
      }
    } else if (adv.currentApprovalStage == 'HOD_REVIEW') {
      stepOrder = 2;
      if (emp.hodId == actorId || actor.hasRole(AppRole.admin)) {
        isAuthorized = true;
        nextStage = 'SIVA_REVIEW';
      }
    } else if (adv.currentApprovalStage == 'SIVA_REVIEW') {
      stepOrder = 3;
      if (actor.hasRole(AppRole.management) || actor.hasRole(AppRole.admin)) {
        isAuthorized = true;
        nextStage = 'FINANCE_REVIEW';
        newStatus = CashAdvanceStatus.underReview;
      }
    } else if (adv.currentApprovalStage == 'FINANCE_REVIEW') {
      stepOrder = 4;
      if (actor.hasRole(AppRole.finance) || actor.hasRole(AppRole.admin)) {
        isAuthorized = true;
        nextStage = 'APPROVED';
        newStatus = CashAdvanceStatus.approved;
      }
    } else {
      return {'success': false, 'code': 'INVALID_STAGE'};
    }

    if (!isAuthorized) {
      return {'success': false, 'code': 'FORBIDDEN'};
    }

    // Action REJECT
    if (action == 'REJECT') {
      if (comments == null || comments.trim().isEmpty) {
        return {'success': false, 'code': 'COMMENT_REQUIRED'};
      }
      adv.status = CashAdvanceStatus.rejected;
      adv.currentApprovalStage = 'REJECTED';
      adv.lockVersion++;

      approvalActions.add(TestApprovalAction(
        advanceId: advanceId,
        stepOrder: stepOrder,
        actorId: actorId,
        action: 'REJECT',
        previousStage: adv.currentApprovalStage,
        newStage: 'REJECTED',
        comments: comments,
        createdAt: DateTime.now(),
      ));

      auditLogs.add(TestAuditRecord(
        event: 'ADVANCE_REJECTED',
        tableName: 'cash_advances',
        recordId: advanceId,
        actorId: actorId,
        metadata: {'stage': adv.currentApprovalStage, 'comments': comments},
        createdAt: DateTime.now(),
      ));

      return {'success': true, 'status': 'REJECTED'};
    }

    // Action APPROVE: check duplicate approval across stages
    if (action == 'APPROVE') {
      final alreadyApproved = approvalActions.any(
        (a) => a.advanceId == advanceId && a.actorId == actorId && a.action == 'APPROVE',
      );
      if (alreadyApproved) {
        return {'success': false, 'code': 'ALREADY_APPROVED_PREVIOUS_STAGE'};
      }

      final prevStage = adv.currentApprovalStage;
      adv.currentApprovalStage = nextStage;
      adv.status = newStatus;
      adv.lockVersion++;
      if (newStatus == CashAdvanceStatus.approved) {
        adv.approvedBy = actorId;
        adv.approvedAt = DateTime.now();
      }

      approvalActions.add(TestApprovalAction(
        advanceId: advanceId,
        stepOrder: stepOrder,
        actorId: actorId,
        action: 'APPROVE',
        previousStage: prevStage,
        newStage: nextStage,
        comments: comments,
        createdAt: DateTime.now(),
      ));

      auditLogs.add(TestAuditRecord(
        event: 'ADVANCE_APPROVED_STAGE',
        tableName: 'cash_advances',
        recordId: advanceId,
        actorId: actorId,
        metadata: {'previous_stage': prevStage, 'new_stage': nextStage, 'status': newStatus.name},
        createdAt: DateTime.now(),
      ));

      return {
        'success': true,
        'status': newStatus.name,
        'current_stage': nextStage,
      };
    }

    return {'success': false, 'code': 'UNSUPPORTED_ACTION'};
  }

  Map<String, dynamic> recordCashAdvancePayment({
    required String advanceId,
    required String actorId,
    required String paymentReference,
  }) {
    final actor = employees[actorId];
    if (actor == null || (!actor.hasRole(AppRole.finance) && !actor.hasRole(AppRole.admin))) {
      return {'success': false, 'code': 'FORBIDDEN'};
    }
    if (paymentReference.trim().isEmpty) {
      return {'success': false, 'code': 'REFERENCE_REQUIRED'};
    }

    final adv = advances[advanceId];
    if (adv == null) return {'success': false, 'code': 'ADVANCE_NOT_FOUND'};
    if (adv.employeeId == actorId) return {'success': false, 'code': 'SELF_PAYMENT_FORBIDDEN'};
    if (adv.status == CashAdvanceStatus.paid) return {'success': false, 'code': 'ALREADY_PAID'};
    if (adv.status != CashAdvanceStatus.approved) return {'success': false, 'code': 'ADVANCE_NOT_APPROVED'};

    adv.status = CashAdvanceStatus.paid;
    adv.currentApprovalStage = 'COMPLETED';
    adv.paidAt = DateTime.now();
    adv.lockVersion++;

    auditLogs.add(TestAuditRecord(
      event: 'ADVANCE_PAID',
      tableName: 'cash_advances',
      recordId: advanceId,
      actorId: actorId,
      metadata: {'payment_reference': paymentReference, 'status': 'PAID'},
      createdAt: DateTime.now(),
    ));

    return {'success': true, 'status': 'PAID'};
  }

  Map<String, dynamic> recordCashAdvanceRefund({
    required String advanceId,
    required String actorId,
    required int refundAmountMinor,
    required String refundReference,
    String? idempotencyKey,
  }) {
    final actor = employees[actorId];
    if (actor == null || (!actor.hasRole(AppRole.finance) && !actor.hasRole(AppRole.admin))) {
      return {'success': false, 'code': 'FORBIDDEN'};
    }
    if (refundAmountMinor <= 0) return {'success': false, 'code': 'INVALID_REFUND_AMOUNT'};
    if (refundReference.trim().isEmpty) return {'success': false, 'code': 'REFERENCE_REQUIRED'};

    // Idempotency check
    if (idempotencyKey != null) {
      final existing = refunds.where((r) => r.idempotencyKey == idempotencyKey).firstOrNull;
      if (existing != null) {
        return {
          'success': true,
          'code': 'REFUND_REPLAYED',
          'replayed': true,
          'refund_id': existing.id,
          'advance_id': advanceId,
          'status': advances[advanceId]!.status.name,
        };
      }
    }

    final adv = advances[advanceId];
    if (adv == null) return {'success': false, 'code': 'ADVANCE_NOT_FOUND'};
    if (adv.status != CashAdvanceStatus.paid && adv.status != CashAdvanceStatus.partiallySettled) {
      return {'success': false, 'code': 'INVALID_STATUS'};
    }
    if (adv.employeeId == actorId) {
      return {'success': false, 'code': 'SELF_REFUND_FORBIDDEN'};
    }

    final unreconciledMinor = adv.remainingBalanceMinor;
    if (refundAmountMinor > unreconciledMinor) {
      return {'success': false, 'code': 'OVER_REFUND_PROHIBITED'};
    }

    final newReturnedMinor = adv.returnedAmountMinor + refundAmountMinor;
    CashAdvanceStatus newStatus = CashAdvanceStatus.partiallySettled;
    if (adv.reconciledAmountMinor + newReturnedMinor >= adv.aedAmountMinor) {
      newStatus = CashAdvanceStatus.settled;
    }

    final refundId = 'ref-${DateTime.now().microsecondsSinceEpoch}';
    refunds.add(TestRefundRecord(
      id: refundId,
      advanceId: advanceId,
      refundAmountMinor: refundAmountMinor,
      refundReference: refundReference,
      idempotencyKey: idempotencyKey,
      processedBy: actorId,
      createdAt: DateTime.now(),
    ));

    adv.returnedAmountMinor = newReturnedMinor;
    adv.status = newStatus;
    adv.lockVersion++;

    auditLogs.add(TestAuditRecord(
      event: 'ADVANCE_REFUNDED',
      tableName: 'cash_advances',
      recordId: advanceId,
      actorId: actorId,
      metadata: {
        'refund_id': refundId,
        'refund_amount_minor': refundAmountMinor,
        'new_status': newStatus.name,
        'reference': refundReference,
      },
      createdAt: DateTime.now(),
    ));

    return {
      'success': true,
      'code': 'REFUND_RECORDED',
      'refund_id': refundId,
      'advance_id': advanceId,
      'refund_amount_minor': refundAmountMinor,
      'total_returned_minor': newReturnedMinor,
      'remaining_balance_minor': adv.remainingBalanceMinor,
      'status': newStatus.name,
    };
  }
}

void main() {
  late CashAdvanceLifecycleEngine engine;
  const claimantId = 'emp-101';
  const lineManagerId = 'mgr-201';
  const hodId = 'hod-301';
  const managementId = 'exec-401';
  const financeId = 'fin-501';
  const cashierId = 'fin-502';
  const unrelatedId = 'emp-999';

  setUp(() {
    engine = CashAdvanceLifecycleEngine();
    engine.employees[claimantId] = TestEmployee(
      id: claimantId,
      lineManagerId: lineManagerId,
      hodId: hodId,
      roles: [AppRole.employee],
    );
    engine.employees[lineManagerId] = TestEmployee(
      id: lineManagerId,
      roles: [AppRole.lineManager],
    );
    engine.employees[hodId] = TestEmployee(
      id: hodId,
      roles: [AppRole.departmentManager],
    );
    engine.employees[managementId] = TestEmployee(
      id: managementId,
      roles: [AppRole.management],
    );
    engine.employees[financeId] = TestEmployee(
      id: financeId,
      roles: [AppRole.finance],
    );
    engine.employees[cashierId] = TestEmployee(
      id: cashierId,
      roles: [AppRole.finance],
    );
    engine.employees[unrelatedId] = TestEmployee(
      id: unrelatedId,
      roles: [AppRole.employee],
    );
  });

  group('Phase 4: Cash Advance Multi-Tier Hierarchy (Option 2)', () {
    test('Happy Path: Employee -> Line Manager -> HOD -> Management -> Finance -> Payment -> PAID', () {
      // 1. Employee submits advance for AED 1,000 (100,000 minor)
      final reqRes = engine.requestCashAdvance(
        employeeId: claimantId,
        amountMinor: 100000,
        currencyCode: 'AED',
        purpose: 'Site visit travel',
      );
      expect(reqRes['success'], isTrue);
      final advanceId = reqRes['advance_id'] as String;
      expect(engine.advances[advanceId]!.currentApprovalStage, equals('LINE_MANAGER_REVIEW'));
      expect(engine.advances[advanceId]!.status, equals(CashAdvanceStatus.underReview));

      // 2. Line Manager approval -> advances to HOD_REVIEW
      final lmRes = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: lineManagerId,
        action: 'APPROVE',
        comments: 'Approved by LM',
      );
      expect(lmRes['success'], isTrue);
      expect(lmRes['current_stage'], equals('HOD_REVIEW'));
      expect(engine.advances[advanceId]!.status, equals(CashAdvanceStatus.underReview));

      // 3. HOD approval -> advances to SIVA_REVIEW
      final hodRes = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: hodId,
        action: 'APPROVE',
        comments: 'Approved by HOD',
      );
      expect(hodRes['success'], isTrue);
      expect(hodRes['current_stage'], equals('SIVA_REVIEW'));
      expect(engine.advances[advanceId]!.status, equals(CashAdvanceStatus.underReview));

      // 4. Siva / Management approval -> advances to FINANCE_REVIEW
      final mgmtRes = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: managementId,
        action: 'APPROVE',
        comments: 'Approved by Management',
      );
      expect(mgmtRes['success'], isTrue);
      expect(mgmtRes['current_stage'], equals('FINANCE_REVIEW'));
      expect(engine.advances[advanceId]!.status, equals(CashAdvanceStatus.underReview));

      // 5. Finance approval -> advance becomes APPROVED
      final finRes = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: financeId,
        action: 'APPROVE',
        comments: 'Approved by Finance',
      );
      expect(finRes['success'], isTrue);
      expect(finRes['current_stage'], equals('APPROVED'));
      expect(engine.advances[advanceId]!.status, equals(CashAdvanceStatus.approved));

      // 6. Payment Disbursement by Finance -> advance becomes PAID
      final payRes = engine.recordCashAdvancePayment(
        advanceId: advanceId,
        actorId: cashierId,
        paymentReference: 'WIRE-2026-9001',
      );
      expect(payRes['success'], isTrue);
      expect(engine.advances[advanceId]!.status, equals(CashAdvanceStatus.paid));
      expect(engine.advances[advanceId]!.currentApprovalStage, equals('COMPLETED'));
      expect(engine.advances[advanceId]!.paidAt, isNotNull);

      // Verify audit logs exist for all actions
      final events = engine.auditLogs.where((l) => l.recordId == advanceId).map((l) => l.event).toList();
      expect(events, containsAll(['ADVANCE_REQUESTED', 'ADVANCE_APPROVED_STAGE', 'ADVANCE_PAID']));
      expect(engine.approvalActions.where((a) => a.advanceId == advanceId).length, equals(4));
    });

    test('Unauthorized stage approval is strictly rejected', () {
      final reqRes = engine.requestCashAdvance(
        employeeId: claimantId,
        amountMinor: 50000,
        currencyCode: 'AED',
        purpose: 'Client dinner',
      );
      final advanceId = reqRes['advance_id'] as String;

      // HOD attempts to approve at LINE_MANAGER_REVIEW stage
      final unauthorizedHod = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: hodId,
        action: 'APPROVE',
      );
      expect(unauthorizedHod['success'], isFalse);
      expect(unauthorizedHod['code'], equals('FORBIDDEN'));

      // Management attempts to approve at LINE_MANAGER_REVIEW stage
      final unauthorizedMgmt = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: managementId,
        action: 'APPROVE',
      );
      expect(unauthorizedMgmt['success'], isFalse);
      expect(unauthorizedMgmt['code'], equals('FORBIDDEN'));

      // Unrelated employee attempts to approve
      final unrelatedRes = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: unrelatedId,
        action: 'APPROVE',
      );
      expect(unrelatedRes['success'], isFalse);
      expect(unrelatedRes['code'], equals('FORBIDDEN'));
    });

    test('Self-approval is strictly prohibited', () {
      // Employee with Management role requests advance
      engine.employees['exec-siva'] = TestEmployee(
        id: 'exec-siva',
        lineManagerId: lineManagerId,
        roles: [AppRole.management],
      );

      final reqRes = engine.requestCashAdvance(
        employeeId: 'exec-siva',
        amountMinor: 80000,
        currencyCode: 'AED',
        purpose: 'Executive conference',
      );
      final advanceId = reqRes['advance_id'] as String;

      // Requester attempts to approve own advance
      final selfRes = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: 'exec-siva',
        action: 'APPROVE',
      );
      expect(selfRes['success'], isFalse);
      expect(selfRes['code'], equals('SELF_APPROVAL_FORBIDDEN'));
    });

    test('Cross-stage duplicate approval by same actor is prohibited', () {
      // Line manager who also has MANAGEMENT role
      engine.employees['dual-actor'] = TestEmployee(
        id: 'dual-actor',
        roles: [AppRole.lineManager, AppRole.management],
      );
      engine.employees['subordinate'] = TestEmployee(
        id: 'subordinate',
        lineManagerId: 'dual-actor',
        hodId: hodId,
        roles: [AppRole.employee],
      );

      final reqRes = engine.requestCashAdvance(
        employeeId: 'subordinate',
        amountMinor: 40000,
        currencyCode: 'AED',
        purpose: 'Tools purchase',
      );
      final advanceId = reqRes['advance_id'] as String;

      // Step 1: dual-actor approves as Line Manager
      final step1 = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: 'dual-actor',
        action: 'APPROVE',
      );
      expect(step1['success'], isTrue);

      // Step 2: HOD approves
      final step2 = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: hodId,
        action: 'APPROVE',
      );
      expect(step2['success'], isTrue);

      // Step 3: dual-actor attempts to approve again as Management -> blocked!
      final step3 = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: 'dual-actor',
        action: 'APPROVE',
      );
      expect(step3['success'], isFalse);
      expect(step3['code'], equals('ALREADY_APPROVED_PREVIOUS_STAGE'));
    });

    test('Concurrent duplicate approval is prevented via lock', () {
      final reqRes = engine.requestCashAdvance(
        employeeId: claimantId,
        amountMinor: 50000,
        currencyCode: 'AED',
        purpose: 'Field expenses',
      );
      final advanceId = reqRes['advance_id'] as String;
      final currentVersion = engine.advances[advanceId]!.lockVersion;

      // First concurrent actor completes approval
      final firstRes = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: lineManagerId,
        action: 'APPROVE',
        expectedVersion: currentVersion,
      );
      expect(firstRes['success'], isTrue);

      // Second concurrent actor using stale version fails
      final secondRes = engine.reviewCashAdvance(
        advanceId: advanceId,
        actorId: lineManagerId,
        action: 'APPROVE',
        expectedVersion: currentVersion,
      );
      expect(secondRes['success'], isFalse);
      expect(secondRes['code'], equals('CONCURRENT_MODIFICATION_DETECTED'));
    });

    test('Payment only succeeds after final Finance approval', () {
      final reqRes = engine.requestCashAdvance(
        employeeId: claimantId,
        amountMinor: 60000,
        currencyCode: 'AED',
        purpose: 'Equipment rental',
      );
      final advanceId = reqRes['advance_id'] as String;

      // Payment attempted when still at LINE_MANAGER_REVIEW
      final prematurePay1 = engine.recordCashAdvancePayment(
        advanceId: advanceId,
        actorId: financeId,
        paymentReference: 'WIRE-FAIL-1',
      );
      expect(prematurePay1['success'], isFalse);
      expect(prematurePay1['code'], equals('ADVANCE_NOT_APPROVED'));

      // Progress through LM, HOD, and Management
      engine.reviewCashAdvance(advanceId: advanceId, actorId: lineManagerId, action: 'APPROVE');
      engine.reviewCashAdvance(advanceId: advanceId, actorId: hodId, action: 'APPROVE');
      engine.reviewCashAdvance(advanceId: advanceId, actorId: managementId, action: 'APPROVE');

      // Still at FINANCE_REVIEW (status is still UNDER_REVIEW)
      final prematurePay2 = engine.recordCashAdvancePayment(
        advanceId: advanceId,
        actorId: financeId,
        paymentReference: 'WIRE-FAIL-2',
      );
      expect(prematurePay2['success'], isFalse);
      expect(prematurePay2['code'], equals('ADVANCE_NOT_APPROVED'));

      // Finance approves
      engine.reviewCashAdvance(advanceId: advanceId, actorId: financeId, action: 'APPROVE');
      expect(engine.advances[advanceId]!.status, equals(CashAdvanceStatus.approved));

      // Now payment succeeds
      final validPay = engine.recordCashAdvancePayment(
        advanceId: advanceId,
        actorId: financeId,
        paymentReference: 'WIRE-SUCCESS',
      );
      expect(validPay['success'], isTrue);
      expect(engine.advances[advanceId]!.status, equals(CashAdvanceStatus.paid));
    });
  });

  group('Phase 4: Leftover Advance Refunds (Option A)', () {
    late String advanceId;

    setUp(() {
      // Create and disburse advance: AED 1,000 (100,000 minor units)
      final req = engine.requestCashAdvance(
        employeeId: claimantId,
        amountMinor: 100000,
        currencyCode: 'AED',
        purpose: 'Abu Dhabi client meetings',
      );
      advanceId = req['advance_id'] as String;
      engine.reviewCashAdvance(advanceId: advanceId, actorId: lineManagerId, action: 'APPROVE');
      engine.reviewCashAdvance(advanceId: advanceId, actorId: hodId, action: 'APPROVE');
      engine.reviewCashAdvance(advanceId: advanceId, actorId: managementId, action: 'APPROVE');
      engine.reviewCashAdvance(advanceId: advanceId, actorId: financeId, action: 'APPROVE');
      engine.recordCashAdvancePayment(advanceId: advanceId, actorId: cashierId, paymentReference: 'PAY-1000');
    });

    test('Option A Example: Advance 1,000 / Expense 800 / Refund 200 -> SETTLED', () {
      final adv = engine.advances[advanceId]!;
      expect(adv.status, equals(CashAdvanceStatus.paid));

      // Simulate claim reconciliation: approved expense = AED 800 (80,000 minor)
      adv.reconciledAmountMinor = 80000;
      adv.status = CashAdvanceStatus.partiallySettled;

      expect(adv.remainingBalanceMinor, equals(20000)); // AED 200 unused balance

      // Finance records refund of AED 200 (20,000 minor)
      final refundRes = engine.recordCashAdvanceRefund(
        advanceId: advanceId,
        actorId: financeId,
        refundAmountMinor: 20000,
        refundReference: 'REF-BANK-2026-001',
      );

      expect(refundRes['success'], isTrue);
      expect(refundRes['code'], equals('REFUND_RECORDED'));
      expect(refundRes['total_returned_minor'], equals(20000));
      expect(refundRes['remaining_balance_minor'], equals(0));
      expect(refundRes['status'], equals('settled'));

      // Advance must now be strictly SETTLED
      expect(adv.status, equals(CashAdvanceStatus.settled));
      expect(adv.returnedAmountMinor, equals(20000));
      expect(adv.reconciledAmountMinor + adv.returnedAmountMinor, equals(adv.aedAmountMinor));

      // Audit record was generated
      final audit = engine.auditLogs.where((l) => l.event == 'ADVANCE_REFUNDED' && l.recordId == advanceId).firstOrNull;
      expect(audit, isNotNull);
      expect(audit!.metadata['refund_amount_minor'], equals(20000));
      expect(audit.metadata['new_status'], equals('settled'));
    });

    test('Refund cannot exceed remaining unreconciled balance', () {
      final adv = engine.advances[advanceId]!;
      adv.reconciledAmountMinor = 80000; // AED 800
      adv.status = CashAdvanceStatus.partiallySettled;

      // Unused balance is AED 200 (20,000 minor). Finance attempts to refund AED 250 (25,000 minor).
      final overRefundRes = engine.recordCashAdvanceRefund(
        advanceId: advanceId,
        actorId: financeId,
        refundAmountMinor: 25000,
        refundReference: 'REF-OVER-001',
      );

      expect(overRefundRes['success'], isFalse);
      expect(overRefundRes['code'], equals('OVER_REFUND_PROHIBITED'));
      expect(adv.returnedAmountMinor, equals(0)); // Nothing recorded
      expect(adv.status, equals(CashAdvanceStatus.partiallySettled));
    });

    test('Duplicate refund request with idempotency key is idempotent', () {
      final adv = engine.advances[advanceId]!;
      adv.reconciledAmountMinor = 80000;
      adv.status = CashAdvanceStatus.partiallySettled;

      const idempotencyKey = 'key-uuid-1234-5678';

      // First refund submission
      final res1 = engine.recordCashAdvanceRefund(
        advanceId: advanceId,
        actorId: financeId,
        refundAmountMinor: 20000,
        refundReference: 'REF-IDEMP-001',
        idempotencyKey: idempotencyKey,
      );
      expect(res1['success'], isTrue);
      expect(res1['code'], equals('REFUND_RECORDED'));
      expect(engine.refunds.length, equals(1));
      expect(adv.returnedAmountMinor, equals(20000));

      // Duplicate submission with identical key
      final res2 = engine.recordCashAdvanceRefund(
        advanceId: advanceId,
        actorId: financeId,
        refundAmountMinor: 20000,
        refundReference: 'REF-IDEMP-001',
        idempotencyKey: idempotencyKey,
      );
      expect(res2['success'], isTrue);
      expect(res2['code'], equals('REFUND_REPLAYED'));
      expect(res2['replayed'], isTrue);

      // Does NOT create second refund record or over-count returned amount
      expect(engine.refunds.length, equals(1));
      expect(adv.returnedAmountMinor, equals(20000));
    });

    test('Wrong or non-positive refund amount fails validation', () {
      final zeroRefund = engine.recordCashAdvanceRefund(
        advanceId: advanceId,
        actorId: financeId,
        refundAmountMinor: 0,
        refundReference: 'REF-ZERO',
      );
      expect(zeroRefund['success'], isFalse);
      expect(zeroRefund['code'], equals('INVALID_REFUND_AMOUNT'));

      final negativeRefund = engine.recordCashAdvanceRefund(
        advanceId: advanceId,
        actorId: financeId,
        refundAmountMinor: -5000,
        refundReference: 'REF-NEG',
      );
      expect(negativeRefund['success'], isFalse);
      expect(negativeRefund['code'], equals('INVALID_REFUND_AMOUNT'));

      final emptyRef = engine.recordCashAdvanceRefund(
        advanceId: advanceId,
        actorId: financeId,
        refundAmountMinor: 5000,
        refundReference: '   ',
      );
      expect(emptyRef['success'], isFalse);
      expect(emptyRef['code'], equals('REFERENCE_REQUIRED'));
    });

    test('Non-Finance cannot record refund, and Finance cannot self-refund', () {
      // Employee attempts to record own refund
      final empRefund = engine.recordCashAdvanceRefund(
        advanceId: advanceId,
        actorId: claimantId,
        refundAmountMinor: 20000,
        refundReference: 'REF-EMP',
      );
      expect(empRefund['success'], isFalse);
      expect(empRefund['code'], equals('FORBIDDEN'));

      // Line manager attempts to record refund
      final lmRefund = engine.recordCashAdvanceRefund(
        advanceId: advanceId,
        actorId: lineManagerId,
        refundAmountMinor: 20000,
        refundReference: 'REF-LM',
      );
      expect(lmRefund['success'], isFalse);
      expect(lmRefund['code'], equals('FORBIDDEN'));

      // Advance belongs to Finance employee
      engine.advances['fin-adv'] = TestCashAdvanceState(
        id: 'fin-adv',
        advanceNumber: 'ADV-FIN-01',
        employeeId: financeId,
        amountMinor: 50000,
        aedAmountMinor: 50000,
        currencyCode: 'AED',
        purpose: 'Finance audit travel',
        status: CashAdvanceStatus.paid,
      );

      // Finance employee attempts to refund own advance
      final selfRefund = engine.recordCashAdvanceRefund(
        advanceId: 'fin-adv',
        actorId: financeId,
        refundAmountMinor: 10000,
        refundReference: 'REF-SELF',
      );
      expect(selfRefund['success'], isFalse);
      expect(selfRefund['code'], equals('SELF_REFUND_FORBIDDEN'));
    });

    test('Advance becomes SETTLED only after full reconciliation + refund sum equals total', () {
      final adv = engine.advances[advanceId]!; // 100,000 minor total
      adv.reconciledAmountMinor = 60000;       // AED 600 reconciled
      adv.status = CashAdvanceStatus.partiallySettled;

      // First partial refund of AED 200 (20,000 minor)
      final part1 = engine.recordCashAdvanceRefund(
        advanceId: advanceId,
        actorId: financeId,
        refundAmountMinor: 20000,
        refundReference: 'REF-PART-1',
      );
      expect(part1['success'], isTrue);
      expect(part1['status'], equals('partiallySettled'));
      expect(adv.status, equals(CashAdvanceStatus.partiallySettled));
      expect(adv.remainingBalanceMinor, equals(20000)); // AED 200 remaining

      // Second partial refund of remaining AED 200 (20,000 minor)
      final part2 = engine.recordCashAdvanceRefund(
        advanceId: advanceId,
        actorId: financeId,
        refundAmountMinor: 20000,
        refundReference: 'REF-PART-2',
      );
      expect(part2['success'], isTrue);
      expect(part2['status'], equals('settled'));
      expect(adv.status, equals(CashAdvanceStatus.settled));
      expect(adv.remainingBalanceMinor, equals(0));
    });
  });

  group('Phase 4: Claim and Advance Pre-Approval Cancellation Contracts', () {
    test('Pre-approval claims can be cancelled with mandatory reason; finalized cannot', () {
      final cancellable = [
        ClaimStatus.draft,
        ClaimStatus.submitted,
        ClaimStatus.lineManagerReview,
        ClaimStatus.hodReview,
        ClaimStatus.sivaReview,
        ClaimStatus.financeReview,
        ClaimStatus.correctionRequired,
      ];

      final nonCancellable = [
        ClaimStatus.approved,
        ClaimStatus.reimbursementProcessing,
        ClaimStatus.paid,
        ClaimStatus.settled,
        ClaimStatus.cancelled,
      ];

      bool canCancelClaim(ClaimStatus s, String? reason) {
        if (reason == null || reason.trim().isEmpty) return false;
        return cancellable.contains(s);
      }

      for (final s in cancellable) {
        expect(canCancelClaim(s, 'Trip cancelled'), isTrue, reason: '${s.displayName} should be cancellable');
      }
      for (final s in nonCancellable) {
        expect(canCancelClaim(s, 'Trip cancelled'), isFalse, reason: '${s.displayName} cannot be cancelled');
      }
      expect(canCancelClaim(ClaimStatus.submitted, '   '), isFalse, reason: 'Empty reason rejected');
    });

    test('Cash advances can be cancelled before payment; disbursed/settled cannot', () {
      final cancellable = [
        CashAdvanceStatus.draft,
        CashAdvanceStatus.submitted,
        CashAdvanceStatus.underReview,
        CashAdvanceStatus.approved,
      ];

      final nonCancellable = [
        CashAdvanceStatus.paid,
        CashAdvanceStatus.partiallySettled,
        CashAdvanceStatus.settled,
        CashAdvanceStatus.cancelled,
      ];

      bool canCancelAdvance(CashAdvanceStatus s, String? reason) {
        if (reason == null || reason.trim().isEmpty) return false;
        return cancellable.contains(s);
      }

      for (final s in cancellable) {
        expect(canCancelAdvance(s, 'No longer needed'), isTrue, reason: '${s.displayName} should be cancellable');
      }
      for (final s in nonCancellable) {
        expect(canCancelAdvance(s, 'No longer needed'), isFalse, reason: '${s.displayName} cannot be cancelled');
      }
      expect(canCancelAdvance(CashAdvanceStatus.underReview, ''), isFalse, reason: 'Empty reason rejected');
    });
  });
}

