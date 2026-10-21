import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../shared/models/expense.dart';
import '../../app/theme/asm_theme.dart';
import '../../shared/widgets/async_states.dart';
import '../../shared/widgets/duplicate_prompt.dart';

class CreateExpenseScreen extends StatefulWidget {
  /// When set, the screen edits this existing expense instead of creating one.
  final String? editExpenseId;

  const CreateExpenseScreen({super.key, this.editExpenseId});

  @override
  State<CreateExpenseScreen> createState() => _CreateExpenseScreenState();
}

class _CreateExpenseScreenState extends State<CreateExpenseScreen> {
  final _formKey = GlobalKey<FormState>();
  final _vendorController = TextEditingController();
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _invoiceController = TextEditingController();
  final _noReceiptReasonController = TextEditingController();

  List<ExpenseCategory> _categories = [];
  String? _selectedCategoryId;
  String _selectedCurrency = 'AED';
  DateTime _selectedDate = DateTime.now();
  bool _hasReceipt = true;
  bool _isLoading = false;
  bool _isSaving = false;
  String? _errorMessage;
  final String _idempotencyKey = const Uuid().v4();
  Expense? _editing;
  bool _editUnavailable = false;

  bool get _isEdit => widget.editExpenseId != null;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadExpenseForEdit(List<ExpenseCategory> cats) async {
    try {
      final e = await SupabaseService().getExpense(widget.editExpenseId!);
      if (e == null) {
        _editUnavailable = true;
        return;
      }
      _editing = e;
      _vendorController.text = e.vendor;
      _amountController.text = MoneyUtils.formatAmount(e.amountMinor).replaceAll(',', '');
      _descriptionController.text = e.description;
      _invoiceController.text = e.invoiceNumber ?? '';
      _noReceiptReasonController.text = e.noReceiptReason ?? '';
      _selectedCurrency = e.currencyCode;
      _selectedDate = e.expenseDate;
      _hasReceipt = e.hasReceipt;
      if (cats.any((c) => c.id == e.categoryId)) _selectedCategoryId = e.categoryId;
    } catch (_) {
      _editUnavailable = true;
    }
  }

  @override
  void dispose() {
    _vendorController.dispose();
    _amountController.dispose();
    _descriptionController.dispose();
    _invoiceController.dispose();
    _noReceiptReasonController.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    setState(() => _isLoading = true);
    final cats = await SupabaseService().getCategories();
    if (_isEdit) await _loadExpenseForEdit(cats);
    if (mounted) {
      setState(() {
        _categories = cats;
        if (cats.isNotEmpty) {
          _selectedCategoryId ??= cats.first.id;
        } else {
          _errorMessage = 'Expense categories could not be loaded. Check your connection and reopen this screen.';
        }
        _isLoading = false;
      });
    }
  }

  Future<void> _submitExpense({bool allowPossibleDuplicate = false}) async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedCategoryId == null) {
      setState(() => _errorMessage = 'Please select an expense category.');
      return;
    }

    final amountMinor = MoneyUtils.parseMinorUnits(_amountController.text);
    if (amountMinor == null || amountMinor <= 0) {
      setState(() => _errorMessage = 'Enter a positive amount with up to 2 decimals.');
      return;
    }

    // A receipt only counts once the image is attached and linked server-side.
    if (_hasReceipt && !_isEdit) {
      setState(() {
        _errorMessage = 'To claim this expense with a receipt, use Scan Receipt so the receipt image is attached. '
            'Untick the receipt option to record an expense without a receipt.';
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final invoice = _invoiceController.text.trim().isEmpty ? null : _invoiceController.text.trim();
      final Map<String, dynamic> result;
      if (_isEdit) {
        result = await SupabaseService().updateExpense(
          expenseId: _editing!.id,
          categoryId: _selectedCategoryId!,
          amountMinor: amountMinor,
          currencyCode: _selectedCurrency,
          expenseDate: _selectedDate,
          vendor: _vendorController.text.trim(),
          invoiceNumber: invoice,
          taxAmountMinor: _editing!.taxAmountMinor,
          description: _descriptionController.text.trim(),
          noReceiptReason: _hasReceipt ? null : _noReceiptReasonController.text.trim(),
          receiptTotalMinor: _hasReceipt ? amountMinor : null,
        );
      } else {
        result = await SupabaseService().createExpense(
          idempotencyKey: _idempotencyKey,
          categoryId: _selectedCategoryId!,
          amountMinor: amountMinor,
          currencyCode: _selectedCurrency,
          expenseDate: _selectedDate,
          vendor: _vendorController.text.trim(),
          invoiceNumber: invoice,
          description: _descriptionController.text.trim(),
          noReceiptReason: _noReceiptReasonController.text.trim(),
          allowPossibleDuplicate: allowPossibleDuplicate,
        );
      }

      if (result['code'] == 'POSSIBLE_DUPLICATE' && mounted) {
        setState(() => _isSaving = false);
        if (await confirmPossibleDuplicate(context, result['message'] as String? ?? '')) {
          await _submitExpense(allowPossibleDuplicate: true);
        }
        return;
      }

      if (result['success'] != true) {
        if (mounted) {
          setState(() => _errorMessage = result['message'] as String? ?? 'Failed to save expense. Please retry.');
        }
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isEdit ? 'Expense updated.' : 'Expense successfully recorded.'),
            backgroundColor: AsmTheme.statusApproved,
          ),
        );
        if (context.canPop()) {
          context.pop(true);
        } else {
          context.go(_isEdit ? '/expenses' : '/dashboard');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Could not reach the server. Check your connection and tap Save again; the expense will not be duplicated.');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = Text(_isEdit ? 'Edit Expense' : 'Record Expense');
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: title),
        body: const SkeletonList(rows: 6, rowHeight: 56),
      );
    }
    if (_isEdit && _editUnavailable) {
      return Scaffold(
        appBar: AppBar(title: title),
        body: StateMessage.error(
          title: 'Expense unavailable',
          message: 'This expense could not be loaded. It may have been deleted or you may be offline.',
          onAction: _loadCategories,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: title,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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

              // Vendor
              const Text('Vendor / Merchant Name *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              TextFormField(
                controller: _vendorController,
                decoration: const InputDecoration(hintText: 'e.g. ADNOC, Careem, Marriott'),
                validator: (val) => val == null || val.trim().isEmpty ? 'Vendor name is required' : null,
              ),
              const SizedBox(height: 16),

              // Category
              const Text('Expense Category *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _selectedCategoryId,
                items: _categories.map((c) {
                  return DropdownMenuItem(value: c.id, child: Text(c.name));
                }).toList(),
                onChanged: (val) => setState(() => _selectedCategoryId = val),
                decoration: const InputDecoration(),
              ),
              const SizedBox(height: 16),

              // Amount and Currency
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Amount *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        const SizedBox(height: 6),
                        TextFormField(
                          controller: _amountController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(hintText: '0.00'),
                          validator: (val) {
                            if (val == null || val.isEmpty) return 'Enter amount';
                            if (MoneyUtils.parseMinorUnits(val) == null) return 'Invalid amount';
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Currency', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          value: _selectedCurrency,
                          items: const [
                            DropdownMenuItem(value: 'AED', child: Text('AED')),
                            DropdownMenuItem(value: 'USD', child: Text('USD')),
                            DropdownMenuItem(value: 'EUR', child: Text('EUR')),
                          ],
                          onChanged: (val) => setState(() => _selectedCurrency = val ?? 'AED'),
                          decoration: const InputDecoration(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Expense date (future dates are rejected by the server)
              const Text('Expense Date *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text(_selectedDate.toIso8601String().split('T')[0]),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setState(() => _selectedDate = picked);
                },
              ),
              const SizedBox(height: 16),

              // Receipt status is fixed once recorded; receipts are attached via Scan Receipt.
              if (_isEdit)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_hasReceipt ? Icons.receipt_long_outlined : Icons.do_not_disturb_alt_outlined),
                  title: Text(_hasReceipt ? 'Receipt attached' : 'No receipt', style: const TextStyle(fontSize: 14)),
                  subtitle: Text(
                    _hasReceipt
                        ? 'The amount above must match the total on the attached receipt.'
                        : 'Expenses without receipt up to AED 500 are eligible upon justification.',
                    style: const TextStyle(fontSize: 12, color: AsmTheme.textSecondary),
                  ),
                )
              else
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('I have a valid receipt/invoice', style: TextStyle(fontSize: 14)),
                subtitle: const Text(
                  'Expenses without receipt up to AED 500 are eligible upon justification.',
                  style: TextStyle(fontSize: 12, color: AsmTheme.textSecondary),
                ),
                value: _hasReceipt,
                onChanged: (val) => setState(() => _hasReceipt = val ?? true),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 10),

              // No Receipt Justification
              if (!_hasReceipt) ...[
                const Text('Reason for No Receipt *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _noReceiptReasonController,
                  maxLines: 2,
                  decoration: const InputDecoration(hintText: 'Explain why a physical/tax receipt was not obtainable'),
                  validator: (val) {
                    if (!_hasReceipt && (val == null || val.trim().isEmpty)) {
                      return 'Justification reason is required when no receipt is present';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
              ],

              // Description
              const Text('Business Purpose / Description *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              TextFormField(
                controller: _descriptionController,
                maxLines: 3,
                decoration: const InputDecoration(hintText: 'Describe business context, client, or ASM vessel project reference'),
                validator: (val) => val == null || val.trim().isEmpty ? 'Description is required' : null,
              ),
              const SizedBox(height: 24),

              ElevatedButton(
                onPressed: _isSaving ? null : _submitExpense,
                child: _isSaving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                      )
                    : Text(_isEdit ? 'Save Changes' : 'Save Expense'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
