import 'package:flutter/material.dart';
import '../../app/theme/asm_theme.dart';

bool _reduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Placeholder rows shaped like list content, so the layout does not jump
/// when real data arrives. Pulses gently unless reduced motion is requested.
class SkeletonList extends StatefulWidget {
  final int rows;
  final double rowHeight;
  final EdgeInsetsGeometry padding;

  const SkeletonList({super.key, this.rows = 5, this.rowHeight = 72, this.padding = const EdgeInsets.all(16)});

  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion(context)) {
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _bar(double widthFactor, double height) => FractionallySizedBox(
        widthFactor: widthFactor,
        child: Container(
          height: height,
          decoration: BoxDecoration(color: AsmTheme.borderLight, borderRadius: BorderRadius.circular(4)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      liveRegion: true,
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.55, end: 1).animate(_c),
          child: ListView.separated(
            physics: const NeverScrollableScrollPhysics(),
            padding: widget.padding,
            itemCount: widget.rows,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, __) => Container(
              height: widget.rowHeight,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AsmTheme.surfaceCard,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AsmTheme.borderLight),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [_bar(0.55, 12), _bar(0.35, 10)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-area message for empty, error, offline and permission states.
class StateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Color? iconColor;

  const StateMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.iconColor,
  });

  const StateMessage.error({super.key, required this.message, this.onAction, this.title = 'Something went wrong'})
      : icon = Icons.error_outline,
        actionLabel = 'Retry',
        iconColor = AsmTheme.statusRejected;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: iconColor ?? AsmTheme.textMuted, semanticLabel: title),
              const SizedBox(height: 14),
              Text(title, textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AsmTheme.textHeading)),
              const SizedBox(height: 6),
              Text(message, textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: AsmTheme.textSecondary, height: 1.4)),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Short fade + slide entrance for list items; the delay is capped so long
/// lists never wait, and it is skipped entirely when reduced motion is on.
class FadeSlideIn extends StatelessWidget {
  final int index;
  final Widget child;

  const FadeSlideIn({super.key, required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    if (_reduceMotion(context)) return child;
    final delay = (index.clamp(0, 6)) * 35;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 220 + delay),
      curve: Interval(delay / (220 + delay), 1, curve: Curves.easeOutCubic),
      builder: (context, t, c) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 8), child: c),
      ),
      child: child,
    );
  }
}

/// Cross-fades between loading, error and content states.
class StateSwitcher extends StatelessWidget {
  final Widget child;

  const StateSwitcher({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: _reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOut,
      child: child,
    );
  }
}
