import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../app/theme/asm_theme.dart';
import '../../core/auth/auth_notifier.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../shared/models/cash_advance.dart';
import '../../shared/models/expense.dart';
import '../../shared/models/expense_claim.dart';
import '../../shared/widgets/async_states.dart';
import '../../shared/widgets/notification_center.dart';
import '../../shared/widgets/spend_summary_chart.dart';
import '../../shared/widgets/status_badge.dart';
import '../../shared/workflow/approval_queue.dart';
import '../../shared/workflow/dashboard_metrics.dart';

/// Dashboard built only from the signed-in user's real records and, for
/// approvers / Finance, their real work queues.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final NotificationCounter _notifications = NotificationCounter();
  String _selectedPeriod = 'Last 6 Months';
  List<ExpenseClaim> _claims = [];
  List<CashAdvance> _advances = [];
  List<Expense> _expenses = [];
  DashboardMetrics? _metrics;
  ApprovalQueue? _queue;
  int? _financePendingReimbursements;
  int? _financeAdvancesToDisburse;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _notifications.refresh();
  }

  @override
  void dispose() {
    _notifications.dispose();
    super.dispose();
  }

  int get _monthsForPeriod {
    switch (_selectedPeriod) {
      case 'This Month':
        return 1;
      case 'This Fiscal Year':
        return 12;
      case 'All Time':
        return 24;
      case 'Last 6 Months':
      default:
        return 6;
    }
  }

  void _onPeriodChanged(String period) {
    if (_selectedPeriod == period) return;
    setState(() {
      _selectedPeriod = period;
      _metrics = DashboardMetrics.from(_claims, _advances, DateTime.now(), months: _monthsForPeriod);
    });
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final service = SupabaseService();
      final auth = AuthNotifier().state;
      final claims = auth.isManager ? await service.getVisibleClaims() : await service.getMyClaims();
      final advances = auth.isManager ? await service.getVisibleAdvances() : await service.getMyAdvances();
      final expenses = await service.getMyExpenses();
      ApprovalQueue? queue;
      if (auth.isManager) queue = await loadApprovalQueue();
      int? pendingReimb;
      int? toDisburse;
      if (auth.isFinance) {
        pendingReimb = (await service.client.from('reimbursements').select('id').eq('status', 'PENDING') as List).length;
        toDisburse = (await service.client.from('cash_advances').select('id').eq('status', 'APPROVED') as List).length;
      }
      if (!mounted) return;
      setState(() {
        _claims = claims;
        _advances = advances;
        _expenses = expenses;
        _metrics = DashboardMetrics.from(claims, advances, DateTime.now(), months: _monthsForPeriod);
        _queue = queue;
        _financePendingReimbursements = pendingReimb;
        _financeAdvancesToDisburse = toDisburse;
        _isLoading = false;
      });
      _notifications.refresh();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Your dashboard could not be loaded. Check your connection and try again.';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rawName = AuthNotifier().currentEmployee?.fullName;
    final name = rawName != null && rawName.isNotEmpty
        ? rawName.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim()
        : null;
    return Scaffold(
      backgroundColor: AsmTheme.surfaceBackground,
      appBar: AppBar(
        title: Text(name != null ? 'Welcome, $name' : 'Dashboard', overflow: TextOverflow.ellipsis),
        actions: [
          NotificationBell(counter: _notifications, color: Colors.white),
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _isLoading ? null : _load),
        ],
      ),
      body: StateSwitcher(
        child: _isLoading
            ? const SkeletonList(key: ValueKey('loading'), rows: 4, rowHeight: 96)
            : _error != null
                ? StateMessage.error(key: const ValueKey('error'), message: _error!, onAction: _load)
                : RefreshIndicator(key: const ValueKey('content'), onRefresh: _load, child: _content(context)),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final m = _metrics!;
    final queueCard = (_queue != null && (_queue!.claims.isNotEmpty || _queue!.advances.isNotEmpty))
        ? Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Color(0xFFCBD5E1)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF3C7),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Icon(Icons.pending_actions_outlined, size: 20, color: Color(0xFFD97706)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'AWAITING YOUR APPROVAL',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.8,
                                      color: AsmTheme.primaryNavy,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${_queue!.claims.length + _queue!.advances.length} ${(_queue!.claims.length + _queue!.advances.length) == 1 ? 'request' : 'requests'} requiring your review',
                                    style: const TextStyle(fontSize: 12, color: AsmTheme.textSecondary),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () => _go('/approvals'),
                        icon: const Icon(Icons.arrow_forward, size: 16),
                        label: const Text('View All Queue'),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  for (final item in [..._queue!.claims, ..._queue!.advances].take(3))
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      item.number,
                                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AsmTheme.primaryNavy),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AsmTheme.primaryNavy.withValues(alpha: 0.08),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(maxWidth: 180),
                                        child: Text(
                                          item.employeeName.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim(),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AsmTheme.primaryNavy),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  item.purpose,
                                  style: const TextStyle(fontSize: 12, color: AsmTheme.textSecondary),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),
                          SizedBox(
                            width: 100,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    MoneyUtils.format(item.amountMinor, currency: item.currency),
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AsmTheme.primaryNavy),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                    visualDensity: VisualDensity.compact,
                                    minimumSize: const Size(0, 30),
                                  ),
                                  onPressed: () => _go(item.isAdvance ? '/advances/${item.id}' : '/claims/${item.id}'),
                                  child: const Text('Review', style: TextStyle(fontSize: 11)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          )
        : null;

    final cards = <Widget>[
      ?queueCard,
      if ((_financePendingReimbursements ?? 0) > 0 || (_financeAdvancesToDisburse ?? 0) > 0)
        _ActionBanner(
          icon: Icons.payments_outlined,
          text: 'Finance: $_financePendingReimbursements reimbursements awaiting payment, '
              '$_financeAdvancesToDisburse cash advances awaiting disbursement',
          action: 'Open settlement',
          onTap: () => _go('/finance/reimbursements'),
        ),
      if (m.correctionCount > 0)
        _ActionBanner(
          icon: Icons.edit_note,
          color: AsmTheme.statusWarning,
          text: '${m.correctionCount} ${m.correctionCount == 1 ? 'claim needs' : 'claims need'} your correction',
          action: 'View claims',
          onTap: () => _go('/claims'),
        ),
    ];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ...cards.map((c) => Padding(padding: const EdgeInsets.only(bottom: 12), child: c)),
        // 1. Benchmark Hero: SPEND SUMMARY (Spline Area Chart) & OVERALL SUMMARY Cards
        LayoutBuilder(
          builder: (context, c) {
            final isDesktop = c.maxWidth >= 900;
            final isManager = AuthNotifier().isManager;
            final totalExpMinor = isManager
                ? _claims.fold<int>(0, (s, c) => s + c.totalExpenseMinor)
                : _claims.fold<int>(0, (s, c) => s + c.totalExpenseMinor) +
                    _expenses.where((e) => !e.isLocked).fold<int>(0, (s, e) => s + e.aedAmountMinor);

            final spendSummary = SpendSummaryCard(
              data: m.monthly,
              title: isManager ? 'TEAM SPEND SUMMARY' : 'SPEND SUMMARY',
              fiscalYear: isManager
                  ? 'TEAM SPEND SUMMARY: ${DateTime.now().year - 1} - ${DateTime.now().year}'
                  : 'FISCAL YEAR: ${DateTime.now().year - 1} - ${DateTime.now().year}',
              periodLabel: _selectedPeriod,
              onPeriodChanged: _onPeriodChanged,
            );

            final overallSummary = OverallSummaryCard(
              totalExpensesMinor: totalExpMinor,
              advancesMinor: m.openAdvanceBalanceMinor,
              reimbursementsMinor: m.paidMinor,
              totalClaimsCount: _claims.length,
              periodLabel: _selectedPeriod,
              onTapExpenses: () => _go('/expenses'),
              onTapAdvances: () => _go('/advances'),
              onTapReimbursements: () => _go('/claims'),
              onTapClaims: () => _go('/claims'),
            );

            if (isDesktop) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 62, child: spendSummary),
                  const SizedBox(width: 16),
                  Expanded(flex: 38, child: overallSummary),
                ],
              );
            } else {
              return Column(
                children: [
                  spendSummary,
                  const SizedBox(height: 16),
                  overallSummary,
                ],
              );
            }
          },
        ),
        const SizedBox(height: 16),

        // 2. Claim Workflow Pipeline KPIs
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth >= 900 ? 4 : (c.maxWidth >= 520 ? 2 : 1);
          final tiles = [
            _Kpi(label: 'In approval', value: MoneyUtils.format(m.inReviewMinor), detail: '${m.inReviewCount} claims under review'),
            _Kpi(label: 'Approved, awaiting payment', value: MoneyUtils.format(m.awaitingPaymentMinor), detail: '${m.awaitingPaymentCount} claims'),
            _Kpi(label: 'Reimbursed', value: MoneyUtils.format(m.paidMinor), detail: '${m.paidCount} claims paid'),
            _Kpi(
              label: 'Open cash advances',
              value: MoneyUtils.format(m.openAdvanceBalanceMinor),
              detail: '${m.openAdvanceCount} with unreconciled balance',
              onTap: () => _go('/advances'),
            ),
          ];
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var i = 0; i < tiles.length; i++)
                SizedBox(width: (c.maxWidth - 12 * (cols - 1)) / cols, child: FadeSlideIn(index: i, child: tiles[i])),
            ],
          );
        }),
        const SizedBox(height: 16),
        if (AuthNotifier().isManager) ...[
          _Section(
            title: 'Team claims & submissions',
            subtitle: 'Real-time expense claims submitted by your team members',
            trailing: TextButton(onPressed: () => _go('/approvals?tab=history'), child: const Text('View all')),
            child: _claims.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Column(children: [
                      const Text('No team claims submitted yet.', style: TextStyle(color: AsmTheme.textSecondary)),
                      const SizedBox(height: 10),
                      OutlinedButton(onPressed: () => _go('/approvals'), child: const Text('Go to Approvals')),
                    ]),
                  )
                : Column(
                    children: [
                      for (final (index, claim) in _claims.take(5).indexed) ...[
                        if (index > 0) const Divider(height: 1, thickness: 0.8, color: Color(0xFFF1F5F9)),
                        _DashboardClaimTile(
                          claim: claim,
                          onTap: () => _go('/claims/${claim.id}'),
                          showEmployee: true,
                        ),
                      ],
                    ],
                  ),
          ),
          if (_expenses.isNotEmpty) ...[
            const SizedBox(height: 16),
            _Section(
              title: 'My personal recorded expenses',
              subtitle: 'Out-of-pocket receipts and expenses ready to be claimed',
              trailing: TextButton(onPressed: () => _go('/expenses'), child: const Text('View all')),
              child: Column(
                children: [
                  for (final (index, exp) in _expenses.take(4).indexed) ...[
                    if (index > 0) const Divider(height: 1, thickness: 0.8, color: Color(0xFFF1F5F9)),
                    _DashboardExpenseTile(
                      exp: exp,
                      onTap: () => _go('/expenses'),
                    ),
                  ],
                  if (_expenses.any((e) => !e.isLocked)) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.add_box_outlined, size: 16),
                        label: const Text('Create claim with these expenses'),
                        onPressed: () => _go('/claims/new'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ] else ...[
          _Section(
            title: 'Recorded expenses',
            subtitle: 'Scanned receipts and recorded expenses ready to be claimed',
            trailing: TextButton(onPressed: () => _go('/expenses'), child: const Text('View all')),
            child: _expenses.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Column(children: [
                      const Text('No recorded expenses yet.', style: TextStyle(color: AsmTheme.textSecondary)),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.document_scanner_outlined, size: 16),
                        label: const Text('Scan receipt'),
                        onPressed: () => _go('/receipts/scan'),
                      ),
                    ]),
                  )
                : Column(
                    children: [
                      for (final (index, exp) in _expenses.take(4).indexed) ...[
                        if (index > 0) const Divider(height: 1, thickness: 0.8, color: Color(0xFFF1F5F9)),
                        _DashboardExpenseTile(
                          exp: exp,
                          onTap: () => _go('/expenses'),
                        ),
                      ],
                      if (_expenses.any((e) => !e.isLocked)) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.add_box_outlined, size: 16),
                            label: const Text('Create claim with these expenses'),
                            onPressed: () => _go('/claims/new'),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Recent claims',
            trailing: TextButton(onPressed: () => _go('/claims'), child: const Text('View all')),
            child: _claims.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Column(children: [
                      const Text('You have not created any claims yet.', style: TextStyle(color: AsmTheme.textSecondary)),
                      const SizedBox(height: 10),
                      OutlinedButton(onPressed: () => _go('/claims/new'), child: const Text('Create a claim')),
                    ]),
                  )
                : Column(
                    children: [
                      for (final (index, claim) in _claims.take(5).indexed) ...[
                        if (index > 0) const Divider(height: 1, thickness: 0.8, color: Color(0xFFF1F5F9)),
                        _DashboardClaimTile(
                          claim: claim,
                          onTap: () => _go('/claims/${claim.id}'),
                          showEmployee: false,
                        ),
                      ],
                    ],
                  ),
          ),
        ],
        const SizedBox(height: 16),
        _Section(
          title: 'Quick actions',
          subtitle: 'Create expenses, submit claims, or request travel funds',
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth >= 640 ? 4 : 2;
              const spacing = 10.0;
              final width = (constraints.maxWidth - spacing * (cols - 1)) / cols;

              final actions = [
                _QuickActionTile(
                  icon: Icons.document_scanner_rounded,
                  title: 'Scan Receipt',
                  subtitle: 'Auto-extract with AI',
                  iconColor: const Color(0xFF0284C7),
                  iconBg: const Color(0xFFE0F2FE),
                  onTap: () => _go('/receipts/scan'),
                ),
                _QuickActionTile(
                  icon: Icons.edit_note_rounded,
                  title: 'Manual Expense',
                  subtitle: 'Record without bill',
                  iconColor: const Color(0xFF0D9488),
                  iconBg: const Color(0xFFCCFBF1),
                  onTap: () => _go('/expenses/new'),
                ),
                _QuickActionTile(
                  icon: Icons.post_add_rounded,
                  title: 'Create Claim',
                  subtitle: 'Submit for review',
                  iconColor: AsmTheme.primaryNavy,
                  iconBg: const Color(0xFFE2E8F0),
                  onTap: () => _go('/claims/new'),
                ),
                _QuickActionTile(
                  icon: Icons.account_balance_wallet_rounded,
                  title: 'Cash Advance',
                  subtitle: 'Request travel funds',
                  iconColor: const Color(0xFF7C3AED),
                  iconBg: const Color(0xFFF3E8FF),
                  onTap: () => _go('/advances/new'),
                ),
              ];

              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final a in actions)
                    SizedBox(width: width, child: a),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _go(String route) async {
    await context.push(route);
    if (mounted) _load();
  }
}

class _Kpi extends StatelessWidget {
  final String label;
  final String value;
  final String detail;
  final VoidCallback? onTap;

  const _Kpi({required this.label, required this.value, required this.detail, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 12, color: AsmTheme.textSecondary, fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AsmTheme.textHeading)),
            ),
            const SizedBox(height: 2),
            Text(detail, style: const TextStyle(fontSize: 11, color: AsmTheme.textMuted)),
          ]),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  const _Section({required this.title, required this.child, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AsmTheme.textHeading))),
            ?trailing,
          ]),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: const TextStyle(fontSize: 11, color: AsmTheme.textMuted)),
          ],
          const SizedBox(height: 12),
          child,
        ]),
      ),
    );
  }
}

class _ActionBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onTap;
  final Color color;

  const _ActionBanner({required this.icon, required this.text, required this.action, required this.onTap, this.color = AsmTheme.primaryNavy});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: color.withValues(alpha: 0.25))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: AsmTheme.textHeading, fontWeight: FontWeight.w500))),
          TextButton(onPressed: onTap, child: Text(action)),
        ]),
      ),
    );
  }
}

class _QuickActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color iconColor;
  final Color iconBg;
  final VoidCallback onTap;

  const _QuickActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.iconColor,
    required this.iconBg,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashColor: iconBg.withValues(alpha: 0.5),
        highlightColor: iconBg.withValues(alpha: 0.25),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: iconBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Center(
                      child: Icon(icon, size: 20, color: iconColor),
                    ),
                  ),
                  const Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 12,
                    color: Color(0xFF94A3B8),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AsmTheme.textHeading,
                  letterSpacing: -0.1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: AsmTheme.textMuted,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardClaimTile extends StatelessWidget {
  final ExpenseClaim claim;
  final VoidCallback onTap;
  final bool showEmployee;

  const _DashboardClaimTile({
    required this.claim,
    required this.onTap,
    this.showEmployee = true,
  });

  @override
  Widget build(BuildContext context) {
    final rawName = claim.employeeName;
    final displayName = rawName != null && rawName.isNotEmpty
        ? rawName.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim()
        : null;

    final dateStr = claim.claimDate.toIso8601String().split('T')[0];

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      hoverColor: AsmTheme.primaryNavy.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    claim.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: AsmTheme.textHeading,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (showEmployee && displayName != null && displayName.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFFE2E8F0), width: 0.8),
                          ),
                          child: Text(
                            displayName,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: AsmTheme.primaryNavy,
                            ),
                          ),
                        ),
                      Text(
                        '#${claim.claimNumber}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AsmTheme.textMuted,
                        ),
                      ),
                      const Text(
                        '•',
                        style: TextStyle(fontSize: 10, color: AsmTheme.textMuted),
                      ),
                      Text(
                        dateStr,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AsmTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  MoneyUtils.format(claim.totalExpenseMinor),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AsmTheme.textHeading,
                  ),
                ),
                const SizedBox(height: 4),
                StatusBadge(status: claim.status.displayName),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardExpenseTile extends StatelessWidget {
  final Expense exp;
  final VoidCallback onTap;

  const _DashboardExpenseTile({required this.exp, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final dateStr = exp.expenseDate.toIso8601String().split('T')[0];

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      hoverColor: AsmTheme.primaryNavy.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AsmTheme.brandBlue.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Icon(
                  exp.hasReceipt ? Icons.receipt_long_outlined : Icons.edit_note_rounded,
                  size: 17,
                  color: AsmTheme.brandBlue,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    exp.vendor,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: AsmTheme.textHeading,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$dateStr  •  ${exp.categoryName ?? 'General'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AsmTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  MoneyUtils.format(exp.amountMinor, currency: exp.currencyCode),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AsmTheme.textHeading,
                  ),
                ),
                const SizedBox(height: 3),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: exp.isLocked ? const Color(0xFFF1F5F9) : const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: exp.isLocked ? const Color(0xFFE2E8F0) : const Color(0xFFA7F3D0),
                      width: 0.7,
                    ),
                  ),
                  child: Text(
                    exp.isLocked ? 'In claim' : 'Ready to claim',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: exp.isLocked ? AsmTheme.textMuted : const Color(0xFF059669),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}