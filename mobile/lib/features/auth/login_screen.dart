import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/auth/auth_notifier.dart';
import '../../app/theme/asm_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      _emailController.text = 'employee@alseermarine.com';
      _passwordController.text = 'Password123!';
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    var email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your Employee ID or corporate email and password.';
      });
      return;
    }

    // Support entering either raw Emp ID (e.g. 37317) or full email
    if (!email.contains('@')) {
      email = '$email@alseermarine.com';
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await AuthNotifier().signIn(email, password);
      if (mounted) {
        context.go('/dashboard');
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Login failed. Please verify your ASM credentials.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AsmTheme.primaryNavy,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Official ASM Logo
                      Center(
                        child: Container(
                          height: 52,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Image.asset(
                            'assets/images/asmlogo.png',
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Text(
                              'AL SEER MARINE',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.5,
                                color: AsmTheme.primaryNavy,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Expense & Reimbursement Portal',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AsmTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 24),

                      if (_errorMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AsmTheme.statusRejected.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AsmTheme.statusRejected.withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: AsmTheme.statusRejected,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],

                      // Email / Emp ID Field
                      const Text(
                        'Employee ID or Corporate Email',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AsmTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.text,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          hintText: 'e.g. 37317 or name@alseermarine.com',
                        ),
                      ),
                      const SizedBox(height: 18),

                      // Password Field
                      const Text(
                        'Password',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AsmTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          hintText: 'Enter corporate password',
                        ),
                        onSubmitted: (_) => _handleLogin(),
                      ),
                      const SizedBox(height: 26),

                      // Submit Button
                      ElevatedButton(
                        onPressed: _isLoading ? null : _handleLogin,
                        child: _isLoading
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              )
                            : const Text('Sign In'),
                      ),
                      if (kDebugMode) ...[
                        const SizedBox(height: 22),
                        // Test persona switcher: 1-click fill for testing in debug mode
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: const [
                                  Icon(Icons.badge_outlined, size: 15, color: AsmTheme.primaryNavy),
                                  SizedBox(width: 6),
                                  Text(
                                    'TEST PERSONAS (1-CLICK FILL)',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6,
                                      color: AsmTheme.primaryNavy,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Tap any role to instantly populate login credentials:',
                                style: TextStyle(fontSize: 11, color: AsmTheme.textSecondary),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  _buildRoleChip(
                                    role: 'Employee',
                                    email: 'employee@alseermarine.com',
                                  ),
                                  _buildRoleChip(
                                    role: 'Line Manager',
                                    email: 'manager@alseermarine.com',
                                  ),
                                  _buildRoleChip(
                                    role: 'HOD',
                                    email: 'hod@alseermarine.com',
                                  ),
                                  _buildRoleChip(
                                    role: 'Management',
                                    email: 'management@alseermarine.com',
                                  ),
                                  _buildRoleChip(
                                    role: 'Finance',
                                    email: 'finance@alseermarine.com',
                                  ),
                                  _buildRoleChip(
                                    role: 'Admin',
                                    email: 'admin@alseermarine.com',
                                  ),
                                  _buildRoleChip(
                                    role: 'Staff 37317',
                                    email: '37317@alseermarine.com',
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Protected internal business application. Password for all test roles: Password123!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: AsmTheme.textMuted,
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 24),
                        const Text(
                          'Protected enterprise application for authorized Al Seer Marine personnel only.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            color: AsmTheme.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoleChip({
    required String role,
    required String email,
  }) {
    final isSelected = _emailController.text == email;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        setState(() {
          _emailController.text = email;
          _passwordController.text = 'Password123!';
          _errorMessage = null;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? AsmTheme.primaryNavy : Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? AsmTheme.primaryNavy : const Color(0xFFCBD5E1),
            width: isSelected ? 1.5 : 1.0,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AsmTheme.primaryNavy.withValues(alpha: 0.15),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  )
                ]
              : null,
        ),
        child: Text(
          role,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: isSelected ? Colors.white : AsmTheme.textPrimary,
          ),
        ),
      ),
    );
  }
}
