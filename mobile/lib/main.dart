import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/theme/asm_theme.dart';
import 'app/router/app_router.dart';
import 'app/startup/app_startup.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Supabase + session/role initialization runs while the splash screen is shown.
  AppStartup.ready;

  // Prevent any Red Screen of Death by replacing default error widget with a clean, branded card
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: AsmTheme.surfaceBackground,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AsmTheme.primaryNavy.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.info_outline_rounded, size: 36, color: AsmTheme.primaryNavy),
              ),
              const SizedBox(height: 16),
              const Text(
                'Something unexpected occurred',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AsmTheme.textHeading),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'The system recorded this event. Please refresh or return to the previous screen.',
                style: TextStyle(fontSize: 13, color: AsmTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  };

  // Catch synchronous errors quietly
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };

  runApp(const ProviderScope(child: AsmExpenseApp()));
}

class AsmExpenseApp extends StatelessWidget {
  const AsmExpenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ASM Expense & Reimbursement',
      debugShowCheckedModeBanner: false,
      theme: AsmTheme.lightTheme,
      routerConfig: appRouter,
      builder: (context, child) {
        // Fallback boundary to ensure no unhandled layout crashes display red screen
        return child ?? const SizedBox.shrink();
      },
    );
  }
}
