import 'package:flutter/material.dart';
import '../../app/theme/asm_theme.dart';

/// Status pill. Accepts either the database value (`LINE_MANAGER_REVIEW`) or a
/// display name (`Line Manager Review`). Status is conveyed by text and icon,
/// not by colour alone.
class StatusBadge extends StatelessWidget {
  final String status;
  final bool isLarge;

  const StatusBadge({
    super.key,
    required this.status,
    this.isLarge = false,
  });

  static ({Color bg, Color fg, IconData icon}) styleFor(String status) {
    switch (status.trim().toUpperCase().replaceAll(' ', '_')) {
      case 'APPROVED':
      case 'PAID':
      case 'SETTLED':
        return (bg: AsmTheme.statusApprovedBg, fg: AsmTheme.statusApproved, icon: Icons.check_circle_outline);
      case 'REJECTED':
        return (bg: AsmTheme.statusRejectedBg, fg: AsmTheme.statusRejected, icon: Icons.cancel_outlined);
      case 'CANCELLED':
        return (bg: AsmTheme.surfaceMuted, fg: AsmTheme.textSecondary, icon: Icons.block);
      case 'CORRECTION_REQUIRED':
        return (bg: AsmTheme.statusWarningBg, fg: AsmTheme.statusWarning, icon: Icons.edit_note);
      case 'PARTIALLY_SETTLED':
      case 'REIMBURSEMENT_PROCESSING':
        return (bg: AsmTheme.statusInfoBg, fg: AsmTheme.statusInfo, icon: Icons.timelapse);
      case 'DRAFT':
        return (bg: AsmTheme.surfaceMuted, fg: AsmTheme.textSecondary, icon: Icons.edit_outlined);
      default:
        return (bg: AsmTheme.statusPendingBg, fg: AsmTheme.statusPending, icon: Icons.schedule);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = styleFor(status);
    final label = status.replaceAll('_', ' ');
    return Semantics(
      label: 'Status: $label',
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isLarge ? 10 : 8, vertical: isLarge ? 5 : 3),
        decoration: BoxDecoration(color: s.bg, borderRadius: BorderRadius.circular(4)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(s.icon, size: isLarge ? 13 : 11, color: s.fg),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: isLarge ? 11 : 10, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: s.fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
