import 'package:flutter/material.dart';
import '../../shared/widgets/async_states.dart';
import 'package:go_router/go_router.dart';
import '../../app/theme/asm_theme.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../shared/models/cash_advance.dart';
import '../../shared/workflow/approval_stages.dart';

/// Employee view of their own cash advances and where each one stands.
class AdvanceListScreen extends StatefulWidget {
  const AdvanceListScreen({super.key});

  @override
  State<AdvanceListScreen> createState() => _AdvanceListScreenState();
}

class _AdvanceListScreenState extends State<AdvanceListScreen> {
  List<CashAdvance> _advances = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final list = await SupabaseService().getMyAdvances();
      if (mounted) setState(() { _advances = list; _isLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Could not load your cash advances. Check your connection and try again.'; _isLoading = false; });
    }
  }

  String _stageText(CashAdvance a) {
    if (a.status == CashAdvanceStatus.underReview || a.status == CashAdvanceStatus.submitted) {
      return 'Awaiting ${reviewStageLabels[a.currentApprovalStage] ?? 'review'}';
    }
    return switch (a.status) {
      CashAdvanceStatus.approved => 'Approved - awaiting disbursement',
      CashAdvanceStatus.paid => 'Paid - balance ${MoneyUtils.format(a.remainingBalanceMinor)}',
      CashAdvanceStatus.partiallySettled => 'Partially settled - balance ${MoneyUtils.format(a.remainingBalanceMinor)}',
      _ => a.status.displayName,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Cash Advances'),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await context.push('/advances/new');
              if (mounted) _load();
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Request'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const SkeletonList()
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AsmTheme.textSecondary)),
                    const SizedBox(height: 12),
                    OutlinedButton(onPressed: _load, child: const Text('Retry')),
                  ]),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _advances.isEmpty
                      ? ListView(children: const [
                          SizedBox(height: 120),
                          Center(child: Text('You have no cash advance requests.', style: TextStyle(color: AsmTheme.textSecondary))),
                        ])
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _advances.length,
                          itemBuilder: (context, i) {
                            final a = _advances[i];
                            return Card(
                              child: ListTile(
                                onTap: () async {
                                  await context.push('/advances/${a.id}');
                                  if (mounted) _load();
                                },
                                title: Text('${a.advanceNumber}  ${a.purpose}', maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                                subtitle: Text(_stageText(a), style: const TextStyle(fontSize: 12)),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(MoneyUtils.format(a.amountMinor, currency: a.currencyCode),
                                        style: const TextStyle(fontWeight: FontWeight.w700)),
                                    Text(a.status.displayName, style: const TextStyle(fontSize: 11, color: AsmTheme.textMuted)),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
    );
  }
}
