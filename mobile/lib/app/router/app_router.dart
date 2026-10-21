import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/auth/auth_notifier.dart';
import '../../core/auth/route_guard.dart';
import '../../features/auth/login_screen.dart';
import '../../features/auth/auth_state_screens.dart';
import '../../features/splash/splash_screen.dart';
import '../../features/dashboard/dashboard_screen.dart';
import '../../features/expenses/create_expense_screen.dart';
import '../../features/expenses/expense_list_screen.dart';
import '../../features/receipts/scan_receipt_screen.dart';
import '../../features/advances/request_advance_screen.dart';
import '../../features/advances/advance_list_screen.dart';
import '../../features/advances/advance_detail_screen.dart';
import '../../features/claims/create_claim_screen.dart';
import '../../features/claims/claim_list_screen.dart';
import '../../features/claims/claim_detail_screen.dart';
import '../../features/approvals/manager_approval_screen.dart';
import '../../features/reimbursements/finance_reimbursement_screen.dart';
import '../../features/reports/expense_reports_screen.dart';
import '../../features/admin/admin_center_screen.dart';
import '../../shared/widgets/enterprise_shell.dart';

final appRouter = GoRouter(
  initialLocation: '/splash',
  refreshListenable: AuthNotifier(),
  redirect: (context, state) => RouteGuard.evaluate(
    targetPath: state.uri.path,
    authState: AuthNotifier().state,
    queryParams: state.uri.queryParameters,
  ),
  routes: [
    // Public authentication screen
    // Launch screen; hands over to RouteGuard once startup has finished.
    GoRoute(
      path: '/splash',
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: '/login',
      // Cross-fade so the splash dissolves into the (same navy) login screen.
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const LoginScreen(),
        transitionDuration: const Duration(milliseconds: 450),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut), child: child),
      ),
    ),

    // Transient & Security State Screens
    GoRoute(
      path: '/loading',
      builder: (context, state) => const AuthLoadingScreen(),
    ),
    GoRoute(
      path: '/unauthorized',
      builder: (context, state) => UnauthorizedScreen(
        requiredRole: state.uri.queryParameters['required'],
        fromPath: state.uri.queryParameters['from'],
      ),
    ),
    GoRoute(
      path: '/session-expired',
      builder: (context, state) => const SessionExpiredScreen(),
    ),
    GoRoute(
      path: '/account-inactive',
      builder: (context, state) => const AccountInactiveScreen(),
    ),
    GoRoute(
      path: '/role-unavailable',
      builder: (context, state) => const RoleUnavailableScreen(),
    ),

    // Protected Shell Routes
    ShellRoute(
      builder: (context, state, child) {
        return EnterpriseShell(
          currentRoute: state.uri.toString(),
          child: child,
        );
      },
      routes: [
        GoRoute(
          path: '/dashboard',
          builder: (context, state) => const DashboardScreen(),
        ),
        GoRoute(
          path: '/expenses',
          builder: (context, state) => const ExpenseListScreen(),
        ),
        GoRoute(
          path: '/expenses/new',
          builder: (context, state) => const CreateExpenseScreen(),
        ),
        GoRoute(
          path: '/expenses/:id/edit',
          builder: (context, state) => CreateExpenseScreen(editExpenseId: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/receipts/scan',
          builder: (context, state) => const ScanReceiptScreen(),
        ),
        GoRoute(
          path: '/advances',
          builder: (context, state) => const AdvanceListScreen(),
        ),
        GoRoute(
          path: '/advances/new',
          builder: (context, state) => const RequestAdvanceScreen(),
        ),
        GoRoute(
          path: '/advances/:id',
          builder: (context, state) => AdvanceDetailScreen(advanceId: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/claims',
          builder: (context, state) => const ClaimListScreen(),
        ),
        GoRoute(
          path: '/claims/new',
          builder: (context, state) => const CreateClaimScreen(),
        ),
        GoRoute(
          path: '/claims/:id',
          builder: (context, state) => ClaimDetailScreen(claimId: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/claims/:id/correct',
          builder: (context, state) => CreateClaimScreen(correctionClaimId: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/approvals',
          builder: (context, state) => ManagerApprovalScreen(
            initialTab: state.uri.queryParameters['tab'],
          ),
        ),
        GoRoute(
          path: '/approvals/management',
          builder: (context, state) => ManagerApprovalScreen(
            isManagementOnly: true,
            initialTab: state.uri.queryParameters['tab'],
          ),
        ),
        GoRoute(
          path: '/finance/reimbursements',
          builder: (context, state) => const FinanceReimbursementScreen(),
        ),
        GoRoute(
          path: '/reports',
          builder: (context, state) => const ExpenseReportsScreen(),
        ),
        GoRoute(
          path: '/admin',
          builder: (context, state) => const AdminCenterScreen(),
        ),
      ],
    ),
  ],
);
