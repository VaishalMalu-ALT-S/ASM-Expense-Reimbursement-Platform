import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../shared/models/expense_claim.dart';
import '../../shared/widgets/async_states.dart';
import '../../shared/widgets/status_badge.dart';
import '../../app/theme/asm_theme.dart';

/// The signed-in employee's claims with search and status filtering.
class ClaimListScreen extends StatefulWidget {
  const ClaimListScreen({super.key});

  @override
  State<ClaimListScreen> createState() => _ClaimListScreenState();
}

enum _Filter { all, inApproval, needsCorrection, awaitingPayment, completed, closed }

class _ClaimListScreenState extends State<ClaimListScreen> {
  static const _filterLabels = {
    _Filter.all: 'All',
    _Filter.inApproval: 'In approval',
    _Filter.needsCorrection: 'Needs correction',
    _Filter.awaitingPayment: 'Awaiting payment',
    _Filter.completed: 'Paid / settled',
    _Filter.closed: 'Rejected / cancelled',
  };
  static const _statusesFor = {
    _Filter.inApproval: {ClaimStatus.submitted, ClaimStatus.lineManagerReview, ClaimStatus.hodReview, ClaimStatus.sivaReview, ClaimStatus.financeReview},
    _Filter.needsCorrection: {ClaimStatus.correctionRequired},
    _Filter.awaitingPayment: {ClaimStatus.approved, ClaimStatus.reimbursementProcessing},
    _Filter.completed: {ClaimStatus.paid, ClaimStatus.settled},
    _Filter.closed: {ClaimStatus.rejected, ClaimStatus.cancelled},
  };

  static const _pageSize = 50;

  List<ExpenseClaim> _claims = [];
  bool _isLoading = true;
  bool _hasMore = false;
  bool _loadingMore = false;
  String? _error;
  String _query = '';
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _loadClaims();
  }

  Future<void> _loadClaims() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final claims = await SupabaseService().getMyClaimsPage(offset: 0, limit: _pageSize);
      if (mounted) {
        setState(() {
          _claims = claims;
          _hasMore = claims.length == _pageSize;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() { _error = 'Your claims could not be loaded. Check your connection and try again.'; _isLoading = false; });
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final page = await SupabaseService().getMyClaimsPage(offset: _claims.length, limit: _pageSize);
      if (mounted) {
        setState(() {
          final known = _claims.map((c) => c.id).toSet();
          _claims = [..._claims, ...page.where((c) => !known.contains(c.id))];
          _hasMore = page.length == _pageSize;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('More claims could not be loaded. Check your connection and try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  List<ExpenseClaim> get _visible {
    final q = _query.trim().toLowerCase();
    final allowed = _statusesFor[_filter];
    return _claims.where((c) {
      if (allowed != null && !allowed.contains(c.status)) return false;
      if (q.isEmpty) return true;
      return c.title.toLowerCase().contains(q) || c.claimNumber.toLowerCase().contains(q);
    }).toList();
  }

  Widget _body() {
    if (_isLoading) return const SkeletonList(key: ValueKey('loading'));
    if (_error != null) return StateMessage.error(key: const ValueKey('error'), message: _error!, onAction: _loadClaims);
    if (_claims.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.receipt_long, size: 48, color: AsmTheme.textMuted),
              const SizedBox(height: 12),
              const Text('No claims submitted yet', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 6),
              const Text(
                'Scanned receipts are saved under My Expenses. You can view your recorded expenses or bundle them into a new claim for reimbursement.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AsmTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.receipt_long_outlined, size: 16),
                    label: const Text('View My Expenses'),
                    onPressed: () => context.go('/expenses'),
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Create Claim'),
                    onPressed: _newClaim,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final visible = _visible;
    return RefreshIndicator(
      key: const ValueKey('content'),
      onRefresh: _loadClaims,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search by title or claim number'),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final f in _Filter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_filterLabels[f]!),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text('No claims match this search or filter.', style: TextStyle(color: AsmTheme.textSecondary))),
            )
          else
            for (var i = 0; i < visible.length; i++) FadeSlideIn(index: i, child: _tile(visible[i])),
          if (_hasMore) ...[
            const SizedBox(height: 4),
            Center(
              child: OutlinedButton.icon(
                onPressed: _loadingMore ? null : _loadMore,
                icon: _loadingMore
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.expand_more, size: 18),
                label: Text(_loadingMore ? 'Loading' : 'Load older claims'),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Search and filters apply to the claims loaded so far.',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: AsmTheme.textMuted)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tile(ExpenseClaim claim) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          await context.push('/claims/${claim.id}');
          if (mounted) _loadClaims();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(claim.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AsmTheme.textPrimary)),
                const SizedBox(height: 4),
                Text('#${claim.claimNumber}  |  ${claim.claimDate.toIso8601String().split('T')[0]}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted, fontWeight: FontWeight.w500)),
              ]),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(MoneyUtils.format(claim.totalExpenseMinor),
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AsmTheme.textPrimary)),
                ),
                const SizedBox(height: 5),
                StatusBadge(status: claim.status.displayName),
              ]),
            ),
            const Icon(Icons.chevron_right, color: AsmTheme.textMuted, size: 20),
          ]),
        ),
      ),
    );
  }

  Future<void> _newClaim() async {
    await context.push('/claims/new');
    if (mounted) _loadClaims();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AsmTheme.bgCanvas,
      appBar: AppBar(
        title: const Text('My Expense Claims'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.receipt_long_outlined, size: 16),
            label: const Text('My Expenses'),
            onPressed: () => context.go('/expenses'),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _isLoading ? null : _loadClaims, tooltip: 'Refresh'),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add, size: 18),
        label: const Text('New Claim'),
        onPressed: _newClaim,
      ),
      body: StateSwitcher(child: _body()),
    );
  }
}
