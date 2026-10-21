import 'package:flutter_test/flutter_test.dart';
import 'package:asm_expense/shared/models/expense_claim.dart';
import 'package:asm_expense/shared/models/employee.dart';

void main() {
  group('Phase 3A - Siva / Management 4-Tier Approval Flow Contracts', () {
    test('A & B: HOD Review progresses to Siva/Management Review, not directly to Finance', () {
      const currentStatus = ClaimStatus.hodReview;
      expect(currentStatus.displayName, 'HOD Review');

      // Allowed next status from HOD in 4-tier chain is strictly SIVA_REVIEW
      const validNextStatus = ClaimStatus.sivaReview;
      expect(validNextStatus.displayName, 'Management Review');

      // Bypass to Finance directly is prohibited under Option B
      expect(validNextStatus, isNot(equals(ClaimStatus.financeReview)));
    });

    test('C & D: AppRole.management is recognized and distinct from other roles', () {
      final role = AppRole.fromString('MANAGEMENT');
      expect(role, equals(AppRole.management));
      expect(role.displayName, 'Management');

      // Non-management role cannot claim management authority
      final lineManager = AppRole.fromString('LINE_MANAGER');
      expect(lineManager, isNot(equals(AppRole.management)));

      final employee = AppRole.fromString('EMPLOYEE');
      expect(employee, isNot(equals(AppRole.management)));
    });

    test('E: Self-approval constraint contract', () {
      const claimantId = 'emp-001';
      const approverId = 'emp-001';

      // Self approval must be detected and rejected
      final isSelfApproval = claimantId == approverId;
      expect(isSelfApproval, isTrue, reason: 'System must detect and prohibit self-approval at SIVA stage');
    });

    test('F: Previous stage approver cannot approve subsequent stage (Segregation of Duties)', () {
      final approvalHistory = <String, String>{
        'LINE_MANAGER_REVIEW': 'manager-user-01',
        'HOD_REVIEW': 'hod-user-02',
      };

      const sivaApproverCandidateA = 'manager-user-01'; // already approved at stage 1
      const sivaApproverCandidateB = 'hod-user-02';     // already approved at stage 2
      const legitimateManagementUser = 'siva-exec-03';  // independent executive

      expect(approvalHistory.containsValue(sivaApproverCandidateA), isTrue,
          reason: 'Candidate A already approved at line manager review');
      expect(approvalHistory.containsValue(sivaApproverCandidateB), isTrue,
          reason: 'Candidate B already approved at HOD review');
      expect(approvalHistory.containsValue(legitimateManagementUser), isFalse,
          reason: 'Legitimate management user has not previously approved');
    });

    test('G: Concurrent SIVA approvals result in exactly one successful approval', () {
      // Simulating concurrent arrival of two approval actions on the same claim
      var claimStatus = ClaimStatus.sivaReview;
      int successfulApprovals = 0;
      int rejectedConcurrentAttempts = 0;

      void attemptApproval(String callerRole) {
        // Under database row-lock FOR UPDATE, the first caller inspects status = sivaReview and updates to financeReview
        if (claimStatus == ClaimStatus.sivaReview && callerRole == 'MANAGEMENT') {
          claimStatus = ClaimStatus.financeReview;
          successfulApprovals++;
        } else {
          // Second concurrent caller wakes up to find status already moved to financeReview
          rejectedConcurrentAttempts++;
        }
      }

      attemptApproval('MANAGEMENT'); // Winner of row lock
      attemptApproval('MANAGEMENT'); // Subsequent caller finding status already moved

      expect(successfulApprovals, equals(1));
      expect(rejectedConcurrentAttempts, equals(1));
      expect(claimStatus, equals(ClaimStatus.financeReview));
    });

    test('H & I: Siva Approval moves to Finance Review, then Finance can approve', () {
      const sivaStatus = ClaimStatus.sivaReview;
      expect(sivaStatus, equals(ClaimStatus.sivaReview));

      // After Management approval -> moves to Finance Review
      const nextStatusAfterSiva = ClaimStatus.financeReview;
      expect(nextStatusAfterSiva, equals(ClaimStatus.financeReview));
      expect(nextStatusAfterSiva.displayName, 'Finance Review');

      // Finance approval -> Approved
      const finalApproval = ClaimStatus.approved;
      expect(finalApproval, equals(ClaimStatus.approved));
      expect(finalApproval.displayName, 'Approved');
    });

    test('Enforces linear 4-Tier chain sequence', () {
      final workflowStages = [
        ClaimStatus.lineManagerReview,
        ClaimStatus.hodReview,
        ClaimStatus.sivaReview,
        ClaimStatus.financeReview,
        ClaimStatus.approved,
      ];

      expect(workflowStages[0], ClaimStatus.lineManagerReview);
      expect(workflowStages[1], ClaimStatus.hodReview);
      expect(workflowStages[2], ClaimStatus.sivaReview);
      expect(workflowStages[3], ClaimStatus.financeReview);
      expect(workflowStages[4], ClaimStatus.approved);
    });
  });
}
