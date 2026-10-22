import 'package:flutter/material.dart';
import '../../shared/widgets/async_states.dart';
import 'package:go_router/go_router.dart';
import '../../app/theme/asm_theme.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../shared/models/expense_claim.dart';
import '../../shared/widgets/stage_timeline.dart';
import '../../shared/widgets/status_badge.dart';
import '../../shared/workflow/approval_stages.dart';

/// Claim Detail Screen replicating Reference Screenshot 4:
/// - Dark slate hero card with Report ID & high-contrast Total Amount
/// - Segmented Tabs: Expenses | Comments | History
/// - Receipt thumbnail list items
/// - Vertical Approval Process Timeline
/// - Full-width action button (Approve / Submit)
class ClaimDetailScreen extends StatefulWidget {
  final String claimId;

  const ClaimDetailScreen({
    super.key,
    required this.claimId,
  });

  @override
  State<ClaimDetailScreen> createState() => _ClaimDetailScreenState();
}

class _ClaimDetailScreenState extends State<ClaimDetailScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  ExpenseClaim? _claim;
  List<Map<String, dynamic>> _claimExpenses = [];
  List<Map<String, dynamic>> _actions = [];
  Map<String, dynamic>? _reimbursement;
  String? _department;
  String? _ownerLineManagerId;
  String? _ownerHodId;
  bool _isLoading = true;
  String? _loadError;

  bool get _canCorrect =>
      _claim != null &&
      _claim!.status == ClaimStatus.correctionRequired &&
      _claim!.employeeId == SupabaseService().currentUserId;

  bool get _canCancel =>
      _claim != null &&
      _claim!.employeeId == SupabaseService().currentUserId &&
      const {
        ClaimStatus.draft,
        ClaimStatus.submitted,
        ClaimStatus.lineManagerReview,
        ClaimStatus.hodReview,
        ClaimStatus.sivaReview,
        ClaimStatus.financeReview,
        ClaimStatus.correctionRequired,
      }.contains(_claim!.status);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadClaimData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadClaimData() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final client = SupabaseService().client;
      final res = await client
          .from('expense_claims')
          .select('*, employees(full_name, line_manager_id, hod_id, departments!employees_department_id_fkey(name))')
          .eq('id', widget.claimId)
          .maybeSingle();

      // Expenses removed during correction are history, not part of the claim
      final expRes = await client
          .from('claim_expenses')
          .select('*, expenses(*, expense_categories(name), expense_receipts(storage_path, receipt_total_minor, currency_code, mime_type))')
          .eq('claim_id', widget.claimId)
          .or('release_reason.is.null,release_reason.neq.REMOVED_IN_CORRECTION');

      final actionRes = await client
          .from('approval_actions')
          .select('action, previous_status, new_status, comments, action_timestamp, employees(full_name)')
          .eq('claim_id', widget.claimId)
          .order('action_timestamp', ascending: true);

      final reimbRes = await client
          .from('reimbursements')
          .select('status, updated_at, payments(payment_date, payment_reference)')
          .eq('claim_id', widget.claimId)
          .maybeSingle();

      if (mounted) {
        final empData = res?['employees'] as Map<String, dynamic>?;
        setState(() {
          _reimbursement = reimbRes;
          _ownerLineManagerId = empData?['line_manager_id'] as String?;
          _ownerHodId = empData?['hod_id'] as String?;
          _department = (empData?['departments'] as Map<String, dynamic>?)?['name'] as String?;
          _claim = res == null ? null : ExpenseClaim.fromJson(res);
          _claimExpenses = List<Map<String, dynamic>>.from(expRes as List);
          _actions = List<Map<String, dynamic>>.from(actionRes as List);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = 'Could not load this claim. Check your connection and try again.';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _openCorrection() async {
    await context.push('/claims/${widget.claimId}/correct');
    if (mounted) _loadClaimData();
  }

  Future<void> _showCancelDialog() async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Expense Report'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Are you sure you want to cancel this claim? All attached expenses and cash advance reservations will be released.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: reasonController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Cancellation reason',
                hintText: 'Enter mandatory reason for cancellation...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Claim')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AsmTheme.statusRejected,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              if (reasonController.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('Cancel Claim'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        final ok = await SupabaseService().cancelExpenseClaim(_claim!.id, reasonController.text.trim());
        if (ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Claim successfully cancelled.')),
          );
          _loadClaimData();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to cancel claim. Please retry.')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Claim Details')),
        body: const SkeletonList(rows: 5, rowHeight: 88),
      );
    }

    if (_loadError != null || _claim == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Expense Report')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_loadError ?? 'Claim report not found.', style: const TextStyle(color: AsmTheme.textSecondary)),
              if (_loadError != null) ...[
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _loadClaimData, child: const Text('Retry')),
              ],
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AsmTheme.surfaceBackground,
      appBar: AppBar(
        title: const Text('View expense report'),
        actions: [
          if (_canCancel)
            IconButton(
              icon: const Icon(Icons.cancel_outlined, color: AsmTheme.statusRejected),
              tooltip: 'Cancel Claim',
              onPressed: _showCancelDialog,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 1. Dark Hero Report Card
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: AsmTheme.primaryNavy,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: AsmTheme.cardShadow,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '#${_claim!.claimNumber}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white60,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _claim!.title,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                          height: 1.25,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                StatusBadge(status: _claim!.status.displayName, isLarge: true),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Text(
                              MoneyUtils.format(_claim!.totalExpenseMinor),
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Submitted on : ${_claim!.claimDate.toIso8601String().split('T')[0]}',
                              style: const TextStyle(fontSize: 12, color: Colors.white60),
                            ),
                            const Divider(color: Colors.white12, height: 24),
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('Employee', style: TextStyle(fontSize: 11, color: Colors.white54)),
                                      const SizedBox(height: 2),
                                      Text((_claim!.employeeName ?? 'Employee').replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim(),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
                                      if (_department != null)
                                        Text(_department!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 11, color: Colors.white60)),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${_claimExpenses.length} ${_claimExpenses.length == 1 ? 'Expense' : 'Expenses'}',
                                    style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      if (_claim!.status == ClaimStatus.correctionRequired) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AsmTheme.statusPending.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AsmTheme.statusPending.withValues(alpha: 0.3)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Correction required',
                                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AsmTheme.textHeading)),
                              const SizedBox(height: 4),
                              Text(_claim!.validationNotes ?? 'The reviewer returned this claim for correction.',
                                  style: const TextStyle(fontSize: 13, color: AsmTheme.textMuted)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // 2. Segmented Underlined Tabs
                      TabBar(
                        controller: _tabController,
                        labelColor: AsmTheme.textHeading,
                        unselectedLabelColor: AsmTheme.textMuted,
                        indicatorColor: AsmTheme.brandBlue,
                        indicatorWeight: 2.5,
                        labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                        tabs: const [
                          Tab(text: 'Expenses'),
                          Tab(text: 'Approval Flow'),
                          Tab(text: 'Reconciliation'),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // 3. Tab Contents
                      SizedBox(
                        height: (MediaQuery.sizeOf(context).height * 0.6).clamp(360.0, 720.0),
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            _buildExpensesList(),
                            _buildApprovalTimeline(),
                            _buildReconciliationTab(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 4. Owner action: correct and resubmit a returned claim
          if (_canCorrect)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: AsmTheme.borderLight)),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _openCorrection,
                      child: const Text('Correct & Resubmit', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildExpensesList() {
    if (_claimExpenses.isEmpty) {
      return const Center(child: Text('No expenses attached to this report.'));
    }

    return ListView.builder(
      itemCount: _claimExpenses.length,
      itemBuilder: (context, idx) {
        final item = _claimExpenses[idx]['expenses'] as Map<String, dynamic>?;
        if (item == null) return const SizedBox.shrink();

        final cat = item['expense_categories'] as Map<String, dynamic>?;
        final amountMinor = (item['aed_amount_minor'] as num).toInt();
        final currency = item['currency_code'] as String? ?? 'AED';
        final originalMinor = (item['amount_minor'] as num?)?.toInt() ?? amountMinor;
        final receipts = (item['expense_receipts'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: receipts.isNotEmpty ? () => _showReceipt(receipts.first) : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  // Receipt Thumbnail / Document Icon
                  Tooltip(
                    message: receipts.isNotEmpty
                        ? 'Tap to view bill / receipt'
                        : (item['has_receipt'] == true ? 'Receipt attached' : 'No receipt'),
                    child: Container(
                      width: 44,
                      height: 48,
                      decoration: BoxDecoration(
                        color: receipts.isNotEmpty ? AsmTheme.brandBlue.withValues(alpha: 0.08) : AsmTheme.surfaceMuted,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: receipts.isNotEmpty ? AsmTheme.brandBlue.withValues(alpha: 0.3) : AsmTheme.borderLight,
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          receipts.isNotEmpty ? Icons.receipt_long : Icons.receipt_outlined,
                          color: receipts.isNotEmpty ? AsmTheme.brandBlue : AsmTheme.textMuted,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cat?['name'] ?? 'Expense',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AsmTheme.textHeading),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${item['vendor'] as String? ?? 'Vendor'}  |  ${item['expense_date'] ?? ''}',
                          style: const TextStyle(fontSize: 12, color: AsmTheme.textMuted),
                        ),
                        if ((item['description'] as String?)?.trim().isNotEmpty ?? false)
                          Text(item['description'] as String, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: AsmTheme.textSecondary)),
                        if (currency != 'AED')
                          Text('Rate ${item['exchange_rate']} $currency to AED (server rate)',
                              style: const TextStyle(fontSize: 11, color: AsmTheme.textMuted)),
                        const SizedBox(height: 4),
                        if (receipts.isNotEmpty)
                          Wrap(
                            spacing: 8,
                            children: [
                              for (int rIdx = 0; rIdx < receipts.length; rIdx++)
                                InkWell(
                                  borderRadius: BorderRadius.circular(4),
                                  onTap: () => _showReceipt(receipts[rIdx]),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.remove_red_eye_outlined, size: 14, color: AsmTheme.brandBlue),
                                        const SizedBox(width: 4),
                                        Text(
                                          receipts.length == 1 ? 'View Bill' : 'View Bill #${rIdx + 1}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: AsmTheme.brandBlue,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          )
                        else
                          Text(item['has_receipt'] == true ? 'Receipt missing' : 'No receipt: ${item['no_receipt_reason'] ?? ''}',
                              style: const TextStyle(fontSize: 11, color: AsmTheme.statusPending)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        MoneyUtils.format(amountMinor),
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AsmTheme.textHeading),
                      ),
                      if (currency != 'AED')
                        Text(MoneyUtils.format(originalMinor, currency: currency),
                            style: const TextStyle(fontSize: 11, color: AsmTheme.textMuted)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showReceipt(Map<String, dynamic> receipt) async {
    final path = receipt['storage_path'] as String?;
    final url = path == null ? null : await SupabaseService().receiptSignedUrl(path);
    if (!mounted) return;
    final mime = receipt['mime_type'] as String? ?? '';
    final isImage = mime.startsWith('image/') ||
        (path != null && (path.endsWith('.jpg') || path.endsWith('.jpeg') || path.endsWith('.png') || path.endsWith('.webp')));
    final total = (receipt['receipt_total_minor'] as num?)?.toInt();
    final filename = receipt['original_file_name'] as String? ?? 'Receipt';

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        title: Row(
          children: [
            const Icon(Icons.receipt_long, color: AsmTheme.brandBlue, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    total != null
                        ? 'Bill / Receipt (${MoneyUtils.format(total, currency: receipt['currency_code'] as String? ?? 'AED')})'
                        : filename,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (total != null && filename.isNotEmpty)
                    Text(filename, style: const TextStyle(fontSize: 11, color: AsmTheme.textMuted), overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.pop(ctx),
              tooltip: 'Close',
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 540,
            maxHeight: (MediaQuery.sizeOf(context).height * 0.7).clamp(300.0, 650.0),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              color: const Color(0xFFF1F5F9),
              child: url == null
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'This receipt could not be opened. You may not have access, or it is unavailable.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AsmTheme.textSecondary),
                        ),
                      ),
                    )
                  : isImage
                      ? InteractiveViewer(
                          panEnabled: true,
                          minScale: 0.8,
                          maxScale: 5.0,
                          child: Center(
                            child: Image.network(
                              url,
                              fit: BoxFit.contain,
                              loadingBuilder: (c, child, p) => p == null
                                  ? child
                                  : const SizedBox(
                                      height: 250,
                                      child: Center(
                                        child: CircularProgressIndicator(strokeWidth: 2.5),
                                      ),
                                    ),
                              errorBuilder: (c, e, s) => const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text('The receipt image could not be loaded.'),
                                ),
                              ),
                            ),
                          ),
                        )
                      : const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('This receipt is a document (PDF) and cannot be previewed in the app.'),
                          ),
                        ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(ctx),
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Done'),
          ),
        ],
      ),
    );
  }

  /// Stage view plus recorded approval history (approval_actions), oldest first.
  Widget _buildApprovalTimeline() {
    final submittedAt = _claim!.submittedAt;
    final awaiting = const {
      ClaimStatus.lineManagerReview,
      ClaimStatus.hodReview,
      ClaimStatus.sivaReview,
      ClaimStatus.financeReview,
      ClaimStatus.correctionRequired,
      ClaimStatus.approved,
    }.contains(_claim!.status);

    String fmt(String? iso) {
      final dt = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
      if (dt == null) return '';
      return '${dt.toIso8601String().split('T')[0]} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }

    String label(String action) => switch (action) {
          'APPROVE' => 'Approved',
          'REJECT' => 'Rejected',
          'REQUEST_CORRECTION' => 'Correction requested',
          _ => action,
        };

    final halt = _actions.lastWhere(
      (a) => a['action'] == 'REJECT' || a['action'] == 'REQUEST_CORRECTION',
      orElse: () => const {},
    );

    final hasLineManager = _ownerLineManagerId != null;
    final hasHod = _ownerHodId != null || _ownerLineManagerId != null;

    return ListView(
      children: [
        StageTimeline(
          stages: claimStages(
            _claim!.status,
            haltedAtStatus: halt['previous_status'] as String?,
            settledByAdvance: _claim!.status == ClaimStatus.settled && _claim!.netReimbursementMinor == 0,
            hasLineManager: hasLineManager,
            hasHod: hasHod,
          ),
        ),
        const Divider(height: 24),
        const Text('Recorded history', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AsmTheme.textHeading)),
        const SizedBox(height: 10),
        _buildTimelineStep(
          'Submitted by ${(_claim!.employeeName ?? 'employee').replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim()}',
          submittedAt != null ? 'Last submitted ${fmt(submittedAt.toIso8601String())}' : 'Not yet submitted',
          isCompleted: submittedAt != null,
        ),
        for (final a in _actions)
          _buildTimelineStep(
            '${label(a['action'] as String)} - ${((a['employees'] as Map<String, dynamic>?)?['full_name'] as String? ?? 'Reviewer').replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim()}',
            [
              '${ClaimStatus.fromString(a['previous_status'] as String).displayName} to '
                  '${ClaimStatus.fromString(a['new_status'] as String).displayName}',
              fmt(a['action_timestamp'] as String?),
              if ((a['comments'] as String?)?.trim().isNotEmpty ?? false) 'Comment: ${a['comments']}',
            ].where((s) => s.isNotEmpty).join('\n'),
            isCompleted: a['action'] == 'APPROVE',
          ),
        if (awaiting)
          _buildTimelineStep(
            _claim!.status == ClaimStatus.lineManagerReview
                ? 'Current stage: Awaiting Line Manager review'
                : _claim!.status == ClaimStatus.hodReview
                    ? 'Current stage: Awaiting Head of Department review'
                    : _claim!.status == ClaimStatus.sivaReview
                        ? 'Current stage: Awaiting Management review'
                        : _claim!.status == ClaimStatus.financeReview
                            ? 'Current stage: Awaiting Finance review'
                            : _claim!.status == ClaimStatus.approved
                                ? 'Approved • Awaiting Finance disbursement'
                                : 'Current stage: ${_claim!.status.displayName}',
            _claim!.status == ClaimStatus.correctionRequired
                ? 'Waiting for the employee to correct and resubmit'
                : 'In progress',
            isCompleted: false,
          ),
        if (_actions.isEmpty && submittedAt == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No approval actions recorded yet.', style: TextStyle(fontSize: 12, color: AsmTheme.textMuted)),
          ),
      ],
    );
  }

  Widget _buildTimelineStep(String title, String subtitle, {required bool isCompleted}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: isCompleted ? AsmTheme.statusApproved : AsmTheme.surfaceMuted,
            child: Icon(
              isCompleted ? Icons.check : Icons.schedule,
              size: 14,
              color: isCompleted ? Colors.white : AsmTheme.textMuted,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: isCompleted ? AsmTheme.textHeading : AsmTheme.textMuted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(fontSize: 11, color: AsmTheme.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _paymentStatusText() {
    final c = _claim!;
    if (c.status == ClaimStatus.settled && c.netReimbursementMinor == 0) return 'Settled against cash advance';
    final payments = (_reimbursement?['payments'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (_reimbursement?['status'] == 'PAID' && payments.isNotEmpty) {
      return 'Paid on ${payments.first['payment_date']} (Ref ${payments.first['payment_reference']})';
    }
    if (_reimbursement != null) return 'Approved - awaiting Finance disbursement';
    return switch (c.status) {
      ClaimStatus.rejected => 'Not payable (rejected)',
      ClaimStatus.cancelled => 'Not payable (cancelled)',
      _ => 'Pending approval',
    };
  }

  Widget _buildReconciliationTab() {
    return ListView(children: [
      Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Server validation:'),
                Flexible(
                  child: Text(
                    switch (_claim!.validationStatus) {
                      'PASSED' => 'Passed (receipts and policy)',
                      'PENDING' => 'Not yet validated',
                      _ => _claim!.validationStatus,
                    },
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Gross Expense Total:'),
                Text(MoneyUtils.format(_claim!.totalExpenseMinor), style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            if (_claim!.advanceAppliedMinor > 0) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Cash Advance Applied:'),
                  Text('- ${MoneyUtils.format(_claim!.advanceAppliedMinor)}', style: const TextStyle(fontWeight: FontWeight.w700, color: AsmTheme.statusPending)),
                ],
              ),
            ],
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Net Payable Reimbursable:', style: TextStyle(fontWeight: FontWeight.w700)),
                Text(MoneyUtils.format(_claim!.netReimbursementMinor), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: AsmTheme.statusApproved)),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Payment status:'),
                Flexible(child: Text(_paymentStatusText(), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
              ],
            ),
            if (_claim!.cashAdvanceId != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.push('/advances/${_claim!.cashAdvanceId}'),
                  child: const Text('View cash advance and refunds'),
                ),
              ),
            ],
          ],
        ),
      ),
      ),
    ]);
  }
}
