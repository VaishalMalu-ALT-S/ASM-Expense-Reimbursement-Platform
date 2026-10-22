import 'package:flutter/material.dart';
import '../../shared/widgets/async_states.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../shared/models/expense.dart';
import '../../app/theme/asm_theme.dart';

/// Creates a new claim, or - when [correctionClaimId] is set - corrects and
/// resubmits a claim that a reviewer returned for correction.
class CreateClaimScreen extends StatefulWidget {
  final String? correctionClaimId;

  const CreateClaimScreen({super.key, this.correctionClaimId});

  @override
  State<CreateClaimScreen> createState() => _CreateClaimScreenState();
}

class _CreateClaimScreenState extends State<CreateClaimScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _purposeController = TextEditingController();

  List<Expense> _availableExpenses = [];
  final Set<String> _selectedExpenseIds = {};

  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;
  String? _loadError;
  String? _claimNumber;
  String? _correctionReason;
  final String _idempotencyKey = const Uuid().v4();

  bool get _isCorrection => widget.correctionClaimId != null;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _purposeController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final service = SupabaseService();
      final expenses = (await service.getMyExpenses()).where((e) => !e.isLocked).toList();
      final limitRule = await service.client
          .from('policy_rules')
          .select('rule_value')
          .eq('rule_key', 'max_claim_limit_aed')
          .eq('is_active', true)
          .maybeSingle();
      _maxClaimMinor = ((limitRule?['rule_value'] as Map?)?['limit_minor'] as num?)?.toInt();
      final activeLinks = await service.getActiveClaimLinks(expenses.map((e) => e.id).toList());

      Map<String, dynamic>? claim;
      String? correctionReason;
      if (_isCorrection) {
        claim = await service.client
            .from('expense_claims')
            .select('claim_number, title, purpose, status, validation_notes')
            .eq('id', widget.correctionClaimId!)
            .maybeSingle();
        if (claim == null || claim['status'] != 'CORRECTION_REQUIRED') {
          if (mounted) {
            setState(() {
              _loadError = 'This claim is not awaiting correction.';
              _isLoading = false;
            });
          }
          return;
        }
        final action = await service.client
            .from('approval_actions')
            .select('comments')
            .eq('claim_id', widget.correctionClaimId!)
            .eq('action', 'REQUEST_CORRECTION')
            .order('action_timestamp', ascending: false)
            .limit(1)
            .maybeSingle();
        correctionReason = action?['comments'] as String? ?? claim['validation_notes'] as String?;
      }

      if (!mounted) return;
      setState(() {
        // Unlocked expenses that are free, or already part of the claim being corrected
        _availableExpenses = expenses
            .where((e) => !activeLinks.containsKey(e.id) || activeLinks[e.id] == widget.correctionClaimId)
            .toList();
        if (claim != null) {
          _claimNumber = claim['claim_number'] as String?;
          _correctionReason = correctionReason;
          _titleController.text = claim['title'] as String? ?? '';
          _purposeController.text = claim['purpose'] as String? ?? '';
          _selectedExpenseIds
            ..clear()
            ..addAll(activeLinks.entries.where((l) => l.value == widget.correctionClaimId).map((l) => l.key));
        }
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = 'Could not load your expenses. Check your connection and try again.';
          _isLoading = false;
        });
      }
    }
  }

  int get _selectedTotalAedMinor {
    return _availableExpenses
        .where((e) => _selectedExpenseIds.contains(e.id))
        .fold<int>(0, (sum, item) => sum + item.aedAmountMinor);
  }

  /// Configured claim ceiling (policy_rules.max_claim_limit_aed); enforced server-side.
  int? _maxClaimMinor;

  int get _netReimbursementMinor => _selectedTotalAedMinor;

  Future<void> _submitClaim() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedExpenseIds.isEmpty) {
      setState(() => _errorMessage = 'Please select at least one expense to include in this claim.');
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      // Single server transaction: attach, validate and (re)submit.
      final submitRes = _isCorrection
          ? await SupabaseService().resubmitCorrectedClaim(
              claimId: widget.correctionClaimId!,
              idempotencyKey: _idempotencyKey,
              expenseIds: _selectedExpenseIds.toList(),
              title: _titleController.text.trim(),
              purpose: _purposeController.text.trim(),
            )
          : await SupabaseService().createAndSubmitClaim(
              idempotencyKey: _idempotencyKey,
              title: _titleController.text.trim(),
              purpose: _purposeController.text.trim(),
              expenseIds: _selectedExpenseIds.toList(),
            );

      if (submitRes['success'] == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_isCorrection
                  ? 'Corrected claim resubmitted for approval.'
                  : 'Expense claim successfully validated and submitted.'),
              backgroundColor: AsmTheme.statusApproved,
            ),
          );
          if (_isCorrection) {
            context.go('/claims/${widget.correctionClaimId}');
          } else if (context.canPop()) {
            context.pop();
          } else {
            context.go('/claims');
          }
        }
      } else {
        setState(() {
          _errorMessage = submitRes['message'] as String? ?? 'Claim failed backend validation.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Could not reach the server. Check your connection and submit again; the claim will not be duplicated.');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.correctionClaimId != null ? 'Correct Claim' : 'New Claim')),
        body: const SkeletonList(rows: 5),
      );
    }

    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(_isCorrection ? 'Correct Claim' : 'New Expense Claim')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_loadError!, textAlign: TextAlign.center, style: const TextStyle(color: AsmTheme.textSecondary)),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _loadData, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isCorrection ? 'Correct Claim #${_claimNumber ?? ''}' : 'New Expense Claim'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isCorrection) ...[
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
                      const Text('Correction requested by reviewer',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AsmTheme.textPrimary)),
                      const SizedBox(height: 4),
                      Text(_correctionReason ?? 'No reason was recorded.',
                          style: const TextStyle(fontSize: 13, color: AsmTheme.textSecondary)),
                      const SizedBox(height: 6),
                      const Text(
                        'Remove or replace the affected expenses below. Record a corrected expense with Scan Receipt first if needed. '
                        'The claim restarts approval from your line manager.',
                        style: TextStyle(fontSize: 12, color: AsmTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AsmTheme.statusRejected.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AsmTheme.statusRejected.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(
                      color: AsmTheme.statusRejected,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Claim Title
              const Text('Claim Title *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(hintText: 'e.g. ADIPEC 2026 Conference Expenses'),
                validator: (val) => val == null || val.trim().isEmpty ? 'Title is required' : null,
              ),
              const SizedBox(height: 16),

              // Purpose
              const Text('Business Purpose *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              TextFormField(
                controller: _purposeController,
                maxLines: 2,
                decoration: const InputDecoration(hintText: 'Summary justification for reimbursement request'),
                validator: (val) => val == null || val.trim().isEmpty ? 'Purpose is required' : null,
              ),
              const SizedBox(height: 16),

              // Select Expenses
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Select Expenses *', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  Text(
                    '${_selectedExpenseIds.length} Selected',
                    style: const TextStyle(fontSize: 12, color: AsmTheme.primaryNavy, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              if (_availableExpenses.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Column(
                        children: [
                          const Text('No unlocked expenses available.'),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () => context.push('/expenses/new'),
                            child: const Text('Record New Expense First'),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                ..._availableExpenses.map((exp) {
                  final isSelected = _selectedExpenseIds.contains(exp.id);
                  return Card(
                    child: CheckboxListTile(
                      value: isSelected,
                      title: Text(exp.vendor, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: Text(
                        '${exp.categoryName ?? 'Expense'} • ${exp.expenseDate.toIso8601String().split('T')[0]} ${!exp.hasReceipt ? '(No Receipt)' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      secondary: Text(
                        MoneyUtils.format(exp.aedAmountMinor),
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                      ),
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedExpenseIds.add(exp.id);
                          } else {
                            _selectedExpenseIds.remove(exp.id);
                          }
                        });
                      },
                    ),
                  );
                }),

              const SizedBox(height: 20),

              if (_maxClaimMinor != null && _selectedTotalAedMinor > _maxClaimMinor!) ...[
                Text(
                  'The selected total exceeds the claim limit of ${MoneyUtils.format(_maxClaimMinor!)}. Split the expenses into separate claims.',
                  style: const TextStyle(fontSize: 12, color: AsmTheme.statusRejected, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
              ],

              // Reconciliation Summary Box
              Card(
                color: AsmTheme.primaryNavy.withValues(alpha: 0.04),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Total Claim Amount:', style: TextStyle(fontSize: 13, color: AsmTheme.textSecondary)),
                          Text(MoneyUtils.format(_selectedTotalAedMinor), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        ],
                      ),
                      const Divider(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Net Reimbursable Payable:', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AsmTheme.textPrimary)),
                          Text(MoneyUtils.format(_netReimbursementMinor), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AsmTheme.statusApproved)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              ElevatedButton(
                onPressed: _isSaving ? null : _submitClaim,
                child: _isSaving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                      )
                    : Text(_isCorrection ? 'Validate & Resubmit Claim' : 'Validate & Submit Claim'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
