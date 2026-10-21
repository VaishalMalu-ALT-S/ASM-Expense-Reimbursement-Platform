import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:asm_expense/core/auth/auth_notifier.dart';
import 'package:asm_expense/core/auth/auth_state.dart';
import 'package:asm_expense/core/auth/route_guard.dart';
import 'package:asm_expense/features/splash/splash_screen.dart';
import 'package:asm_expense/shared/models/employee.dart';

const _minVisible = Duration(milliseconds: 1200);
const _maxWait = Duration(seconds: 8);

final _employee = AuthState.authenticated(Employee(
  id: 'emp-1',
  employeeCode: 'ASM-1',
  fullName: 'Test Employee',
  email: 'test@alseermarine.com',
  roles: const [AppRole.employee],
));

/// Same guard wiring as the app router; destinations are stubs.
GoRouter _router(Future<void> ready) => GoRouter(
      initialLocation: '/splash',
      refreshListenable: AuthNotifier(),
      redirect: (context, state) => RouteGuard.evaluate(
        targetPath: state.uri.path,
        authState: AuthNotifier().state,
        queryParams: state.uri.queryParameters,
      ),
      routes: [
        GoRoute(path: '/splash', builder: (_, __) => SplashScreen(ready: ready, minVisible: _minVisible, maxWait: _maxWait)),
        for (final p in ['/login', '/dashboard', '/loading', '/session-expired', '/role-unavailable'])
          GoRoute(path: p, builder: (_, __) => Scaffold(body: Text('PAGE $p'))),
      ],
    );

Future<GoRouter> _launch(WidgetTester tester, Future<void> ready, {Size size = const Size(390, 844), bool reduceMotion = false}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final router = _router(ready);
  await tester.pumpWidget(MediaQuery(
    data: MediaQueryData(size: size, disableAnimations: reduceMotion),
    child: MaterialApp.router(routerConfig: router),
  ));
  return router;
}

bool _onSplash() => find.byType(SplashScreen).evaluate().isNotEmpty;

void main() {
  setUp(() => AuthNotifier().setMockState(const AuthState.loading()));

  testWidgets('logged-out user: splash then login, splash removed from history', (tester) async {
    final semantics = tester.ensureSemantics();
    AuthNotifier().setMockState(const AuthState.unauthenticated());
    final router = await _launch(tester, Future.value());
    expect(_onSplash(), isTrue);
    double logoOpacity() => tester
        .widget<Opacity>(find.ancestor(of: find.byWidgetPredicate((w) => w is Image && w.semanticLabel == 'ASM Al Seer Marine'),
            matching: find.byType(Opacity)).first)
        .opacity;
    expect(logoOpacity(), 0, reason: 'logo starts hidden');

    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_onSplash(), isTrue, reason: 'minimum visible time not over yet');
    expect(logoOpacity(), greaterThan(0.5), reason: 'logo fades in during the first second');
    expect(find.bySemanticsLabel('ASM Al Seer Marine'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('PAGE /login'), findsOneWidget);
    expect(_onSplash(), isFalse);
    expect(router.canPop(), isFalse);
    semantics.dispose();
  });

  testWidgets('existing session: splash then authenticated home', (tester) async {
    AuthNotifier().setMockState(_employee);
    await _launch(tester, Future.value());
    await tester.pump(_minVisible);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('PAGE /dashboard'), findsOneWidget);
  });

  testWidgets('expired session goes to the existing session-expired screen', (tester) async {
    AuthNotifier().setMockState(const AuthState.sessionExpired());
    await _launch(tester, Future.value());
    await tester.pump(_minVisible);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('PAGE /session-expired'), findsOneWidget);
  });

  testWidgets('slow initialization keeps the splash until startup completes', (tester) async {
    final ready = Completer<void>();
    await _launch(tester, ready.future);
    await tester.pump(const Duration(seconds: 3));
    expect(_onSplash(), isTrue);
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'loader animates while waiting');

    AuthNotifier().setMockState(const AuthState.unauthenticated());
    ready.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('PAGE /login'), findsOneWidget);
  });

  testWidgets('fast initialization still shows the entrance for the minimum time only', (tester) async {
    AuthNotifier().setMockState(const AuthState.unauthenticated());
    await _launch(tester, Future.value());
    await tester.pump(_minVisible - const Duration(milliseconds: 50));
    expect(_onSplash(), isTrue);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_onSplash(), isFalse);
  });

  testWidgets('startup that never finishes does not trap the user on the splash', (tester) async {
    await _launch(tester, Completer<void>().future);
    await tester.pump(_maxWait);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_onSplash(), isFalse);
    expect(find.text('PAGE /loading'), findsOneWidget, reason: 'RouteGuard loading screen takes over');
  });

  testWidgets('startup failure (e.g. Supabase init error) still hands over', (tester) async {
    AuthNotifier().setMockState(const AuthState.unauthenticated());
    final ready = Completer<void>();
    await _launch(tester, ready.future);
    await tester.pump(const Duration(milliseconds: 200));
    ready.completeError(StateError('Supabase initialization failed'));
    await tester.pump(_minVisible);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('PAGE /login'), findsOneWidget);
  });

  testWidgets('profile verification failure goes to the existing role-unavailable screen', (tester) async {
    AuthNotifier().setMockState(const AuthState.roleUnavailable('Network error'));
    await _launch(tester, Future.value());
    await tester.pump(_minVisible);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('PAGE /role-unavailable'), findsOneWidget);
  });

  testWidgets('back button during splash does not navigate or break startup', (tester) async {
    final ready = Completer<void>();
    await _launch(tester, ready.future);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(_onSplash(), isTrue);

    AuthNotifier().setMockState(const AuthState.unauthenticated());
    ready.complete();
    await tester.pump(_minVisible);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('PAGE /login'), findsOneWidget);
  });

  testWidgets('reduced motion shows the artwork at once without entrance motion', (tester) async {
    final ready = Completer<void>();
    await _launch(tester, ready.future, reduceMotion: true);
    await tester.pump();
    final opacities = tester.widgetList<Opacity>(find.descendant(of: find.byType(SplashScreen), matching: find.byType(Opacity)));
    expect(opacities, isNotEmpty);
    expect(opacities.every((o) => o.opacity == 1), isTrue);
    AuthNotifier().setMockState(const AuthState.unauthenticated());
    ready.complete();
    await tester.pump(_minVisible);
    await tester.pump(const Duration(milliseconds: 500));
  });

  for (final (name, size, gaps) in [
    ('small 16:9 phone', const Size(320, 568), false),
    ('19.5:9 phone', const Size(412, 915), false),
    ('21:9 phone', const Size(412, 961), true),
    ('large phone', const Size(480, 1067), false),
    ('tablet portrait', const Size(800, 1280), false),
    ('landscape', const Size(915, 412), true),
  ]) {
    testWidgets('layout on $name: no overflow, no stretch, logo and loader on screen', (tester) async {
      final ready = Completer<void>();
      await _launch(tester, ready.future, size: size);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
      final screen = Offset.zero & size;
      final logo = tester.getRect(find.byWidgetPredicate((w) => w is Image && w.semanticLabel == 'ASM Al Seer Marine'));
      final tagline = tester.getRect(find.byWidgetPredicate((w) => w is Image && w.semanticLabel == 'Expense and Claims Management'));
      final loader = tester.getRect(find.byType(CircularProgressIndicator));
      for (final r in [logo, tagline, loader]) {
        expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight - const Offset(0.01, 0.01)), isTrue,
            reason: '$r must be fully visible on $size');
      }
      // The logo layer box has ~7 artwork px of transparent margin around the glyphs.
      final glyphInset = 7 * logo.width / 426;
      expect(logo.left + glyphInset, greaterThanOrEqualTo(12), reason: 'logo glyphs keep a margin from the edge');
      expect(size.width - logo.right + glyphInset, greaterThanOrEqualTo(12));
      // Layers are scaled uniformly with the artwork (no stretch).
      expect(logo.width / logo.height, closeTo(426 / 82, 0.01));
      expect(find.byType(ImageFiltered), gaps ? findsOneWidget : findsNothing, reason: 'blur fill only where edges are uncovered');
      AuthNotifier().setMockState(const AuthState.unauthenticated());
      ready.complete();
      await tester.pump(_minVisible);
      await tester.pump(const Duration(milliseconds: 500));
    });
  }

  test('RouteGuard allows the splash in every auth state', () {
    for (final s in [
      const AuthState.loading(),
      const AuthState.unauthenticated(),
      const AuthState.sessionExpired(),
      const AuthState.roleUnavailable('x'),
      _employee,
    ]) {
      expect(RouteGuard.evaluate(targetPath: '/splash', authState: s), isNull);
    }
  });
}
