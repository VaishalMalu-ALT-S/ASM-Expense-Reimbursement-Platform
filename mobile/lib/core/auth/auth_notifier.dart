import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;
import '../network/supabase_service.dart';
import '../../shared/models/employee.dart';
import 'auth_state.dart';

/// Central Authentication and Authorization Notifier
/// Bridges Supabase Auth state, employee profile, and roles to Flutter UI and GoRouter.
class AuthNotifier extends ChangeNotifier {
  static final AuthNotifier _instance = AuthNotifier._internal();
  factory AuthNotifier() => _instance;
  AuthNotifier._internal();

  AuthState _state = const AuthState.loading();
  AuthState get state => _state;

  bool get isAuthenticated => _state.isAuthenticated;
  Employee? get currentEmployee => _state.employee;
  bool get isManager => _state.isManager;
  bool get isManagement => _state.isManagement;
  bool get isFinance => _state.isFinance;
  bool get isHod => _state.isHod;
  bool get isLineManager => _state.isLineManager;
  bool get isAdmin => _state.isAdmin;

  StreamSubscription? _authSubscription;
  bool _isInitialized = false;

  /// Initialize and resolve session and roles
  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    try {
      final client = SupabaseService().client;

      // Listen to Supabase auth events
      client.auth.onAuthStateChange.listen((data) async {
        final event = data.event;
        final session = data.session;

        if (event == AuthChangeEvent.signedOut || session == null) {
          _updateState(const AuthState.unauthenticated());
        } else if (event == AuthChangeEvent.signedIn ||
            event == AuthChangeEvent.tokenRefreshed ||
            event == AuthChangeEvent.userUpdated) {
          await refreshProfile();
        }
      });

      // Resolve initial session
      final session = client.auth.currentSession;
      if (session == null) {
        _updateState(const AuthState.unauthenticated());
      } else {
        await refreshProfile();
      }
    } catch (_) {
      // In test or offline environments where Supabase is uninitialized
      if (_state.status == AuthStatus.loading) {
        _updateState(const AuthState.unauthenticated());
      }
    }
  }

  /// Reload current employee record and assigned roles
  Future<void> refreshProfile() async {
    try {
      final uid = SupabaseService().currentUserId;
      if (uid == null) {
        _updateState(const AuthState.unauthenticated());
        return;
      }

      final employee = await SupabaseService().getCurrentEmployee();
      if (employee == null) {
        _updateState(const AuthState.roleUnavailable(
          'Unable to verify employee profile. Please contact IT support.',
        ));
        return;
      }

      if (!employee.isActive) {
        _updateState(AuthState.inactive(employee));
        return;
      }

      _updateState(AuthState.authenticated(employee));
    } catch (e) {
      _updateState(AuthState.roleUnavailable(
        'Network error while verifying permissions. Please try again.',
      ));
    }
  }

  /// Sign in with corporate credentials
  Future<void> signIn(String email, String password) async {
    _updateState(const AuthState.loading());
    try {
      await SupabaseService().signIn(email, password);
      await refreshProfile();
    } catch (e) {
      _updateState(const AuthState.unauthenticated());
      rethrow;
    }
  }

  /// Sign out and clear protected state
  Future<void> signOut() async {
    try {
      await SupabaseService().signOut();
    } catch (_) {}
    _updateState(const AuthState.unauthenticated());
  }

  /// Manually update state and notify GoRouter / UI
  void _updateState(AuthState newState) {
    _state = newState;
    notifyListeners();
  }

  /// Test harness override to inject deterministic AuthState
  @visibleForTesting
  void setMockState(AuthState mockState) {
    _updateState(mockState);
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }
}
