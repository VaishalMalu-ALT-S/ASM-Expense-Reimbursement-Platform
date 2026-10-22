import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../app/theme/asm_theme.dart';
import '../../core/utils/money_utils.dart';

class MonthlyTotal {
  final String label;
  final int amountMinor;

  const MonthlyTotal(this.label, this.amountMinor);
}

/// Enterprise Spline Area Chart matching the Zoho Expense benchmark standard.
/// Features:
/// - Smooth cubic Bézier spline interpolation with ASM Brand Navy/Blue palette
/// - Lush vertical area gradient fill
/// - Glowing hollow circular nodes at data coordinates
/// - Clean horizontal gridlines and dynamic Y-axis scale (80K, 60K, 40K, 20K, 0)
/// - X-axis month labels with responsive positioning and hover tooltips
class SpendSummaryChart extends StatefulWidget {
  final List<MonthlyTotal> data;
  final double height;
  final String? fiscalYearLabel;

  const SpendSummaryChart({
    super.key,
    required this.data,
    this.height = 200,
    this.fiscalYearLabel,
  });

  @override
  State<SpendSummaryChart> createState() => _SpendSummaryChartState();
}

class _SpendSummaryChartState extends State<SpendSummaryChart> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    if (widget.data.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: const Center(
          child: Text(
            'No expense activity available for this period.',
            style: TextStyle(color: AsmTheme.textSecondary, fontSize: 13),
          ),
        ),
      );
    }

    final maxSpend = widget.data.fold<int>(0, (m, d) => d.amountMinor > m ? d.amountMinor : m);
    final scaleCeiling = _computeNiceCeiling(maxSpend);

    return Semantics(
      label: 'Monthly claimed amounts: ${widget.data.map((d) => '${d.label} ${MoneyUtils.format(d.amountMinor)}').join(', ')}',
      excludeSemantics: true,
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            const leftGutter = 46.0;
            const rightGutter = 16.0;
            const topGutter = 24.0;
            const bottomGutter = 28.0;

            final plotWidth = math.max(10.0, constraints.maxWidth - leftGutter - rightGutter);
            final plotHeight = math.max(10.0, constraints.maxHeight - topGutter - bottomGutter);

            final points = <Offset>[];
            final n = widget.data.length;
            for (var i = 0; i < n; i++) {
              final x = n == 1 ? (leftGutter + plotWidth / 2) : (leftGutter + (i / (n - 1)) * plotWidth);
              final frac = scaleCeiling == 0 ? 0.0 : (widget.data[i].amountMinor / scaleCeiling).clamp(0.0, 1.0);
              final y = topGutter + (1.0 - frac) * plotHeight;
              points.add(Offset(x, y));
            }

            return MouseRegion(
              onHover: (event) {
                final localX = event.localPosition.dx;
                var closestIndex = 0;
                var closestDist = double.infinity;
                for (var i = 0; i < points.length; i++) {
                  final dist = (points[i].dx - localX).abs();
                  if (dist < closestDist) {
                    closestDist = dist;
                    closestIndex = i;
                  }
                }
                if (_hoveredIndex != closestIndex) {
                  setState(() => _hoveredIndex = closestIndex);
                }
              },
              onExit: (_) {
                if (_hoveredIndex != null) setState(() => _hoveredIndex = null);
              },
              child: GestureDetector(
                onTapDown: (details) {
                  final localX = details.localPosition.dx;
                  var closestIndex = 0;
                  var closestDist = double.infinity;
                  for (var i = 0; i < points.length; i++) {
                    final dist = (points[i].dx - localX).abs();
                    if (dist < closestDist) {
                      closestDist = dist;
                      closestIndex = i;
                    }
                  }
                  setState(() => _hoveredIndex = closestIndex);
                },
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // 1. CustomPainter for Gridlines, Spline Curve, Area Fill and Glowing Dots
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _SplineAreaPainter(
                          data: widget.data,
                          points: points,
                          scaleCeiling: scaleCeiling,
                          leftGutter: leftGutter,
                          rightGutter: rightGutter,
                          topGutter: topGutter,
                          bottomGutter: bottomGutter,
                          hoveredIndex: _hoveredIndex,
                        ),
                      ),
                    ),

                    // 2. Value Labels Above Points (Satisfies Unit Tests & Immediate Reading)
                    for (var i = 0; i < widget.data.length; i++) ...[
                      if (widget.data[i].amountMinor > 0)
                        Positioned(
                          left: points[i].dx - 30,
                          top: math.max(0.0, points[i].dy - 20),
                          width: 60,
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                MoneyUtils.formatAmount(widget.data[i].amountMinor).split('.').first,
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: AsmTheme.primaryNavy,
                                ),
                              ),
                            ),
                          ),
                        ),

                      // 3. Month Labels Below Chart (Satisfies Unit Tests)
                      Positioned(
                        left: points[i].dx - 22,
                        bottom: 4,
                        width: 44,
                        child: Center(
                          child: Text(
                            widget.data[i].label,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: i == _hoveredIndex ? FontWeight.w800 : FontWeight.w600,
                              color: i == _hoveredIndex ? AsmTheme.primaryNavy : const Color(0xFF64748B),
                            ),
                          ),
                        ),
                      ),
                    ],

                    // 4. Interactive Hover Popover Tooltip
                    if (_hoveredIndex != null && _hoveredIndex! < widget.data.length) ...[
                      Positioned(
                        left: math.max(leftGutter, math.min(constraints.maxWidth - 120, points[_hoveredIndex!].dx - 55)),
                        top: math.max(2.0, points[_hoveredIndex!].dy - 44),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: AsmTheme.primaryNavy,
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.20),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            '${widget.data[_hoveredIndex!].label}: ${MoneyUtils.format(widget.data[_hoveredIndex!].amountMinor)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static int _computeNiceCeiling(int max) {
    if (max <= 0) return 8000000; // Default 80K AED ceiling for clean empty grid
    if (max <= 100000) {
      // Up to 1,000 AED
      return ((max / 20000).ceil()) * 20000;
    }
    if (max <= 1000000) {
      // Up to 10,000 AED
      return ((max / 200000).ceil()) * 200000;
    }
    if (max <= 10000000) {
      // Up to 100,000 AED (e.g. 80K)
      return ((max / 2000000).ceil()) * 2000000;
    }
    return ((max / 10000000).ceil()) * 10000000;
  }
}

class _SplineAreaPainter extends CustomPainter {
  final List<MonthlyTotal> data;
  final List<Offset> points;
  final int scaleCeiling;
  final double leftGutter;
  final double rightGutter;
  final double topGutter;
  final double bottomGutter;
  final int? hoveredIndex;

  _SplineAreaPainter({
    required this.data,
    required this.points,
    required this.scaleCeiling,
    required this.leftGutter,
    required this.rightGutter,
    required this.topGutter,
    required this.bottomGutter,
    this.hoveredIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final plotRect = Rect.fromLTWH(
      leftGutter,
      topGutter,
      math.max(10.0, size.width - leftGutter - rightGutter),
      math.max(10.0, size.height - topGutter - bottomGutter),
    );

    // 1. Draw 5 Horizontal Gridlines with Y-Axis Tick Labels
    const ticks = 4;
    final gridPaint = Paint()
      ..color = const Color(0xFFF1F5F9)
      ..strokeWidth = 1.0;

    for (var i = 0; i <= ticks; i++) {
      final y = plotRect.top + (i / ticks) * plotRect.height;
      final val = (scaleCeiling * (ticks - i) / ticks).round();

      // Horizontal gridline
      canvas.drawLine(Offset(plotRect.left, y), Offset(plotRect.right, y), gridPaint);

      // Y-axis label text on the left
      final label = _formatTick(val);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: Color(0xFF94A3B8),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plotRect.left - tp.width - 8, y - tp.height / 2));
    }

    if (points.isEmpty) return;

    // 2. Build Cubic Bézier Spline Path
    final splinePath = Path();
    splinePath.moveTo(points.first.dx, points.first.dy);

    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final dx = p1.dx - p0.dx;
      final cp1 = Offset(p0.dx + dx * 0.5, p0.dy);
      final cp2 = Offset(p0.dx + dx * 0.5, p1.dy);
      splinePath.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p1.dx, p1.dy);
    }

    // 3. Draw Area Gradient Fill Under Curve
    final areaPath = Path.from(splinePath);
    areaPath.lineTo(points.last.dx, plotRect.bottom);
    areaPath.lineTo(points.first.dx, plotRect.bottom);
    areaPath.close();

    final areaPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0x280284C7), // Light translucent brand blue
          Color(0x000284C7), // Fade to transparent
        ],
      ).createShader(plotRect);

    canvas.drawPath(areaPath, areaPaint);

    // 4. Draw Stroke Curve
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = const Color(0xFF0284C7) // ASM Brand Blue / Cyan
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(splinePath, strokePaint);

    // 5. Draw Glowing Circular Nodes at Data Points
    for (var i = 0; i < points.length; i++) {
      final pt = points[i];
      final isHovered = hoveredIndex == i;

      // Subtle outer halo
      canvas.drawCircle(
        pt,
        isHovered ? 7.5 : 5.0,
        Paint()..color = const Color(0xFF0284C7).withValues(alpha: isHovered ? 0.35 : 0.16),
      );

      // Inner white disc
      canvas.drawCircle(
        pt,
        isHovered ? 5.0 : 4.0,
        Paint()..color = Colors.white,
      );

      // Outer colored ring
      canvas.drawCircle(
        pt,
        isHovered ? 5.0 : 4.0,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = isHovered ? 2.6 : 2.0
          ..color = const Color(0xFF0284C7),
      );
    }
  }

  static String _formatTick(int val) {
    if (val >= 100000000) {
      return '${(val / 100000000).toStringAsFixed(0)} M';
    }
    if (val >= 100000) {
      return '${(val / 100000).toStringAsFixed(0)} K';
    }
    if (val == 0) return '0';
    return (val / 100).toStringAsFixed(0);
  }

  @override
  bool shouldRepaint(covariant _SplineAreaPainter oldDelegate) {
    return oldDelegate.scaleCeiling != scaleCeiling ||
        oldDelegate.points != points ||
        oldDelegate.hoveredIndex != hoveredIndex;
  }
}

/// Standalone Card matching the "SPEND SUMMARY" Card from Zoho Expense benchmark
class SpendSummaryCard extends StatelessWidget {
  final List<MonthlyTotal> data;
  final String title;
  final String fiscalYear;
  final String periodLabel;
  final List<String> availablePeriods;
  final ValueChanged<String>? onPeriodChanged;

  const SpendSummaryCard({
    super.key,
    required this.data,
    this.title = 'SPEND SUMMARY',
    this.fiscalYear = 'FISCAL YEAR: 2025 - 2026',
    this.periodLabel = 'This Fiscal Year',
    this.availablePeriods = const ['This Fiscal Year', 'Last 6 Months', 'This Month', 'All Time'],
    this.onPeriodChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AsmTheme.borderLight),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.03),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Row: SPEND SUMMARY title + dropdown button
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Color(0xFF64748B),
                ),
              ),
              if (onPeriodChanged != null)
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFCBD5E1), width: 0.8),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: availablePeriods.contains(periodLabel) ? periodLabel : availablePeriods.first,
                      icon: const Icon(Icons.keyboard_arrow_down, size: 16, color: Color(0xFF64748B)),
                      isDense: true,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AsmTheme.textHeading,
                      ),
                      onChanged: (val) {
                        if (val != null) onPeriodChanged!(val);
                      },
                      items: availablePeriods
                          .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                          .toList(),
                    ),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    periodLabel,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF475569),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Subtitle: FISCAL YEAR: 2025 - 2026
          Center(
            child: Text(
              fiscalYear,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
                color: Color(0xFF94A3B8),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // The Spline Chart Canvas
          SpendSummaryChart(data: data, height: 210),
        ],
      ),
    );
  }
}

/// Standalone Card matching the "OVERALL SUMMARY" Card from Zoho Expense benchmark
class OverallSummaryCard extends StatelessWidget {
  final int totalExpensesMinor;
  final int advancesMinor;
  final int reimbursementsMinor;
  final int totalClaimsCount;
  final String periodLabel;
  final VoidCallback? onTapExpenses;
  final VoidCallback? onTapAdvances;
  final VoidCallback? onTapReimbursements;
  final VoidCallback? onTapClaims;

  const OverallSummaryCard({
    super.key,
    required this.totalExpensesMinor,
    this.advancesMinor = 0,
    required this.reimbursementsMinor,
    required this.totalClaimsCount,
    this.periodLabel = 'This Fiscal Year',
    this.onTapExpenses,
    this.onTapAdvances,
    this.onTapReimbursements,
    this.onTapClaims,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AsmTheme.borderLight),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.03),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Row: OVERALL SUMMARY + dropdown
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'OVERALL SUMMARY',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Color(0xFF64748B),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  periodLabel,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF475569),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // 1. Total Expenses Row
          _buildSummaryRow(
            icon: Icons.receipt_long_outlined,
            iconColor: const Color(0xFFEA580C),
            iconBgColor: const Color(0xFFFFEDD5),
            title: 'Total Expenses',
            value: MoneyUtils.format(totalExpensesMinor),
            onTap: onTapExpenses,
          ),
          const Divider(height: 24, thickness: 0.6, color: Color(0xFFF1F5F9)),

          // 2. Reimbursements Row
          _buildSummaryRow(
            icon: Icons.payments_outlined,
            iconColor: const Color(0xFF0284C7),
            iconBgColor: const Color(0xFFE0F2FE),
            title: 'Reimbursements',
            value: MoneyUtils.format(reimbursementsMinor),
            onTap: onTapReimbursements,
          ),
          const Divider(height: 24, thickness: 0.6, color: Color(0xFFF1F5F9)),

          // 4. Total Claims Row
          _buildSummaryRow(
            icon: Icons.folder_outlined,
            iconColor: const Color(0xFF16A34A),
            iconBgColor: const Color(0xFFDCFCE7),
            title: 'Total Claims',
            value: totalClaimsCount.toString(),
            onTap: onTapClaims,
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow({
    required IconData icon,
    required Color iconColor,
    required Color iconBgColor,
    required String title,
    required String value,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Container(
              height: 38,
              width: 38,
              decoration: BoxDecoration(
                color: iconBgColor,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF64748B),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.info_outline, size: 12, color: Color(0xFF94A3B8)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AsmTheme.textHeading,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
