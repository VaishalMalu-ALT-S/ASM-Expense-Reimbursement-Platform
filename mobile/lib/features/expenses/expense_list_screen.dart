import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../app/theme/asm_theme.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../shared/models/expense.dart';
import '../../shared/widgets/async_states.dart';
import '../../shared/widgets/status_badge.dart';

/// The employee's recorded expenses with edit / delete for those that are
/// not yet part of a submitted claim.
class ExpenseListScreen extends StatefulWidget {
  const ExpenseListScreen({super.key});

  @override
  State<ExpenseListScreen> createState() => _ExpenseListScreenState();
}

enum _Filter { all, available, inClaim }

class _ExpenseListScreenState extends State<ExpenseListScreen> {
  List<Expense>? _expenses;
  List<ExpenseClaimLink> _links = const [];
  String? _error;
  String _query = '';
  _Filter _filter = _Filter.all;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final svc = SupabaseService();
      final expenses = await svc.getMyExpenses();
      final links = await svc.getExpenseClaimLinks(expenses.map((e) => e.id).toList());
      if (mounted) {
        setState(() {
          _expenses = expenses;
          _links = links;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Your expenses could not be loaded. Check your connection and try again.');
    }
  }

  Future<void> _edit(Expense e) async {
    final changed = await context.push<bool>('/expenses/${e.id}/edit');
    if (changed == true) _load();
  }

  Future<void> _delete(Expense e) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete expense?'),
        content: Text('${e.vendor} - ${MoneyUtils.format(e.amountMinor, currency: e.currencyCode)} on '
            '${_date(e.expenseDate)} will be permanently removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AsmTheme.statusRejected),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy.add(e.id));
    try {
      final r = await SupabaseService().deleteExpense(e.id);
      if (!mounted) return;
      final ok = r['success'] == true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r['message'] as String? ?? (ok ? 'Expense deleted.' : 'Expense could not be deleted.')),
        backgroundColor: ok ? AsmTheme.statusApproved : AsmTheme.statusRejected,
      ));
      if (ok) await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not reach the server. The expense was not deleted.'),
          backgroundColor: AsmTheme.statusRejected,
        ));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(e.id));
    }
  }

  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  List<Expense> _visible() {
    final q = _query.trim().toLowerCase();
    return (_expenses ?? const <Expense>[]).where((e) {
      final m = ExpenseMaintenance.of(e, _links);
      final inClaim = m.activeClaim != null || e.isLocked;
      if (_filter == _Filter.available && inClaim) return false;
      if (_filter == _Filter.inClaim && !inClaim) return false;
      if (q.isEmpty) return true;
      return e.vendor.toLowerCase().contains(q) ||
          e.description.toLowerCase().contains(q) ||
          (e.categoryName ?? '').toLowerCase().contains(q) ||
          (e.invoiceNumber ?? '').toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_error != null) {
      body = StateMessage.error(message: _error!, onAction: _load);
    } else if (_expenses == null) {
      body = const SkeletonList(rows: 6);
    } else if (_expenses!.isEmpty) {
      body = StateMessage(
        icon: Icons.receipt_long_outlined,
        title: 'No expenses recorded',
        message: 'Scan a receipt or record an expense without a receipt to get started.',
        actionLabel: 'Scan receipt',
        onAction: () => context.push('/receipts/scan').then((_) => _load()),
      );
    } else {
      final items = _visible();
      body = RefreshIndicator(
        onRefresh: _load,
        child: items.isEmpty
            ? ListView(children: const [
                SizedBox(height: 80),
                StateMessage(icon: Icons.search_off, title: 'No matching expenses', message: 'Change the search or filter.'),
              ])
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => FadeSlideIn(index: i, child: _tile(items[i])),
              ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('My Expenses')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/receipts/scan').then((_) => _load()),
        icon: const Icon(Icons.document_scanner_outlined),
        label: const Text('Scan receipt'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search vendor, category, purpose or invoice',
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
            for (final f in _Filter.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(switch (f) {
                    _Filter.all => 'All',
                    _Filter.available => 'Not in a claim',
                    _Filter.inClaim => 'In a claim',
                  }),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
              ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => context.push('/expenses/new').then((_) => _load()),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Without receipt'),
            ),
          ]),
        ),
        Expanded(child: StateSwitcher(child: KeyedSubtree(key: ValueKey('${_expenses == null}$_error'), child: body))),
      ]),
    );
  }

  Widget _tile(Expense e) {
    final m = ExpenseMaintenance.of(e, _links);
    final busy = _busy.contains(e.id);
    final claim = m.activeClaim;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(e.hasReceipt ? Icons.receipt_long_outlined : Icons.do_not_disturb_alt_outlined,
              color: AsmTheme.textMuted, semanticLabel: e.hasReceipt ? 'Receipt attached' : 'No receipt'),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.vendor, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 2),
              Text('${_date(e.expenseDate)}  |  ${e.categoryName ?? 'Uncategorised'}',
                  style: const TextStyle(fontSize: 12, color: AsmTheme.textSecondary)),
              if (e.description.isNotEmpty)
                Text(e.description, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AsmTheme.textSecondary)),
              const SizedBox(height: 6),
              if (claim != null)
                Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('Claim #${claim.claimNumber ?? ''}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  if (claim.claimStatus != null) StatusBadge(status: claim.claimStatus!),
                ])
              else if (e.isLocked)
                const Text('Locked in a submitted claim', style: TextStyle(fontSize: 12, color: AsmTheme.textMuted))
              else
                const Text('Not in a claim', style: TextStyle(fontSize: 12, color: AsmTheme.statusApproved)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(MoneyUtils.format(e.amountMinor, currency: e.currencyCode),
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            if (e.currencyCode != 'AED')
              Text(MoneyUtils.format(e.aedAmountMinor),
                  style: const TextStyle(fontSize: 11, color: AsmTheme.textSecondary)),
            busy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : PopupMenuButton<String>(
                    tooltip: 'Expense actions',
                    onSelected: (v) => v == 'edit' ? _edit(e) : _delete(e),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        enabled: m.canEdit,
                        child: ListTile(
                          leading: const Icon(Icons.edit_outlined),
                          title: const Text('Edit'),
                          subtitle: m.canEdit ? null : const Text('Part of a submitted claim'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        enabled: m.canDelete,
                        child: ListTile(
                          leading: const Icon(Icons.delete_outline),
                          title: const Text('Delete'),
                          subtitle: m.canDelete ? null : const Text('Kept for claim history'),
                        ),
                      ),
                    ],
                  ),
          ]),
        ]),
      ),
    );
  }
}
