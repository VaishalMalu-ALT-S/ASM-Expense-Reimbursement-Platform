import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asm_expense/app/theme/asm_theme.dart';

void main() {
  testWidgets('ASM Theme and Branding test', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AsmTheme.lightTheme,
        home: const Scaffold(
          body: Center(child: Text('AL SEER MARINE')),
        ),
      ),
    );
    expect(find.text('AL SEER MARINE'), findsOneWidget);
  });
}
