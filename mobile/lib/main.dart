import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/theme/asm_theme.dart';
import 'app/router/app_router.dart';
import 'app/startup/app_startup.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Supabase + session/role initialization runs while the splash screen is shown.
  AppStartup.ready;

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
    );
  }
}
