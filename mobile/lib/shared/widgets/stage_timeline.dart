import 'package:flutter/material.dart';
import '../../app/theme/asm_theme.dart';
import '../workflow/approval_stages.dart';

/// Vertical workflow timeline: completed, current, pending, rejected,
/// correction-required and cancelled stages are visually distinct.
class StageTimeline extends StatelessWidget {
  final List<WorkflowStage> stages;

  const StageTimeline({super.key, required this.stages});

  static ({IconData icon, Color fg, Color bg, String label}) _style(StageState s) => switch (s) {
        StageState.completed => (icon: Icons.check, fg: Colors.white, bg: AsmTheme.statusApproved, label: 'Completed'),
        StageState.current => (icon: Icons.more_horiz, fg: Colors.white, bg: AsmTheme.primaryNavy, label: 'Current'),
        StageState.pending => (icon: Icons.schedule, fg: AsmTheme.textMuted, bg: AsmTheme.surfaceMuted, label: 'Pending'),
        StageState.rejected => (icon: Icons.close, fg: Colors.white, bg: AsmTheme.statusRejected, label: 'Rejected'),
        StageState.correction => (icon: Icons.edit_outlined, fg: Colors.white, bg: AsmTheme.statusPending, label: 'Correction required'),
        StageState.cancelled => (icon: Icons.block, fg: Colors.white, bg: AsmTheme.textMuted, label: 'Cancelled'),
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < stages.length; i++)
          Semantics(
            label: '${stages[i].label}: ${_style(stages[i].state).label}',
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    children: [
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: _style(stages[i].state).bg,
                        child: Icon(_style(stages[i].state).icon, size: 13, color: _style(stages[i].state).fg),
                      ),
                      if (i < stages.length - 1)
                        Expanded(child: Container(width: 2, color: AsmTheme.borderLight)),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14, top: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            stages[i].label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: stages[i].state == StageState.pending ? FontWeight.w500 : FontWeight.w700,
                              color: stages[i].state == StageState.pending ? AsmTheme.textMuted : AsmTheme.textHeading,
                            ),
                          ),
                          Text(
                            stages[i].note ?? _style(stages[i].state).label,
                            style: const TextStyle(fontSize: 11, color: AsmTheme.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
