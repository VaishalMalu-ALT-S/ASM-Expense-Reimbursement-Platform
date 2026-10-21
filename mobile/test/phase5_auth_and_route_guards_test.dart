import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asm_expense/core/auth/auth_state.dart';
import 'package:asm_expense/core/auth/route_guard.dart';
import 'package:asm_expense/core/auth/auth_notifier.dart';
import 'package:asm_expense/features/auth/auth_state_screens.dart';
import 'package:asm_expense/shared/models/employee.dart';

void main() {
  group('Phase 5: Route Guard Authentication Contracts', () {
    test('Unauthenticated access to any protected route is strictly blocked and redirects to /login', () {
      const unauthState = AuthState.unauthenticated();

      final protectedRoutes = [
        '/dashboard',
        '/expenses/new',
        '/receipts/scan',
        '/advances/new',
        '/claims',
        '/claims/new',
        '/claims/claim-123',
        '/approvals',
        '/approvals/management',
        '/finance/reimbursements',
        '/reports',
      ];

      for (final route in protectedRoutes) {
        final redirect = RouteGuard.evaluate(
          targetPath: route,
          authState: unauthState,
        );
        expect(
          redirect,
          equals('/login?redirect=${Uri.encodeComponent(route)}'),
          reason: 'Unauthenticated direct access to $route must redirect to login with redirect parameter',
        );
      }
    });

    test('Public route /login is accessible when unauthenticated without redirect loop', () {
      const unauthState = AuthState.unauthenticated();
      final redirect = RouteGuard.evaluate(
        targetPath: '/login',
        authState: unauthState,
      );
      expect(redirect, isNull, reason: '/login must be directly accessible to unauthenticated users');
    });

    test('Unknown or loading role does not expose privileged UI (redirects to /loading)', () {
      const loadingState = AuthState.loading();

      final targetRoutes = [
        '/dashboard',
        '/finance/reimbursements',
        '/approvals/management',
        '/claims',
      ];

      for (final route in targetRoutes) {
        final redirect = RouteGuard.evaluate(
          targetPath: route,
          authState: loadingState,
        );
        expect(
          redirect,
          equals('/loading?redirect=${Uri.encodeComponent(route)}'),
          reason: 'Route $route must redirect to /loading while session and roles are resolving',
        );
      }

      // /loading itself is accessible without redirect loop
      expect(
        RouteGuard.evaluate(targetPath: '/loading', authState: loadingState),
        isNull,
      );
    });

    test('Expired session safely redirects to /session-expired', () {
      const expiredState = AuthState.sessionExpired();

      final redirect = RouteGuard.evaluate(
        targetPath: '/dashboard',
        authState: expiredState,
      );
      expect(redirect, equals('/session-expired'));

      expect(
        RouteGuard.evaluate(targetPath: '/session-expired', authState: expiredState),
        isNull,
      );
    });

    test('Inactive employee account safely redirects to /account-inactive', () {
      final inactiveEmployee = Employee(
        id: 'emp-inactive',
        employeeCode: 'ASM-999',
        fullName: 'Inactive User',
        email: 'inactive@alseermarine.com',
        isActive: false,
        roles: const [AppRole.employee],
      );
      final inactiveState = AuthState.inactive(inactiveEmployee);

      final redirect = RouteGuard.evaluate(
        targetPath: '/dashboard',
        authState: inactiveState,
      );
      expect(redirect, equals('/account-inactive'));

      expect(
        RouteGuard.evaluate(targetPath: '/account-inactive', authState: inactiveState),
        isNull,
      );
    });

    test('Role unavailable or network resolution failure safely redirects to /role-unavailable', () {
      const errorState = AuthState.roleUnavailable('Connection timeout to ASM directory');

      final redirect = RouteGuard.evaluate(
        targetPath: '/dashboard',
        authState: errorState,
      );
      expect(redirect, equals('/role-unavailable'));

      expect(
        RouteGuard.evaluate(targetPath: '/role-unavailable', authState: errorState),
        isNull,
      );
    });

    test('Authenticated user attempting to visit /login is redirected to /dashboard or target', () {
      final activeEmployee = Employee(
        id: 'emp-001',
        employeeCode: 'ASM-001',
        fullName: 'Active Employee',
        email: 'active@alseermarine.com',
        roles: const [AppRole.employee],
      );
      final authState = AuthState.authenticated(activeEmployee);

      // Visiting /login without redirect param -> /dashboard
      expect(
        RouteGuard.evaluate(targetPath: '/login', authState: authState),
        equals('/dashboard'),
      );

      // Visiting /login with redirect param -> target
      expect(
        RouteGuard.evaluate(
          targetPath: '/login',
          authState: authState,
          queryParams: {'redirect': '/claims/new'},
        ),
        equals('/claims/new'),
      );
    });
  });

  group('Phase 5: Role-Based Route Guard Enforcement', () {
    // Helper to generate authenticated state with specific roles
    AuthState createAuthState(List<AppRole> roles) {
      return AuthState.authenticated(Employee(
        id: 'test-user',
        employeeCode: 'ASM-TEST',
        fullName: 'Test User',
        email: 'test@alseermarine.com',
        roles: roles,
      ));
    }

    test('Employee cannot access manager, finance, management, or reports routes', () {
      final employeeState = createAuthState([AppRole.employee]);

      // General employee routes are allowed
      expect(RouteGuard.evaluate(targetPath: '/dashboard', authState: employeeState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/claims', authState: employeeState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/claims/new', authState: employeeState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/expenses/new', authState: employeeState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/advances/new', authState: employeeState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/receipts/scan', authState: employeeState), isNull);

      // Manager route blocked
      final managerRedirect = RouteGuard.evaluate(targetPath: '/approvals', authState: employeeState);
      expect(managerRedirect, startsWith('/unauthorized'));
      expect(managerRedirect, contains('required=Approver'));

      // Management approval route blocked
      final mgmtRedirect = RouteGuard.evaluate(targetPath: '/approvals/management', authState: employeeState);
      expect(mgmtRedirect, startsWith('/unauthorized'));
      expect(mgmtRedirect, contains('required=Management'));

      // Finance route blocked
      final finRedirect = RouteGuard.evaluate(targetPath: '/finance/reimbursements', authState: employeeState);
      expect(finRedirect, startsWith('/unauthorized'));
      expect(finRedirect, contains('required=Finance'));

      // Reports route blocked
      final repRedirect = RouteGuard.evaluate(targetPath: '/reports', authState: employeeState);
      expect(repRedirect, startsWith('/unauthorized'));
      expect(repRedirect, contains('required=Managerial'));
    });

    test('Line Manager can access approvals and reports, but cannot access finance or management review', () {
      final lmState = createAuthState([AppRole.lineManager]);

      // Permitted routes
      expect(RouteGuard.evaluate(targetPath: '/dashboard', authState: lmState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/approvals', authState: lmState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/reports', authState: lmState), isNull);

      // Blocked routes
      expect(
        RouteGuard.evaluate(targetPath: '/finance/reimbursements', authState: lmState),
        startsWith('/unauthorized'),
      );
      expect(
        RouteGuard.evaluate(targetPath: '/approvals/management', authState: lmState),
        startsWith('/unauthorized'),
      );
    });

    test('HOD (Department Manager) can access approvals and reports, but cannot access finance or management review', () {
      final hodState = createAuthState([AppRole.departmentManager]);

      // Permitted routes
      expect(RouteGuard.evaluate(targetPath: '/dashboard', authState: hodState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/approvals', authState: hodState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/reports', authState: hodState), isNull);

      // Blocked routes
      expect(
        RouteGuard.evaluate(targetPath: '/finance/reimbursements', authState: hodState),
        startsWith('/unauthorized'),
      );
      expect(
        RouteGuard.evaluate(targetPath: '/approvals/management', authState: hodState),
        startsWith('/unauthorized'),
      );
    });

    test('Only MANAGEMENT can access Management approval route (/approvals/management)', () {
      final mgmtState = createAuthState([AppRole.management]);

      // Permitted routes
      expect(RouteGuard.evaluate(targetPath: '/dashboard', authState: mgmtState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/approvals', authState: mgmtState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/approvals/management', authState: mgmtState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/reports', authState: mgmtState), isNull);

      // Management cannot access Finance screens
      expect(
        RouteGuard.evaluate(targetPath: '/finance/reimbursements', authState: mgmtState),
        startsWith('/unauthorized'),
      );
    });

    test('Only FINANCE can access payment/refund route (/finance/reimbursements)', () {
      final finState = createAuthState([AppRole.finance]);

      // Finance can access finance and approvals queue
      expect(RouteGuard.evaluate(targetPath: '/finance/reimbursements', authState: finState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/approvals', authState: finState), isNull);

      // Finance cannot access dedicated Management review
      expect(
        RouteGuard.evaluate(targetPath: '/approvals/management', authState: finState),
        startsWith('/unauthorized'),
      );
    });

    test('ADMIN role has access according to authorization policy', () {
      final adminState = createAuthState([AppRole.admin]);

      expect(RouteGuard.evaluate(targetPath: '/dashboard', authState: adminState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/approvals', authState: adminState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/approvals/management', authState: adminState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/finance/reimbursements', authState: adminState), isNull);
      expect(RouteGuard.evaluate(targetPath: '/reports', authState: adminState), isNull);
    });
  });

  group('Phase 5: AuthNotifier Lifecycle and Deep-Link Protection', () {
    late AuthNotifier notifier;

    setUp(() {
      notifier = AuthNotifier();
    });

    test('AuthNotifier updates state and informs listeners on logout', () {
      final emp = Employee(
        id: 'emp-1',
        employeeCode: 'ASM-01',
        fullName: 'Jane Doe',
        email: 'jane@alseermarine.com',
        roles: const [AppRole.finance],
      );
      notifier.setMockState(AuthState.authenticated(emp));
      expect(notifier.isAuthenticated, isTrue);
      expect(notifier.isFinance, isTrue);

      bool notified = false;
      notifier.addListener(() => notified = true);

      // Sign out
      notifier.setMockState(const AuthState.unauthenticated());
      expect(notified, isTrue);
      expect(notifier.isAuthenticated, isFalse);
      expect(notifier.currentEmployee, isNull);

      // Guard immediately blocks previously permitted route
      final redirect = RouteGuard.evaluate(
        targetPath: '/finance/reimbursements',
        authState: notifier.state,
      );
      expect(redirect, equals('/login?redirect=%2Ffinance%2Freimbursements'));
    });

    test('Direct / deep-link navigation cannot bypass route guards', () {
      final employeeState = AuthState.authenticated(Employee(
        id: 'emp-direct',
        employeeCode: 'ASM-DIR',
        fullName: 'Direct Nav User',
        email: 'direct@alseermarine.com',
        roles: const [AppRole.employee],
      ));

      // Attempting to directly deep-link into finance or management
      final directFinance = RouteGuard.evaluate(
        targetPath: '/finance/reimbursements',
        authState: employeeState,
      );
      expect(directFinance, startsWith('/unauthorized'));

      final directManagement = RouteGuard.evaluate(
        targetPath: '/approvals/management',
        authState: employeeState,
      );
      expect(directManagement, startsWith('/unauthorized'));
    });
  });

  group('Phase 5: Humanized State UI Screen Tests', () {
    testWidgets('UnauthorizedScreen renders professional ASM guidance without errors or stack traces', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: UnauthorizedScreen(requiredRole: 'Finance', fromPath: '/finance/reimbursements'),
        ),
      );

      expect(find.text('Access Restricted'), findsOneWidget);
      expect(find.textContaining('requires Finance role authorization'), findsOneWidget);
      expect(find.text('Return to Dashboard'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      // No raw errors, stack traces, or emojis
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.textContaining('Error'), findsNothing);
    });

    testWidgets('SessionExpiredScreen renders session guidance with sign in action', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SessionExpiredScreen(),
        ),
      );

      expect(find.text('Session Expired'), findsOneWidget);
      expect(find.textContaining('Your security session has expired'), findsOneWidget);
      expect(find.text('Sign In Again'), findsOneWidget);
    });

    testWidgets('AccountInactiveScreen renders clear HR instruction', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AccountInactiveScreen(),
        ),
      );

      expect(find.text('Account Inactive'), findsOneWidget);
      expect(find.textContaining('contact Human Resources'), findsOneWidget);
      expect(find.text('Return to Sign In'), findsOneWidget);
    });

    testWidgets('RoleUnavailableScreen renders clean retry and sign out options', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: RoleUnavailableScreen(),
        ),
      );

      expect(find.text('Permissions Unavailable'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Sign Out'), findsOneWidget);
    });

    testWidgets('AuthLoadingScreen renders professional corporate verification without flashing UI', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AuthLoadingScreen(),
        ),
      );

      expect(find.text('AL SEER MARINE'), findsOneWidget);
      expect(find.text('Verifying Credentials'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
