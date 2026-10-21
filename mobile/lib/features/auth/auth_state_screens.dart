import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../app/theme/asm_theme.dart';
import '../../core/auth/auth_notifier.dart';

/// Professional ASM Loading Screen preventing flashes of protected content
class AuthLoadingScreen extends StatelessWidget {
  const AuthLoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AsmTheme.surfaceBackground,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Card(
            elevation: 2,
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AsmTheme.borderLight),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AsmTheme.primaryNavy,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Center(
                      child: Text(
                        'AL SEER MARINE',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(AsmTheme.primaryNavy),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Verifying Credentials',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AsmTheme.textHeading,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Securing your corporate session and role permissions...',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: AsmTheme.textBody,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Professional Unauthorized Access Screen
class UnauthorizedScreen extends StatelessWidget {
  final String? requiredRole;
  final String? fromPath;

  const UnauthorizedScreen({
    super.key,
    this.requiredRole,
    this.fromPath,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AsmTheme.surfaceBackground,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            elevation: 2,
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AsmTheme.borderLight),
            ),
            child: Padding(
              padding: const EdgeInsets.all(36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AsmTheme.statusRejectedBg,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.lock_outline,
                      color: AsmTheme.statusRejected,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Access Restricted',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AsmTheme.textHeading,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    requiredRole != null
                        ? 'This section requires $requiredRole role authorization. Your ASM account is not provisioned for this resource.'
                        : 'You do not have the required permissions to view this screen. Access is logged and restricted according to company policy.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AsmTheme.textBody,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    height: 40,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AsmTheme.primaryNavy,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      onPressed: () => context.go('/dashboard'),
                      child: const Text(
                        'Return to Dashboard',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Professional Session Expired Screen
class SessionExpiredScreen extends StatelessWidget {
  const SessionExpiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AsmTheme.surfaceBackground,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            elevation: 2,
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AsmTheme.borderLight),
            ),
            child: Padding(
              padding: const EdgeInsets.all(36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AsmTheme.statusWarningBg,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.schedule,
                      color: AsmTheme.statusWarning,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Session Expired',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AsmTheme.textHeading,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Your security session has expired due to inactivity. Please sign in again with your ASM corporate credentials.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: AsmTheme.textBody,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    height: 40,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AsmTheme.primaryNavy,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      onPressed: () async {
                        await AuthNotifier().signOut();
                        if (context.mounted) context.go('/login');
                      },
                      child: const Text(
                        'Sign In Again',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Professional Inactive Account Screen
class AccountInactiveScreen extends StatelessWidget {
  const AccountInactiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AsmTheme.surfaceBackground,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            elevation: 2,
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AsmTheme.borderLight),
            ),
            child: Padding(
              padding: const EdgeInsets.all(36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AsmTheme.surfaceMuted,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.person_off_outlined,
                      color: AsmTheme.textMuted,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Account Inactive',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AsmTheme.textHeading,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Your employee profile is currently inactive in the ASM directory. Access to expense and advance workflows has been paused. Please contact Human Resources or your manager.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: AsmTheme.textBody,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    height: 40,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AsmTheme.primaryNavy,
                        side: const BorderSide(color: AsmTheme.borderLight),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      onPressed: () async {
                        await AuthNotifier().signOut();
                        if (context.mounted) context.go('/login');
                      },
                      child: const Text(
                        'Return to Sign In',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Professional Role / Network Resolution Failure Screen
class RoleUnavailableScreen extends StatelessWidget {
  const RoleUnavailableScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final errorMessage = AuthNotifier().state.errorMessage ??
        'Unable to resolve employee permissions at this time.';

    return Scaffold(
      backgroundColor: AsmTheme.surfaceBackground,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            elevation: 2,
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AsmTheme.borderLight),
            ),
            child: Padding(
              padding: const EdgeInsets.all(36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AsmTheme.statusWarningBg,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.cloud_off_outlined,
                      color: AsmTheme.statusWarning,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Permissions Unavailable',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AsmTheme.textHeading,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    errorMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AsmTheme.textBody,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AsmTheme.textHeading,
                              side: const BorderSide(color: AsmTheme.borderLight),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                            onPressed: () async {
                              await AuthNotifier().signOut();
                              if (context.mounted) context.go('/login');
                            },
                            child: const Text('Sign Out', style: TextStyle(fontSize: 13)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AsmTheme.primaryNavy,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                            onPressed: () => AuthNotifier().refreshProfile(),
                            child: const Text(
                              'Retry',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
