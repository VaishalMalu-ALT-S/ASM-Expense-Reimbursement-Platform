import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../app/startup/app_startup.dart';
import '../../app/theme/asm_theme.dart';

/// Layer geometry in the coordinate space of the approved 576x1024 splash
/// artwork (see tool/build_splash_layers.py, which produced the layers).
class SplashLayout {
  static const Size artwork = Size(576, 1024);
  static const Rect logo = Rect.fromLTWH(82, 272, 426, 82);
  static const Rect tagline = Rect.fromLTWH(84, 380, 408, 56);
  static const Offset spinnerCentre = Offset(288, 796);
  static const double spinnerDiameter = 42;
  static const double loadingTextTop = 834;

  /// Wider than this (tablets in landscape, foldables) the artwork is shown
  /// whole instead of cropped, so the logo and loader are never cut off.
  static const double maxCoverAspect = 0.75;

  /// On tall phones the sides are cropped by at most this much (artwork px per
  /// side), which keeps the logo clear of the screen edge.
  static const double maxSideCrop = 60;

  /// Artwork scale for a screen: full-bleed cover where possible, otherwise the
  /// largest scale that keeps the logo and loader on screen.
  static double scaleFor(Size screen) {
    final cover = math.max(screen.width / artwork.width, screen.height / artwork.height);
    final contain = math.min(screen.width / artwork.width, screen.height / artwork.height);
    if (screen.width / screen.height > maxCoverAspect) return contain;
    return math.min(cover, screen.width / (artwork.width - 2 * maxSideCrop));
  }
}

/// Branded launch screen shown while [AppStartup] initializes. It then hands
/// over to the existing router: `/dashboard` is requested and RouteGuard sends
/// the user to login, the authenticated home, or the matching status screen.
class SplashScreen extends StatefulWidget {
  /// Initialization to wait for; defaults to the app's one-time startup.
  final Future<void>? ready;

  /// Shortest time the splash stays visible so the entrance is not a flash.
  final Duration minVisible;

  /// Longest time the splash waits; afterwards RouteGuard's loading screen takes over.
  final Duration maxWait;

  /// Route requested once startup is done; RouteGuard decides the final destination.
  final String destination;

  const SplashScreen({
    super.key,
    this.ready,
    this.minVisible = const Duration(milliseconds: 1200),
    this.maxWait = const Duration(seconds: 8),
    this.destination = '/dashboard',
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  static const _plate = AssetImage('assets/splash/splash_plate.jpg');
  static const _logo = AssetImage('assets/splash/splash_logo.png');
  static const _tagline = AssetImage('assets/splash/splash_tagline.png');
  static const _cyan = Color(0xFF35BDF2);

  late final AnimationController _entrance =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  bool _started = false;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    _awaitStartup();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _entrance.value = 1;
      return;
    }
    // Start once the artwork is decoded so the fade never reveals a blank frame;
    // a slow decode does not hold the entrance back for long.
    final decoded = Future.wait([
      precacheImage(_plate, context),
      precacheImage(_logo, context),
      precacheImage(_tagline, context),
    ]);
    Future.any([decoded, Future<void>.delayed(const Duration(milliseconds: 400))])
        .whenComplete(() {
      if (mounted && !_entrance.isAnimating && _entrance.value == 0) _entrance.forward();
    });
  }

  Future<void> _awaitStartup() async {
    final ready = (widget.ready ?? AppStartup.ready).catchError((Object e) {
      debugPrint('Startup failed: $e');
    });
    await Future.wait([
      ready.timeout(widget.maxWait, onTimeout: () {}),
      Future<void>.delayed(widget.minVisible),
    ]);
    _leave();
  }

  void _leave() {
    if (!mounted || _left) return;
    _left = true;
    GoRouter.of(context).go(widget.destination);
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Animation<double> _interval(double begin, double end, [Curve curve = Curves.easeOutCubic]) =>
      CurvedAnimation(parent: _entrance, curve: Interval(begin, end, curve: curve));

  Widget _artworkLayers() {
    final plateFade = _interval(0.0, 0.25, Curves.easeOut);
    // Very slow settle of the whole scene (3% -> 0) for a subtle parallax feel.
    final plateScale = Tween<double>(begin: 1.03, end: 1.0).animate(_interval(0.0, 1.0));
    final logo = _interval(0.06, 0.33);
    final tagline = _interval(0.20, 0.45);
    final loader = _interval(0.30, 0.50, Curves.easeOut);

    Widget rise(Animation<double> a, double distance, Widget child) => AnimatedBuilder(
          animation: a,
          child: child,
          builder: (_, c) => Opacity(
            opacity: a.value,
            child: Transform.translate(offset: Offset(0, (1 - a.value) * distance), child: c),
          ),
        );

    final r = SplashLayout.spinnerDiameter / 2;
    return SizedBox.fromSize(
      size: SplashLayout.artwork,
      child: Stack(children: [
        Positioned.fill(
          child: FadeTransition(
            opacity: plateFade,
            child: ScaleTransition(
              scale: plateScale,
              child: const Image(image: _plate, fit: BoxFit.fill, gaplessPlayback: true),
            ),
          ),
        ),
        Positioned.fromRect(
          rect: SplashLayout.logo,
          child: rise(logo, 14, const Image(image: _logo, fit: BoxFit.fill, semanticLabel: 'ASM Al Seer Marine')),
        ),
        Positioned.fromRect(
          rect: SplashLayout.tagline,
          child: rise(tagline, 8, const Image(image: _tagline, fit: BoxFit.fill, semanticLabel: 'Expense and Claims Management')),
        ),
        Positioned(
          left: SplashLayout.spinnerCentre.dx - r,
          top: SplashLayout.spinnerCentre.dy - r,
          width: r * 2,
          height: r * 2,
          child: FadeTransition(
            opacity: loader,
            child: const CircularProgressIndicator(
              strokeWidth: 3.5,
              color: _cyan,
              backgroundColor: Color(0x33FFFFFF),
              semanticsLabel: 'Loading',
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: SplashLayout.loadingTextTop,
          child: FadeTransition(
            opacity: loader,
            child: const ExcludeSemantics(
              child: Text(
                'Loading...',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xE6FFFFFF), fontSize: 14, letterSpacing: 0.3, fontWeight: FontWeight.w400),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: AsmTheme.primaryNavy,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AsmTheme.primaryNavy,
        body: LayoutBuilder(builder: (context, c) {
          final screen = c.biggest;
          final scale = SplashLayout.scaleFor(screen);
          final drawn = SplashLayout.artwork * scale;
          // Any uncovered edge (landscape, very tall phones) is filled with a soft blur of the artwork.
          final hasGaps = drawn.width < screen.width - 0.5 || drawn.height < screen.height - 0.5;
          final scene = ClipRect(
            child: OverflowBox(
              minWidth: 0,
              minHeight: 0,
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: SizedBox.fromSize(
                size: drawn,
                child: FittedBox(fit: BoxFit.fill, child: _artworkLayers()),
              ),
            ),
          );
          return Stack(fit: StackFit.expand, children: [
            if (hasGaps)
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: FadeTransition(
                  opacity: _interval(0.0, 0.25, Curves.easeOut),
                  child: const Image(image: _plate, fit: BoxFit.cover),
                ),
              ),
            // Full-bleed artwork; logo and loader sit well inside system insets on supported ratios.
            scene,
          ]);
        }),
      ),
    );
  }
}
