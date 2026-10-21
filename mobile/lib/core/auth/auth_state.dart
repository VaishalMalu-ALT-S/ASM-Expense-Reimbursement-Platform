import '../../shared/models/employee.dart';

/// Authentication and session status states
enum AuthStatus {
  loading,
  unauthenticated,
  authenticated,
  sessionExpired,
  inactive,
  roleUnavailable,
}

/// Immutable state snapshot of authentication, profile, and roles
class AuthState {
  final AuthStatus status;
  final Employee? employee;
  final String? errorMessage;

  const AuthState({
    required this.status,
    this.employee,
    this.errorMessage,
  });

  const AuthState.loading()
      : status = AuthStatus.loading,
        employee = null,
        errorMessage = null;

  const AuthState.unauthenticated()
      : status = AuthStatus.unauthenticated,
        employee = null,
        errorMessage = null;

  const AuthState.sessionExpired()
      : status = AuthStatus.sessionExpired,
        employee = null,
        errorMessage = 'Your session has expired. Please sign in again.';

  const AuthState.inactive(Employee emp)
      : status = AuthStatus.inactive,
        employee = emp,
        errorMessage = 'Your ASM employee account is inactive. Please contact HR.';

  const AuthState.roleUnavailable(String error)
      : status = AuthStatus.roleUnavailable,
        employee = null,
        errorMessage = error;

  const AuthState.authenticated(Employee emp)
      : status = AuthStatus.authenticated,
        employee = emp,
        errorMessage = null;

  bool get isAuthenticated => status == AuthStatus.authenticated && employee != null;

  bool hasRole(AppRole role) {
    if (!isAuthenticated || employee == null) return false;
    return employee!.roles.contains(role);
  }

  bool hasAnyRole(Iterable<AppRole> roles) {
    if (!isAuthenticated || employee == null) return false;
    return employee!.roles.any(roles.contains);
  }

  bool get isAdmin => hasRole(AppRole.admin);

  bool get isFinance => hasRole(AppRole.finance) || isAdmin;

  bool get isManagement => hasRole(AppRole.management) || isAdmin;

  bool get isHod => hasRole(AppRole.departmentManager) || isAdmin;

  bool get isLineManager => hasRole(AppRole.lineManager) || isAdmin;

  /// Any role authorized to view the general approvals queue
  bool get isManager =>
      hasRole(AppRole.lineManager) ||
      hasRole(AppRole.departmentManager) ||
      isManagement ||
      isFinance ||
      isAdmin;

  AuthState copyWith({
    AuthStatus? status,
    Employee? employee,
    String? errorMessage,
  }) {
    return AuthState(
      status: status ?? this.status,
      employee: employee ?? this.employee,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
