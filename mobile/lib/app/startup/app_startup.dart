import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/auth/auth_notifier.dart';

/// One-time app initialization (Supabase, then session and roles).
///
/// Started from main() before the first frame and awaited by the splash
/// screen, so it runs exactly once whichever route the app opens on. Each step
/// is time-bounded and never throws: on failure AuthNotifier settles to a
/// state RouteGuard already handles (login, role-unavailable, loading).
class AppStartup {
  AppStartup._();

  static const supabaseTimeout = Duration(seconds: 10);
  static const authTimeout = Duration(seconds: 15);

  static Future<void>? _ready;

  /// Completes when initialization has finished or given up.
  static Future<void> get ready => _ready ??= _run();

  static Future<void> _run() async {
    try {
      await Supabase.initialize(
        url: const String.fromEnvironment(
          'SUPABASE_URL',
          defaultValue: 'https://vrnqemqzmklrjpssneng.supabase.co',
        ),
        anonKey: const String.fromEnvironment(
          'SUPABASE_ANON_KEY',
          defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZybnFlbXF6bWtscmpwc3NuZW5nIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIzMTc4NTUsImV4cCI6MjEwNzg5Mzg1NX0.Z4DQaxXetoINqVH_Q2mOkICyZEa3B3cieB_IW4oQu7k',
        ),
      ).timeout(supabaseTimeout);
    } catch (e, stack) {
      debugPrint('Supabase initialization fallback: $e\n$stack');
    }

    // Initialize corporate auth and role-based permissions state
    try {
      await AuthNotifier().initialize().timeout(authTimeout);
    } catch (e, stack) {
      debugPrint('AuthNotifier initialization fallback: $e\n$stack');
    }
  }
}
