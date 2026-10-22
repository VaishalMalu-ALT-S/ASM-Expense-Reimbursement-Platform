import 'package:flutter/material.dart';
import '../../app/theme/asm_theme.dart';
import '../../core/network/supabase_service.dart';
import '../../shared/models/currency_item.dart';

/// Reusable searchable currency picker modal adhering to ASM design system.
/// Supports common international currencies, dynamic database currencies,
/// quick search, and adding custom currencies.
class CurrencyPickerModal extends StatefulWidget {
  final List<CurrencyItem> initialCurrencies;
  final String? selectedCurrencyCode;
  final ValueChanged<CurrencyItem> onSelected;

  const CurrencyPickerModal({
    super.key,
    required this.initialCurrencies,
    this.selectedCurrencyCode,
    required this.onSelected,
  });

  static Future<CurrencyItem?> show(
    BuildContext context, {
    required List<CurrencyItem> currencies,
    String? selectedCurrencyCode,
  }) {
    return showModalBottomSheet<CurrencyItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => CurrencyPickerModal(
        initialCurrencies: currencies,
        selectedCurrencyCode: selectedCurrencyCode,
        onSelected: (curr) => Navigator.of(ctx).pop(curr),
      ),
    );
  }

  @override
  State<CurrencyPickerModal> createState() => _CurrencyPickerModalState();
}

class _CurrencyPickerModalState extends State<CurrencyPickerModal> {
  final _searchController = TextEditingController();
  late List<CurrencyItem> _allCurrencies;
  String _searchQuery = '';
  bool _isCreatingCustom = false;

  // Custom currency form controllers
  final _customCodeController = TextEditingController();
  final _customNameController = TextEditingController();
  final _customSymbolController = TextEditingController();
  final _customFormKey = GlobalKey<FormState>();
  bool _isSavingCustom = false;
  String? _customError;

  @override
  void initState() {
    super.initState();
    _allCurrencies = List.from(widget.initialCurrencies);
    _ensureDefaults();
  }

  void _ensureDefaults() {
    // Ensure priority currencies are present
    const defaults = [
      CurrencyItem(code: 'AED', name: 'United Arab Emirates Dirham', symbol: 'AED'),
      CurrencyItem(code: 'USD', name: 'United States Dollar', symbol: r'$'),
      CurrencyItem(code: 'EUR', name: 'Euro', symbol: '€'),
      CurrencyItem(code: 'GBP', name: 'British Pound', symbol: '£'),
      CurrencyItem(code: 'INR', name: 'Indian Rupee', symbol: '₹'),
      CurrencyItem(code: 'SAR', name: 'Saudi Riyal', symbol: 'SAR'),
      CurrencyItem(code: 'QAR', name: 'Qatari Riyal', symbol: 'QAR'),
      CurrencyItem(code: 'OMR', name: 'Omani Rial', symbol: 'OMR'),
      CurrencyItem(code: 'BHD', name: 'Bahraini Dinar', symbol: 'BHD', decimals: 3),
      CurrencyItem(code: 'KWD', name: 'Kuwaiti Dinar', symbol: 'KWD', decimals: 3),
      CurrencyItem(code: 'SGD', name: 'Singapore Dollar', symbol: r'S$'),
      CurrencyItem(code: 'JPY', name: 'Japanese Yen', symbol: '¥', decimals: 0),
    ];

    for (final d in defaults) {
      if (!_allCurrencies.any((c) => c.code == d.code)) {
        _allCurrencies.add(d);
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _customCodeController.dispose();
    _customNameController.dispose();
    _customSymbolController.dispose();
    super.dispose();
  }

  List<CurrencyItem> get _filteredCurrencies {
    if (_searchQuery.trim().isEmpty) return _allCurrencies;
    final q = _searchQuery.trim().toLowerCase();
    return _allCurrencies.where((c) {
      return c.code.toLowerCase().contains(q) ||
          c.name.toLowerCase().contains(q) ||
          c.symbol.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _saveCustomCurrency() async {
    if (!_customFormKey.currentState!.validate()) return;
    setState(() {
      _isSavingCustom = true;
      _customError = null;
    });

    final code = _customCodeController.text.trim().toUpperCase();
    final name = _customNameController.text.trim();
    final symbol = _customSymbolController.text.trim().isEmpty ? code : _customSymbolController.text.trim();

    try {
      final res = await SupabaseService().registerCustomCurrency(
        code: code,
        name: name,
        symbol: symbol,
      );

      if (res['success'] == true && res['currency'] != null) {
        final newCurr = res['currency'] as CurrencyItem;
        widget.onSelected(newCurr);
      } else {
        // Fallback local currency if network registration fails
        final fallback = CurrencyItem(code: code, name: name, symbol: symbol);
        widget.onSelected(fallback);
      }
    } catch (e) {
      final fallback = CurrencyItem(code: code, name: name, symbol: symbol);
      widget.onSelected(fallback);
    } finally {
      if (mounted) setState(() => _isSavingCustom = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      margin: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _isCreatingCustom ? 'Add Custom Currency' : 'Select Currency',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AsmTheme.textPrimary,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isCreatingCustom = !_isCreatingCustom;
                      _customError = null;
                    });
                  },
                  child: Text(
                    _isCreatingCustom ? 'Cancel' : '+ Custom Currency',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          if (_isCreatingCustom)
            _buildCustomCurrencyForm()
          else ...[
            // Search field
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search by currency, name, or symbol...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                ),
                onChanged: (val) => setState(() => _searchQuery = val),
              ),
            ),

            // Currency list
            Flexible(
              child: _filteredCurrencies.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'No matching currencies found.',
                              style: TextStyle(color: AsmTheme.textSecondary),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('Add as Custom Currency'),
                              onPressed: () {
                                setState(() {
                                  _isCreatingCustom = true;
                                  if (_searchQuery.trim().length == 3 &&
                                      RegExp(r'^[A-Za-z]{3}$').hasMatch(_searchQuery.trim())) {
                                    _customCodeController.text = _searchQuery.trim().toUpperCase();
                                  }
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: _filteredCurrencies.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final c = _filteredCurrencies[index];
                        final isSelected = widget.selectedCurrencyCode == c.code;

                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                          leading: Container(
                            width: 44,
                            height: 34,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AsmTheme.primaryNavy
                                  : AsmTheme.primaryNavy.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              c.symbol,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: isSelected ? Colors.white : AsmTheme.primaryNavy,
                              ),
                            ),
                          ),
                          title: Text(
                            c.code,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          subtitle: Text(
                            c.name,
                            style: const TextStyle(fontSize: 12, color: AsmTheme.textSecondary),
                          ),
                          trailing: isSelected
                              ? const Icon(Icons.check_circle, color: AsmTheme.statusApproved, size: 20)
                              : null,
                          onTap: () => widget.onSelected(c),
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCustomCurrencyForm() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _customFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Enter the custom currency details below. Server exchange rate lookup will be performed on verification.',
              style: TextStyle(fontSize: 12, color: AsmTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            if (_customError != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AsmTheme.statusRejected.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AsmTheme.statusRejected.withValues(alpha: 0.3)),
                ),
                child: Text(
                  _customError!,
                  style: const TextStyle(color: AsmTheme.statusRejected, fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
            ],
            // 3-letter ISO code
            const Text('ISO Currency Code * (e.g. CAD, SGD, KWD)',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            TextFormField(
              controller: _customCodeController,
              textCapitalization: TextCapitalization.characters,
              maxLength: 3,
              decoration: const InputDecoration(
                hintText: 'e.g. CAD',
                counterText: '',
              ),
              validator: (val) {
                if (val == null || val.trim().length != 3) {
                  return 'Code must be exactly 3 uppercase letters (ISO 4217)';
                }
                if (!RegExp(r'^[A-Za-z]{3}$').hasMatch(val.trim())) {
                  return 'Code must contain alphabets only';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),

            // Currency Name
            const Text('Currency Name *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            TextFormField(
              controller: _customNameController,
              decoration: const InputDecoration(hintText: 'e.g. Canadian Dollar'),
              validator: (val) => val == null || val.trim().length < 2 ? 'Name is required' : null,
            ),
            const SizedBox(height: 14),

            // Currency Symbol
            const Text(r'Currency Symbol (e.g. $, £, ₹, or code)',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            TextFormField(
              controller: _customSymbolController,
              decoration: const InputDecoration(hintText: r'e.g. CA$ or $'),
            ),
            const SizedBox(height: 20),

            ElevatedButton(
              onPressed: _isSavingCustom ? null : _saveCustomCurrency,
              child: _isSavingCustom
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                    )
                  : const Text('Add & Select Currency'),
            ),
          ],
        ),
      ),
    );
  }
}
