import 'package:flutter/material.dart';
import '../../shared/widgets/async_states.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../app/theme/asm_theme.dart';

class FinanceReimbursementScreen extends StatefulWidget {
  const FinanceReimbursementScreen({super.key});

  @override
  State<FinanceReimbursementScreen> createState() => _FinanceReimbursementScreenState();
}

class _FinanceReimbursementScreenState extends State<FinanceReimbursementScreen> {
  List<Map<String, dynamic>> _reimbursements = [];
  bool _isLoading = true;
  String? _loadError;
  String? _payingId;

  @override
  void initState() {
    super.initState();
    _loadReimbursements();
  }

  Future<void> _loadReimbursements() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      // 1. First attempt to load direct reimbursements
      final res = await SupabaseService().client
          .from('reimbursements')
          .select('id, claim_id, employee_id, amount_minor, status, created_at, employees:employee_id(full_name, employee_code), expense_claims(id, claim_number, title, status)')
          .order('created_at', ascending: false);

      List<Map<String, dynamic>> items = List<Map<String, dynamic>>.from(res as List);

      // 2. If reimbursements table is empty (e.g. pending DB policy migration),
      // query expense_claims directly for all approved or paid claims so Finance sees the real live data!
      if (items.isEmpty) {
        final claimsRes = await SupabaseService().client
            .from('expense_claims')
            .select('id, claim_number, title, status, net_reimbursement_minor, total_expense_minor, employee_id, created_at, employees:employee_id(full_name, employee_code)')
            .inFilter('status', ['APPROVED', 'REIMBURSEMENT_PROCESSING', 'PAID'])
            .order('created_at', ascending: false);

        items = (claimsRes as List).map<Map<String, dynamic>>((c) {
          final isClaimPaid = c['status'] == 'PAID';
          return {
            'id': c['id'],
            'claim_id': c['id'],
            'amount_minor': c['net_reimbursement_minor'] ?? c['total_expense_minor'] ?? 0,
            'status': isClaimPaid ? 'PAID' : 'PENDING',
            'is_fallback_claim': true,
            'employees': c['employees'],
            'expense_claims': {
              'claim_number': c['claim_number'],
              'title': c['title'],
            },
          };
        }).toList();
      }

      if (mounted) {
        setState(() {
          _reimbursements = items;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = 'Could not load the reimbursement queue: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _recordPayment(Map<String, dynamic> item, int amountMinor) async {
    final refController = TextEditingController();
    final reimbursementId = item['id'] as String;
    // One key per payment attempt: a retry after a lost response is not paid twice.
    final idempotencyKey = const Uuid().v4();

    final reference = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Record Bank Settlement Payment'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Amount: ${MoneyUtils.format(amountMinor)} (approved claim amount)',
                    style: const TextStyle(fontSize: 13, color: AsmTheme.textSecondary)),
                const SizedBox(height: 12),
                const Text('Bank Payment Reference *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 6),
                TextField(
                  controller: refController,
                  decoration: InputDecoration(hintText: 'Reference from the bank transfer', errorText: error),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  final ref = refController.text.trim();
                  if (ref.isEmpty) {
                    setDialogState(() => error = 'Enter the bank payment reference');
                    return;
                  }
                  Navigator.pop(ctx, ref);
                },
                child: const Text('Confirm Settlement'),
              ),
            ],
          ),
        );
      },
    );
    refController.dispose();
    if (reference == null || !mounted) return;

    setState(() => _payingId = reimbursementId);
    try {
      String targetReimbId = reimbursementId;
      if (item['is_fallback_claim'] == true && item['claim_id'] != null) {
        final reimbLookup = await SupabaseService().client
            .from('reimbursements')
            .select('id')
            .eq('claim_id', item['claim_id'])
            .maybeSingle();
        if (reimbLookup != null && reimbLookup['id'] != null) {
          targetReimbId = reimbLookup['id'] as String;
        }
      }

      final res = await SupabaseService().client.rpc('record_reimbursement_payment', params: {
        'p_reimbursement_id': targetReimbId,
        'p_idempotency_key': idempotencyKey,
        'p_payment_reference': reference,
        'p_payment_method': 'BANK_TRANSFER',
      });
      final ok = res is Map && res['success'] == true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res is Map
                ? (res['message'] as String? ?? (ok ? 'Payment recorded.' : 'Payment could not be recorded.'))
                : 'Payment could not be recorded.'),
            backgroundColor: ok ? AsmTheme.statusApproved : AsmTheme.statusRejected,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Payment transaction error: $e'),
            backgroundColor: AsmTheme.statusRejected,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _payingId = null);
        _loadReimbursements();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Finance Settlement Portal'),
        bottom: const TabBar(tabs: [Tab(text: 'Claim Reimbursements'), Tab(text: 'Cash Advances')]),
      ),
      body: TabBarView(children: [
      _isLoading
          ? const SkeletonList()
          : _loadError != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_loadError!, textAlign: TextAlign.center, style: const TextStyle(color: AsmTheme.textSecondary)),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _loadReimbursements, child: const Text('Retry')),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadReimbursements,
              child: _reimbursements.isEmpty
                  ? const Center(child: Text('No reimbursements in queue.', style: TextStyle(color: AsmTheme.textSecondary)))
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _reimbursements.length,
                      itemBuilder: (context, idx) {
                        final r = _reimbursements[idx];
                        final emp = r['employees'] as Map<String, dynamic>?;
                        final claim = r['expense_claims'] as Map<String, dynamic>?;
                        final isPaid = r['status'] == 'PAID';
                        final claimId = (r['claim_id'] ?? r['id']) as String?;
                        final amountMinor = (r['amount_minor'] as num).toInt();

                        return Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: claimId == null
                                ? null
                                : () async {
                                    await context.push('/claims/$claimId');
                                    if (mounted) _loadReimbursements();
                                  },
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          (emp?['full_name'] as String? ?? 'Employee').replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim(),
                                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        MoneyUtils.format(amountMinor),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 16,
                                          color: isPaid ? AsmTheme.statusApproved : AsmTheme.primaryNavy,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          'Claim #${claim?['claim_number'] ?? ''} • ${claim?['title'] ?? ''}',
                                          style: const TextStyle(fontSize: 13, color: AsmTheme.textSecondary),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const Icon(Icons.chevron_right, size: 18, color: AsmTheme.textMuted),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: (isPaid ? AsmTheme.statusApproved : AsmTheme.statusPending).withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      isPaid ? 'PAID / SETTLED' : 'AWAITING DISBURSEMENT',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: isPaid ? AsmTheme.statusApproved : AsmTheme.statusPending,
                                      ),
                                    ),
                                  ),
                                  if (!isPaid) ...[
                                    const Divider(height: 20),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: ElevatedButton.icon(
                                        icon: _payingId == r['id']
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                                              )
                                            : const Icon(Icons.payment_outlined, size: 16),
                                        label: const Text('Record Payment'),
                                        onPressed: _payingId != null ? null : () => _recordPayment(r, amountMinor),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
        const _FinanceAdvancesTab(),
      ]),
      ),
    );
  }
}

/// Advances awaiting disbursement, or paid and awaiting reconciliation/refund.
class _FinanceAdvancesTab extends StatefulWidget {
  const _FinanceAdvancesTab();

  @override
  State<_FinanceAdvancesTab> createState() => _FinanceAdvancesTabState();
}

class _FinanceAdvancesTabState extends State<_FinanceAdvancesTab> {
  List<Map<String, dynamic>> _rows = [];
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
      final res = await SupabaseService().client
          .from('cash_advances')
          .select('id, advance_number, purpose, status, amount_minor, currency_code, aed_amount_minor, reconciled_amount_minor, returned_amount_minor, employees:employee_id(full_name)')
          .inFilter('status', ['APPROVED', 'PAID', 'PARTIALLY_SETTLED'])
          .order('updated_at', ascending: false);
      if (mounted) setState(() { _rows = List<Map<String, dynamic>>.from(res as List); _isLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Could not load cash advances. Check your connection and try again.'; _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const SkeletonList();
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AsmTheme.textSecondary)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _rows.isEmpty
          ? ListView(children: const [
              SizedBox(height: 120),
              Center(child: Text('No cash advances awaiting disbursement or settlement.', style: TextStyle(color: AsmTheme.textSecondary))),
            ])
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _rows.length,
              itemBuilder: (context, i) {
                final r = _rows[i];
                final aed = (r['aed_amount_minor'] as num).toInt();
                final open = aed - ((r['reconciled_amount_minor'] as num?)?.toInt() ?? 0) - ((r['returned_amount_minor'] as num?)?.toInt() ?? 0);
                final awaitingPayment = r['status'] == 'APPROVED';
                return Card(
                  child: ListTile(
                    onTap: () async {
                      await context.push('/advances/${r['id']}');
                      if (mounted) _load();
                    },
                    title: Text('${((r['employees'] as Map<String, dynamic>?)?['full_name'] as String? ?? 'Employee').replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim()}  |  ${r['advance_number']}',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    subtitle: Text(awaitingPayment ? 'Approved - awaiting disbursement' : 'Paid - unreconciled AED ${MoneyUtils.formatAmount(open)}',
                        style: const TextStyle(fontSize: 12)),
                    trailing: Text(MoneyUtils.format(aed), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                );
              },
            ),
    );
  }
}
