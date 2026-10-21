import 'auth_state.dart';

/// Pure, deterministic route guard evaluator for Flutter GoRouter.
/// Evaluates route accessibility based on the user's authenticated session,
/// employee status, and role claims.
class RouteGuard {
  static const Set<String> _publicRoutes = {'/login'};
  static const Set<String> _statusRoutes = {
    '/loading',
    '/unauthorized',
    '/session-expired',
    '/account-inactive',
    '/role-unavailable',
  };

  /// Evaluates target path against current AuthState and returns the redirect path,
  /// or null if navigation to targetPath is permitted.
  static String? evaluate({
    required String targetPath,
    required AuthState authState,
    Map<String, String>? queryParams,
  }) {
    // 0. Launch splash: shown in every state; it requests a route itself when startup is done.
    if (targetPath == '/splash') {
      return null;
    }

    // 1. Session / roles resolving state
    if (authState.status == AuthStatus.loading) {
      if (targetPath == '/loading' || targetPath == '/login') {
        return null;
      }
      return '/loading?redirect=${Uri.encodeComponent(targetPath)}';
    }

    // 2. Unauthenticated state
    if (authState.status == AuthStatus.unauthenticated) {
      if (_publicRoutes.contains(targetPath)) {
        return null;
      }
      // Do not preserve status screens as redirect destinations
      final redirectTarget = _statusRoutes.contains(targetPath) ? '/dashboard' : targetPath;
      return '/login?redirect=${Uri.encodeComponent(redirectTarget)}';
    }

    // 3. Session expired state
    if (authState.status == AuthStatus.sessionExpired) {
      if (targetPath == '/session-expired' || targetPath == '/login') {
        return null;
      }
      return '/session-expired';
    }

    // 4. Inactive account state
    if (authState.status == AuthStatus.inactive) {
      if (targetPath == '/account-inactive' || targetPath == '/login') {
        return null;
      }
      return '/account-inactive';
    }

    // 5. Role or credentials resolution failure
    if (authState.status == AuthStatus.roleUnavailable) {
      if (targetPath == '/role-unavailable' || targetPath == '/login') {
        return null;
      }
      return '/role-unavailable';
    }

    // 6. Authenticated state
    if (authState.status == AuthStatus.authenticated) {
      // Prevent authenticated users from visiting login or transient status screens
      if (targetPath == '/login' ||
          targetPath == '/loading' ||
          targetPath == '/session-expired' ||
          targetPath == '/account-inactive' ||
          targetPath == '/role-unavailable') {
        final redirectUrl = queryParams?['redirect'];
        if (redirectUrl != null &&
            redirectUrl.isNotEmpty &&
            redirectUrl.startsWith('/') &&
            !_statusRoutes.contains(redirectUrl) &&
            !_publicRoutes.contains(redirectUrl)) {
          return redirectUrl;
        }
        return '/dashboard';
      }

      // Allow viewing the unauthorized screen itself
      if (targetPath == '/unauthorized') {
        return null;
      }

      // Role Guard: Management Approval Functionality
      if (targetPath.startsWith('/approvals/management')) {
        if (!authState.isManagement) {
          return '/unauthorized?required=Management&from=${Uri.encodeComponent(targetPath)}';
        }
      }

      // Role Guard: Finance Payment and Reimbursement Screens
      if (targetPath.startsWith('/finance')) {
        if (!authState.isFinance) {
          return '/unauthorized?required=Finance&from=${Uri.encodeComponent(targetPath)}';
        }
      }

      // Role Guard: General Approvals Queue
      if (targetPath.startsWith('/approvals')) {
        if (!authState.isManager) {
          return '/unauthorized?required=Approver&from=${Uri.encodeComponent(targetPath)}';
        }
      }

      // Role Guard: Expense Analytics & Reports
      if (targetPath.startsWith('/reports')) {
        if (!authState.isManager) {
          return '/unauthorized?required=Managerial&from=${Uri.encodeComponent(targetPath)}';
        }
      }

      // Role Guard: Administrator Console & Governance
      if (targetPath.startsWith('/admin')) {
        if (!authState.isAdmin) {
          return '/unauthorized?required=Administrator&from=${Uri.encodeComponent(targetPath)}';
        }
      }

      // Standard employee routes are accessible to all authenticated active employees
      return null;
    }

    return null;
  }
}
