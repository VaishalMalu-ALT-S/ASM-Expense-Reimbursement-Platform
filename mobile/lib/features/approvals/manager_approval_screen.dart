import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/auth/auth_notifier.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../shared/widgets/async_states.dart';
import '../../shared/workflow/approval_queue.dart';
import '../../shared/workflow/approval_stages.dart';
import '../../app/theme/asm_theme.dart';

class AuditActionItem {
  final String id;
  final String action; // 'APPROVE', 'REJECT', 'REQUEST_CORRECTION'
  final String? previousStatus;
  final String? newStatus;
  final String? comments;
  final DateTime timestamp;
  final String actorName;
  final String? claimId;
  final String? claimNumber;
  final String? claimTitle;
  final int claimAmountMinor;
  final String? claimStatus;
  final String? employeeName;
  final bool isAdvance;

  const AuditActionItem({
    required this.id,
    required this.action,
    this.previousStatus,
    this.newStatus,
    this.comments,
    required this.timestamp,
    required this.actorName,
    this.claimId,
    this.claimNumber,
    this.claimTitle,
    this.claimAmountMinor = 0,
    this.claimStatus,
    this.employeeName,
    this.isAdvance = false,
  });
}

/// Unified approval queue and audit history for managers.
class ManagerApprovalScreen extends StatefulWidget {
  final bool isManagementOnly;
  final String? initialTab;
  const ManagerApprovalScreen({super.key, this.isManagementOnly = false, this.initialTab});

  @override
  State<ManagerApprovalScreen> createState() => _ManagerApprovalScreenState();
}

class _ManagerApprovalScreenState extends State<ManagerApprovalScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<QueueItem> _claims = [];
  List<QueueItem> _advances = [];
  List<AuditActionItem> _auditActions = [];
  String _selectedAuditFilter = 'ALL';
  bool _isLoading = true;
  String? _errorMessage;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    int initialIndex = 0;
    if (widget.initialTab == 'history') {
      initialIndex = 2;
    } else if (widget.initialTab == 'advances') {
      initialIndex = 1;
    }
    _tabController = TabController(length: 3, vsync: this, initialIndex: initialIndex);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final queueFuture = loadApprovalQueue(managementOnly: widget.isManagementOnly);
      final auditFuture = _loadAuditHistory();

      final queue = await queueFuture;
      final audit = await auditFuture;

      if (mounted) {
        setState(() {
          _claims = queue.claims;
          _advances = queue.advances;
          _auditActions = audit;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not load the approval data. Check your connection and try again.';
          _isLoading = false;
        });
      }
    }
  }

  Future<List<AuditActionItem>> _loadAuditHistory() async {
    final client = SupabaseService().client;
    final items = <AuditActionItem>[];

    try {
      final claimRes = await client
          .from('approval_actions')
          .select('id, action, previous_status, new_status, comments, action_timestamp, actor_id, actor:employees!approval_actions_actor_id_fkey(full_name), claim:expense_claims(id, claim_number, title, total_expense_minor, status, employee:employees!expense_claims_employee_id_fkey(full_name))')
          .order('action_timestamp', ascending: false);

      for (final r in (claimRes as List).cast<Map<String, dynamic>>()) {
        final claim = r['claim'] as Map<String, dynamic>?;
        final actor = r['actor'] as Map<String, dynamic>?;
        final emp = claim?['employee'] as Map<String, dynamic>?;
        items.add(AuditActionItem(
          id: r['id'] as String,
          action: r['action'] as String? ?? 'APPROVE',
          previousStatus: r['previous_status'] as String?,
          newStatus: r['new_status'] as String?,
          comments: r['comments'] as String?,
          timestamp: DateTime.tryParse(r['action_timestamp'] as String? ?? '')?.toLocal() ?? DateTime.now(),
          actorName: actor?['full_name'] as String? ?? 'Manager',
          claimId: claim?['id'] as String?,
          claimNumber: claim?['claim_number'] as String?,
          claimTitle: claim?['title'] as String? ?? 'Expense Claim',
          claimAmountMinor: (claim?['total_expense_minor'] as num?)?.toInt() ?? 0,
          claimStatus: claim?['status'] as String?,
          employeeName: emp?['full_name'] as String? ?? 'Team Member',
          isAdvance: false,
        ));
      }
    } catch (e) {
      debugPrint('Error loading claim approval actions: $e');
    }

    try {
      final advRes = await client
          .from('advance_approval_actions')
          .select('id, action, previous_stage, new_stage, comments, created_at, actor_id, actor:employees!advance_approval_actions_actor_id_fkey(full_name), advance:cash_advances(id, advance_number, purpose, amount_minor, status, employee:employees!cash_advances_employee_id_fkey(full_name))')
          .order('created_at', ascending: false);

      for (final r in (advRes as List).cast<Map<String, dynamic>>()) {
        final adv = r['advance'] as Map<String, dynamic>?;
        final actor = r['actor'] as Map<String, dynamic>?;
        final emp = adv?['employee'] as Map<String, dynamic>?;
        items.add(AuditActionItem(
          id: r['id'] as String,
          action: r['action'] as String? ?? 'APPROVE',
          previousStatus: r['previous_stage'] as String?,
          newStatus: r['new_stage'] as String?,
          comments: r['comments'] as String?,
          timestamp: DateTime.tryParse(r['created_at'] as String? ?? '')?.toLocal() ?? DateTime.now(),
          actorName: actor?['full_name'] as String? ?? 'Manager',
          claimId: adv?['id'] as String?,
          claimNumber: adv?['advance_number'] as String?,
          claimTitle: adv?['purpose'] as String? ?? 'Cash Advance',
          claimAmountMinor: (adv?['amount_minor'] as num?)?.toInt() ?? 0,
          claimStatus: adv?['status'] as String?,
          employeeName: emp?['full_name'] as String? ?? 'Team Member',
          isAdvance: true,
        ));
      }
    } catch (e) {
      debugPrint('Error loading advance approval actions: $e');
    }

    items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return items;
  }

  Future<void> _act(QueueItem item, String action) async {
    final isAdmin = AuthNotifier().isAdmin;
    final needsReason = action != 'APPROVE' || isAdmin;
    final title = switch (action) {
      'APPROVE' => item.isAdvance ? 'Approve Cash Advance' : 'Approve Claim',
      'REJECT' => item.isAdvance ? 'Reject Cash Advance' : 'Reject Claim',
      _ => 'Request Correction',
    };
    final controller = TextEditingController();
    final comments = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? err;
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: Text(title),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('#${item.number} - ${item.employeeName.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim()} - ${MoneyUtils.format(item.amountMinor, currency: item.currency)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: AsmTheme.textSecondary)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: action == 'APPROVE' && isAdmin
                      ? 'Override reason (required for Admin, recorded in audit log)'
                      : needsReason ? 'Reason (required)' : 'Comments (optional)',
                  errorText: err,
                ),
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back')),
              ElevatedButton(
                onPressed: () {
                  if (needsReason && controller.text.trim().isEmpty) {
                    setD(() => err = 'Please enter a reason');
                    return;
                  }
                  Navigator.pop(ctx, controller.text.trim());
                },
                child: Text(action == 'APPROVE' ? 'Approve' : 'Submit'),
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();
    if (comments == null || !mounted) return;

    setState(() => _busyId = item.id);
    try {
      final res = item.isAdvance
          ? await SupabaseService().reviewCashAdvance(advanceId: item.id, action: action, comments: comments.isEmpty ? null : comments)
          : Map<String, dynamic>.from(await SupabaseService().client.rpc('process_approval_action', params: {
              'p_claim_id': item.id,
              'p_action': action,
              'p_comments': comments.isEmpty ? null : comments,
            }) as Map);
      final ok = res['success'] == true;
      if (ok && mounted) {
        setState(() {
          if (item.isAdvance) {
            _advances.removeWhere((a) => a.id == item.id);
          } else {
            _claims.removeWhere((c) => c.id == item.id);
          }
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok ? '#${item.number}: action recorded.' : (res['message'] as String? ?? 'The action was not accepted.')),
          backgroundColor: ok ? AsmTheme.statusApproved : AsmTheme.statusRejected,
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not reach the server. Refresh the queue before retrying.'),
          backgroundColor: AsmTheme.statusRejected,
        ));
      }
    } finally {
      if (mounted) {
        setState(() => _busyId = null);
        _load();
      }
    }
  }

  Widget _empty(String text) => ListView(children: [
        const SizedBox(height: 60),
        _errorMessage != null
            ? StateMessage.error(message: _errorMessage!, onAction: _load)
            : StateMessage(icon: Icons.task_alt, iconColor: AsmTheme.statusApproved, title: 'Queue is clear', message: text),
      ]);

  Widget _card(QueueItem item) {
    final busy = _busyId == item.id;
    final age = item.ageDays(DateTime.now());
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  item.employeeName.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim(),
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text('${item.department ?? 'Department not set'}  |  #${item.number}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted)),
                if (age != null)
                  Text(
                    age == 0 ? 'Submitted today' : 'Waiting $age ${age == 1 ? 'day' : 'days'}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: age >= 7 ? AsmTheme.statusWarning : AsmTheme.textSecondary,
                    ),
                  ),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(MoneyUtils.format(item.amountMinor, currency: item.currency), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              if (item.currency != 'AED') Text('AED ${MoneyUtils.formatAmount(item.aedMinor)}', style: const TextStyle(fontSize: 11, color: AsmTheme.textMuted)),
              Text(reviewStageLabels[item.stageKey] ?? item.stageKey, style: const TextStyle(fontSize: 11, color: AsmTheme.statusPending, fontWeight: FontWeight.w700)),
            ]),
          ]),
          const SizedBox(height: 10),
          Text(item.purpose, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AsmTheme.textSecondary)),
          const SizedBox(height: 12),
          if (busy) const LinearProgressIndicator(),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      await context.push(item.isAdvance ? '/advances/${item.id}' : '/claims/${item.id}');
                      if (mounted) _load();
                    },
              child: Text(item.isAdvance ? 'View details' : 'View details and receipts'),
            ),
            if (!item.isAdvance)
              OutlinedButton(onPressed: busy ? null : () => _act(item, 'REQUEST_CORRECTION'), child: const Text('Request Correction')),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: AsmTheme.statusRejected),
              onPressed: busy ? null : () => _act(item, 'REJECT'),
              child: const Text('Reject'),
            ),
            ElevatedButton(onPressed: busy ? null : () => _act(item, 'APPROVE'), child: const Text('Approve')),
          ]),
        ]),
      ),
    );
  }

  Widget _list(List<QueueItem> items, String emptyText) => RefreshIndicator(
        onRefresh: _load,
        child: items.isEmpty || _errorMessage != null
            ? _empty(emptyText)
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                itemBuilder: (_, i) => FadeSlideIn(index: i, child: _card(items[i])),
              ),
      );

  Widget _filterChip(String filterKey, String label, {Color? color}) {
    final isSelected = _selectedAuditFilter == filterKey;
    final chipColor = color ?? AsmTheme.primaryNavy;

    return InkWell(
      onTap: () => setState(() => _selectedAuditFilter = filterKey),
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? chipColor : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? chipColor : const Color(0xFFCBD5E1),
            width: 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: chipColor.withValues(alpha: 0.25), blurRadius: 4, offset: const Offset(0, 2))]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? Colors.white : AsmTheme.textHeading,
          ),
        ),
      ),
    );
  }

  Widget _auditCard(AuditActionItem item) {
    final isApprove = item.action == 'APPROVE';
    final isReject = item.action == 'REJECT';

    final actionColor = isApprove
        ? const Color(0xFF059669)
        : isReject
            ? const Color(0xFFDC2626)
            : const Color(0xFFD97706);

    final actionBg = isApprove
        ? const Color(0xFFECFDF5)
        : isReject
            ? const Color(0xFFFEF2F2)
            : const Color(0xFFFFFBEB);

    final actionBorder = isApprove
        ? const Color(0xFFA7F3D0)
        : isReject
            ? const Color(0xFFFECACA)
            : const Color(0xFFFDE68A);

    final actionIcon = isApprove
        ? Icons.check_circle_rounded
        : isReject
            ? Icons.cancel_rounded
            : Icons.edit_note_rounded;

    final actionLabel = isApprove
        ? 'Approved'
        : isReject
            ? 'Rejected'
            : 'Correction Requested';

    final timeStr =
        '${item.timestamp.day.toString().padLeft(2, '0')}/${item.timestamp.month.toString().padLeft(2, '0')}/${item.timestamp.year} ${item.timestamp.hour.toString().padLeft(2, '0')}:${item.timestamp.minute.toString().padLeft(2, '0')}';

    final employeeDisplay = (item.employeeName ?? 'Team Member').replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          if (item.claimId != null) {
            context.push(item.isAdvance ? '/advances/${item.claimId}' : '/claims/${item.claimId}');
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: actionBg,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: actionBorder, width: 0.8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(actionIcon, size: 14, color: actionColor),
                        const SizedBox(width: 4),
                        Text(
                          actionLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: actionColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    timeStr,
                    style: const TextStyle(fontSize: 11, color: AsmTheme.textMuted, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.claimTitle ?? 'Expense Claim',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: AsmTheme.textHeading,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: const Color(0xFFCBD5E1), width: 0.7),
                              ),
                              child: Text(
                                employeeDisplay,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: AsmTheme.primaryNavy,
                                ),
                              ),
                            ),
                            if (item.claimNumber != null)
                              Text(
                                '#${item.claimNumber}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: AsmTheme.textMuted,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    MoneyUtils.format(item.claimAmountMinor),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: AsmTheme.textHeading,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFE2E8F0), width: 0.7),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.person_outline_rounded, size: 14, color: AsmTheme.textSecondary),
                    const SizedBox(width: 6),
                    const Text(
                      'Action by: ',
                      style: TextStyle(fontSize: 11, color: AsmTheme.textMuted),
                    ),
                    Expanded(
                      child: Text(
                        item.actorName,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AsmTheme.textHeading),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (item.previousStatus != null && item.newStatus != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${item.previousStatus} → ${item.newStatus}',
                        style: const TextStyle(fontSize: 10, color: AsmTheme.textMuted, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ],
                ),
              ),
              if (item.comments != null && item.comments!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: actionBg.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(6),
                    border: Border(
                      left: BorderSide(color: actionColor, width: 3),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.notes_rounded, size: 14, color: actionColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.comments!,
                          style: TextStyle(
                            fontSize: 12,
                            color: actionColor.withValues(alpha: 0.95),
                            fontWeight: FontWeight.w600,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerRight,
                child: Text(
                  'View full claim flow →',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AsmTheme.brandBlue),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _auditHistoryTab() {
    final filtered = _auditActions.where((a) {
      if (_selectedAuditFilter == 'ALL') return true;
      return a.action == _selectedAuditFilter;
    }).toList();

    final approveCount = _auditActions.where((a) => a.action == 'APPROVE').length;
    final rejectCount = _auditActions.where((a) => a.action == 'REJECT').length;
    final correctionCount = _auditActions.where((a) => a.action == 'REQUEST_CORRECTION').length;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _filterChip('ALL', 'All Actions (${_auditActions.length})'),
                const SizedBox(width: 8),
                _filterChip('APPROVE', 'Approved ($approveCount)', color: AsmTheme.statusApproved),
                const SizedBox(width: 8),
                _filterChip('REJECT', 'Rejected ($rejectCount)', color: AsmTheme.statusRejected),
                const SizedBox(width: 8),
                _filterChip('REQUEST_CORRECTION', 'Corrections ($correctionCount)', color: AsmTheme.statusWarning),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  'No audit actions found for this filter.',
                  style: TextStyle(color: AsmTheme.textMuted, fontSize: 13),
                ),
              ),
            )
          else
            for (final (index, item) in filtered.indexed) ...[
              FadeSlideIn(
                index: index,
                child: _auditCard(item),
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AsmTheme.bgCanvas,
      appBar: AppBar(
        title: Text(
          widget.isManagementOnly ? 'Management Review Queue' : 'Approvals & Audit Queue',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load, tooltip: 'Reload'),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'Pending Claims (${_claims.length})'),
            Tab(text: 'Pending Advances (${_advances.length})'),
            Tab(text: 'Audit & History (${_auditActions.length})'),
          ],
        ),
      ),
      body: StateSwitcher(
        child: _isLoading
            ? const SkeletonList(key: ValueKey('loading'), rowHeight: 120)
            : TabBarView(
                controller: _tabController,
                key: const ValueKey('content'),
                children: [
                  _list(_claims, 'No expense claims are awaiting your action.'),
                  _list(_advances, 'No cash advances are awaiting your action.'),
                  _auditHistoryTab(),
                ],
              ),
      ),
    );
  }
}
