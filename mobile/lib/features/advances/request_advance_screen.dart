import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../app/theme/asm_theme.dart';

class RequestAdvanceScreen extends StatefulWidget {
  const RequestAdvanceScreen({super.key});

  @override
  State<RequestAdvanceScreen> createState() => _RequestAdvanceScreenState();
}

class _RequestAdvanceScreenState extends State<RequestAdvanceScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _purposeController = TextEditingController();

  String _selectedCurrency = 'AED';
  DateTime _startDate = DateTime.now();
  DateTime _endDate = DateTime.now().add(const Duration(days: 3));
  bool _isSaving = false;
  String? _errorMessage;
  final String _idempotencyKey = const Uuid().v4();

  @override
  void dispose() {
    _amountController.dispose();
    _purposeController.dispose();
    super.dispose();
  }

  Future<void> _submitAdvance() async {
    if (!_formKey.currentState!.validate()) return;

    final amountMinor = MoneyUtils.parseMinorUnits(_amountController.text);
    if (amountMinor == null || amountMinor <= 0) {
      setState(() => _errorMessage = 'Enter a positive amount with up to 2 decimals.');
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final res = await SupabaseService().createCashAdvance(
        idempotencyKey: _idempotencyKey,
        amountMinor: amountMinor,
        currencyCode: _selectedCurrency,
        purpose: _purposeController.text.trim(),
        startDate: _startDate,
        endDate: _endDate,
      );

      if (res['success'] != true) {
        if (mounted) setState(() => _errorMessage = res['message'] as String? ?? 'Cash advance request could not be submitted.');
        return;
      }

      if (mounted) {
        final aed = (res['aed_amount_minor'] as num?)?.toInt();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cash advance ${res['advance_number'] ?? ''} submitted for review'
                '${aed != null && _selectedCurrency != 'AED' ? ' (AED equivalent ${MoneyUtils.format(aed)})' : ''}.'),
            backgroundColor: AsmTheme.statusApproved,
          ),
        );
        context.go('/advances/${res['advance_id']}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Could not reach the server. Check your connection and submit again; the request will not be duplicated.');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Request Cash Advance'),
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

              // Amount & Currency
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Advance Amount *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
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

              // Date Range
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Start Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        const SizedBox(height: 6),
                        OutlinedButton(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _startDate,
                              firstDate: DateTime.now().subtract(const Duration(days: 30)),
                              lastDate: DateTime.now().add(const Duration(days: 365)),
                            );
                            if (picked != null) setState(() => _startDate = picked);
                          },
                          child: Text(_startDate.toIso8601String().split('T')[0]),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('End Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        const SizedBox(height: 6),
                        OutlinedButton(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _endDate,
                              firstDate: _startDate,
                              lastDate: DateTime.now().add(const Duration(days: 365)),
                            );
                            if (picked != null) setState(() => _endDate = picked);
                          },
                          child: Text(_endDate.toIso8601String().split('T')[0]),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Business Purpose
              const Text('Business / Travel Purpose *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 6),
              TextFormField(
                controller: _purposeController,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Specify project, trip itinerary, expected expenditure categories, or client details',
                ),
                validator: (val) => val == null || val.trim().isEmpty ? 'Purpose is required' : null,
              ),
              const SizedBox(height: 24),

              ElevatedButton(
                onPressed: _isSaving ? null : _submitAdvance,
                child: _isSaving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                      )
                    : const Text('Submit Cash Advance Request'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
