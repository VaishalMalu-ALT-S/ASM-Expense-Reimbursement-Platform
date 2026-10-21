import 'package:flutter/material.dart';
import '../../shared/widgets/async_states.dart';
import 'package:uuid/uuid.dart';
import '../../app/theme/asm_theme.dart';
import '../../core/auth/auth_notifier.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../shared/models/cash_advance.dart';
import '../../shared/models/expense_claim.dart';
import '../../shared/workflow/approval_stages.dart';
import '../../shared/widgets/stage_timeline.dart';

/// Cash advance detail for the requester, approvers and Finance. Buttons
/// reflect the signed-in user's stage/role; the server authorizes every action.
class AdvanceDetailScreen extends StatefulWidget {
  final String advanceId;

  const AdvanceDetailScreen({super.key, required this.advanceId});

  @override
  State<AdvanceDetailScreen> createState() => _AdvanceDetailScreenState();
}

class _AdvanceDetailScreenState extends State<AdvanceDetailScreen> {
  static const _reservingStatuses = {
    ClaimStatus.submitted,
    ClaimStatus.lineManagerReview,
    ClaimStatus.hodReview,
    ClaimStatus.sivaReview,
    ClaimStatus.financeReview,
    ClaimStatus.correctionRequired,
  };
  static const _paymentMethods = {'BANK_TRANSFER': 'Bank transfer', 'CHEQUE': 'Cheque', 'CASH': 'Cash'};

  CashAdvance? _advance;
  Map<String, dynamic>? _owner;
  List<Map<String, dynamic>> _actions = [];
  List<Map<String, dynamic>> _refunds = [];
  List<Map<String, dynamic>> _claims = [];
  bool _isLoading = true;
  bool _busy = false;
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
      final client = SupabaseService().client;
      final adv = await client
          .from('cash_advances')
          .select('*, employees!cash_advances_employee_id_fkey(full_name, line_manager_id, hod_id, departments!employees_department_id_fkey(name))')
          .eq('id', widget.advanceId)
          .maybeSingle();
      if (adv == null) {
        if (mounted) setState(() { _error = 'Cash advance not found or you do not have access to it.'; _isLoading = false; });
        return;
      }
      final actions = await client
          .from('advance_approval_actions')
          .select('action, previous_stage, new_stage, comments, created_at, employees(full_name)')
          .eq('advance_id', widget.advanceId)
          .order('created_at');
      final refunds = await client
          .from('advance_refunds')
          .select('refund_amount_minor, refund_reference, refund_date, payment_method, notes')
          .eq('advance_id', widget.advanceId)
          .order('created_at');
      final claims = await client
          .from('expense_claims')
          .select('id, claim_number, status, advance_applied_minor')
          .eq('cash_advance_id', widget.advanceId);
      if (!mounted) return;
      setState(() {
        _advance = CashAdvance.fromJson(adv);
        _owner = adv['employees'] as Map<String, dynamic>?;
        _actions = List<Map<String, dynamic>>.from(actions as List);
        _refunds = List<Map<String, dynamic>>.from(refunds as List);
        _claims = List<Map<String, dynamic>>.from(claims as List);
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() { _error = 'Could not load this cash advance. Check your connection and try again.'; _isLoading = false; });
    }
  }

  // --- Derived values (display only) ---------------------------------------
  String get _me => SupabaseService().currentUserId ?? '';
  bool get _isOwner => _advance?.employeeId == _me;
  int get _reservedMinor => _claims
      .where((c) => _reservingStatuses.contains(ClaimStatus.fromString(c['status'] as String)))
      .fold<int>(0, (s, c) => s + ((c['advance_applied_minor'] as num?)?.toInt() ?? 0));
  int get _availableMinor => (_advance?.remainingBalanceMinor ?? 0) - _reservedMinor;

  bool get _canReview {
    final a = _advance;
    if (a == null || a.status != CashAdvanceStatus.underReview) return false;
    final auth = AuthNotifier().state;
    return canActAtStage(
      stageKey: a.currentApprovalStage,
      ownerId: a.employeeId,
      ownerLineManagerId: _owner?['line_manager_id'] as String?,
      ownerHodId: _owner?['hod_id'] as String?,
      currentUserId: _me,
      isManagement: auth.isManagement,
      isFinance: auth.isFinance,
      isAdmin: auth.isAdmin,
    );
  }

  bool get _canPay => AuthNotifier().state.isFinance && !_isOwner && _advance?.status == CashAdvanceStatus.approved;
  bool get _canRefund =>
      AuthNotifier().state.isFinance &&
      !_isOwner &&
      (_advance?.status == CashAdvanceStatus.paid || _advance?.status == CashAdvanceStatus.partiallySettled) &&
      _availableMinor > 0;
  bool get _canCancel =>
      _isOwner &&
      const {CashAdvanceStatus.draft, CashAdvanceStatus.submitted, CashAdvanceStatus.underReview, CashAdvanceStatus.approved}
          .contains(_advance?.status);

  // --- Actions ------------------------------------------------------------
  Future<void> _run(Future<Map<String, dynamic>> Function() call, String fallbackSuccess) async {
    setState(() => _busy = true);
    try {
      final res = await call();
      final ok = res['success'] == true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res['message'] as String? ?? (ok ? fallbackSuccess : 'The action could not be completed.')),
          backgroundColor: ok ? AsmTheme.statusApproved : AsmTheme.statusRejected,
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not reach the server. Refresh before retrying.'),
          backgroundColor: AsmTheme.statusRejected,
        ));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _load();
      }
    }
  }

  Future<String?> _textDialog({required String title, required String label, required bool required, String confirm = 'Submit'}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        String? err;
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: Text(title),
            content: TextField(controller: controller, maxLines: 3, decoration: InputDecoration(labelText: label, errorText: err)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back')),
              ElevatedButton(
                onPressed: () {
                  final v = controller.text.trim();
                  if (required && v.isEmpty) {
                    setD(() => err = 'This field is required');
                    return;
                  }
                  Navigator.pop(ctx, v);
                },
                child: Text(confirm),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _review(String action) async {
    // Admins acting outside their designated stage need a reason (server-enforced override).
    final isAdmin = AuthNotifier().isAdmin;
    final comment = await _textDialog(
      title: action == 'APPROVE' ? 'Approve Cash Advance' : 'Reject Cash Advance',
      label: action == 'APPROVE'
          ? (isAdmin ? 'Override reason (required for Admin, recorded in audit log)' : 'Comments (optional)')
          : 'Reason for rejection',
      required: action == 'REJECT' || isAdmin,
      confirm: action == 'APPROVE' ? 'Approve' : 'Reject',
    );
    if (comment == null) return;
    await _run(
      () => SupabaseService().reviewCashAdvance(advanceId: widget.advanceId, action: action, comments: comment.isEmpty ? null : comment),
      action == 'APPROVE' ? 'Advance approved.' : 'Advance rejected.',
    );
  }

  Future<void> _cancel() async {
    final reason = await _textDialog(title: 'Cancel Cash Advance Request', label: 'Cancellation reason', required: true, confirm: 'Cancel Request');
    if (reason == null) return;
    await _run(() => SupabaseService().cancelCashAdvance(advanceId: widget.advanceId, reason: reason), 'Advance request cancelled.');
  }

  Future<void> _pay() async {
    final a = _advance!;
    final refCtl = TextEditingController();
    final notesCtl = TextEditingController();
    String method = 'BANK_TRANSFER';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String? err;
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('Record Advance Disbursement'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Amount: ${MoneyUtils.format(a.aedAmountMinor)} (approved AED amount)', style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                TextField(controller: refCtl, decoration: InputDecoration(labelText: 'Bank payment reference *', errorText: err)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: method,
                  decoration: const InputDecoration(labelText: 'Payment method'),
                  items: _paymentMethods.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                  onChanged: (v) => method = v ?? method,
                ),
                const SizedBox(height: 8),
                TextField(controller: notesCtl, decoration: const InputDecoration(labelText: 'Notes (optional)')),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
              ElevatedButton(
                onPressed: () {
                  if (refCtl.text.trim().isEmpty) {
                    setD(() => err = 'Enter the bank payment reference');
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: const Text('Record Payment'),
              ),
            ],
          ),
        );
      },
    );
    if (ok != true) return;
    await _run(
      () => SupabaseService().recordCashAdvancePayment(
        advanceId: widget.advanceId,
        paymentReference: refCtl.text.trim(),
        paymentMethod: method,
        notes: notesCtl.text.trim().isEmpty ? null : notesCtl.text.trim(),
      ),
      'Advance disbursement recorded.',
    );
  }

  Future<void> _refund() async {
    final amountCtl = TextEditingController(text: MoneyUtils.formatAmount(_availableMinor).replaceAll(',', ''));
    final refCtl = TextEditingController();
    final notesCtl = TextEditingController();
    String method = 'BANK_TRANSFER';
    DateTime date = DateTime.now();
    final idempotencyKey = const Uuid().v4();
    int? amountMinor;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String? amountErr;
        String? refErr;
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('Record Unused Advance Refund'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Refundable balance: ${MoneyUtils.format(_availableMinor)}', style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                TextField(
                  controller: amountCtl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: 'Refund amount (AED) *', errorText: amountErr),
                ),
                const SizedBox(height: 8),
                TextField(controller: refCtl, decoration: InputDecoration(labelText: 'Refund reference *', errorText: refErr)),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.event_outlined, size: 16),
                  label: Text('Refund date: ${date.toIso8601String().split('T')[0]}'),
                  onPressed: () async {
                    final picked = await showDatePicker(context: ctx, initialDate: date, firstDate: DateTime(2020), lastDate: DateTime.now());
                    if (picked != null) setD(() => date = picked);
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: method,
                  decoration: const InputDecoration(labelText: 'Payment method'),
                  items: _paymentMethods.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                  onChanged: (v) => method = v ?? method,
                ),
                const SizedBox(height: 8),
                TextField(controller: notesCtl, decoration: const InputDecoration(labelText: 'Notes (optional)')),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
              ElevatedButton(
                onPressed: () {
                  amountMinor = MoneyUtils.parseMinorUnits(amountCtl.text);
                  setD(() {
                    amountErr = amountMinor == null || amountMinor! <= 0
                        ? 'Enter a positive amount with up to 2 decimals'
                        : amountMinor! > _availableMinor
                            ? 'Exceeds the refundable balance'
                            : null;
                    refErr = refCtl.text.trim().isEmpty ? 'Enter the refund reference' : null;
                  });
                  if (amountErr == null && refErr == null) Navigator.pop(ctx, true);
                },
                child: const Text('Record Refund'),
              ),
            ],
          ),
        );
      },
    );
    if (ok != true || amountMinor == null) return;
    await _run(
      () => SupabaseService().recordCashAdvanceRefund(
        advanceId: widget.advanceId,
        refundAmountMinor: amountMinor!,
        refundReference: refCtl.text.trim(),
        refundDate: date,
        paymentMethod: method,
        notes: notesCtl.text.trim().isEmpty ? null : notesCtl.text.trim(),
        idempotencyKey: idempotencyKey,
      ),
      'Refund recorded.',
    );
  }

  // --- UI -----------------------------------------------------------------
  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 13, color: AsmTheme.textSecondary)),
          const SizedBox(width: 12),
          Flexible(child: Text(value, textAlign: TextAlign.right, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w500))),
        ]),
      );

  Widget _section(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AsmTheme.textHeading)),
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cash Advance')),
        body: const SkeletonList(rows: 4, rowHeight: 88),
      );
    }
    if (_error != null || _advance == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cash Advance')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error ?? 'Cash advance not found.', textAlign: TextAlign.center, style: const TextStyle(color: AsmTheme.textSecondary)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ]),
        ),
      );
    }
    final a = _advance!;
    final lastHalt = _actions.lastWhere((x) => x['action'] == 'REJECT', orElse: () => const {});
    final stages = advanceStages(a.status, a.currentApprovalStage, haltedAtStage: lastHalt['previous_stage'] as String?);
    String fmtDate(String? iso) => iso == null ? '' : (DateTime.tryParse(iso)?.toLocal().toIso8601String().split('T')[0] ?? '');

    return Scaffold(
      appBar: AppBar(title: Text('Cash Advance ${a.advanceNumber}')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _section('Request', [
              _row('Employee', ((_owner?['full_name'] as String? ?? 'Employee')).replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim()),
              _row('Department', ((_owner?['departments'] as Map<String, dynamic>?)?['name'] as String?) ?? '-'),
              _row('Purpose', a.purpose),
              _row('Travel dates', '${a.startDate.toIso8601String().split('T')[0]} to ${a.endDate.toIso8601String().split('T')[0]}'),
              _row('Amount', MoneyUtils.format(a.amountMinor, currency: a.currencyCode), bold: true),
              if (a.currencyCode != 'AED') _row('AED equivalent', '${MoneyUtils.format(a.aedAmountMinor)} (rate ${a.exchangeRate})'),
              _row('Status', a.status.displayName),
              if (a.status == CashAdvanceStatus.underReview)
                _row('Current stage', reviewStageLabels[a.currentApprovalStage] ?? a.currentApprovalStage ?? '-'),
            ]),
            _section('Approval Timeline', [StageTimeline(stages: stages)]),
            _section('Approval History', [
              if (_actions.isEmpty) const Text('No approval actions recorded yet.', style: TextStyle(fontSize: 12, color: AsmTheme.textMuted)),
              for (final x in _actions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${x['action'] == 'APPROVE' ? 'Approved' : 'Rejected'} by ${(((x['employees'] as Map<String, dynamic>?)?['full_name'] as String? ?? 'Reviewer')).replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim()}'
                    ' at ${reviewStageLabels[x['previous_stage']] ?? x['previous_stage']} on ${fmtDate(x['created_at'] as String?)}'
                    '${(x['comments'] as String?)?.trim().isNotEmpty ?? false ? '\nComment: ${x['comments']}' : ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ]),
            if (a.status == CashAdvanceStatus.paid || a.status == CashAdvanceStatus.partiallySettled || a.status == CashAdvanceStatus.settled)
              _section('Reconciliation', [
                _row('Advance (AED)', MoneyUtils.format(a.aedAmountMinor)),
                _row('Applied to approved claims', MoneyUtils.format(a.reconciledAmountMinor)),
                _row('Reserved by claims under review', MoneyUtils.format(_reservedMinor)),
                _row('Refunded by employee', MoneyUtils.format(a.returnedAmountMinor)),
                const Divider(),
                _row('Unreconciled balance', MoneyUtils.format(_availableMinor < 0 ? 0 : _availableMinor), bold: true),
                for (final c in _claims)
                  _row('Claim #${c['claim_number']} (${ClaimStatus.fromString(c['status'] as String).displayName})',
                      MoneyUtils.format((c['advance_applied_minor'] as num?)?.toInt() ?? 0)),
                for (final r in _refunds)
                  _row('Refund ${r['refund_reference']} on ${r['refund_date']}', MoneyUtils.format((r['refund_amount_minor'] as num).toInt())),
              ]),
            if (_canReview || _canPay || _canRefund || _canCancel)
              _section('Actions', [
                if (_busy) const LinearProgressIndicator(),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (_canReview) ...[
                    OutlinedButton(onPressed: _busy ? null : () => _review('REJECT'), child: const Text('Reject')),
                    ElevatedButton(onPressed: _busy ? null : () => _review('APPROVE'), child: const Text('Approve')),
                  ],
                  if (_canPay) ElevatedButton(onPressed: _busy ? null : _pay, child: const Text('Record Disbursement')),
                  if (_canRefund) ElevatedButton(onPressed: _busy ? null : _refund, child: const Text('Record Refund')),
                  if (_canCancel) OutlinedButton(onPressed: _busy ? null : _cancel, child: const Text('Cancel Request')),
                ]),
              ]),
          ],
        ),
      ),
    );
  }
}
