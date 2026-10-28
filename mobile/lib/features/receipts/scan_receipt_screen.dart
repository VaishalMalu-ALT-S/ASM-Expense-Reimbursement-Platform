import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../core/network/supabase_service.dart';
import '../../core/utils/money_utils.dart';
import '../../shared/models/expense.dart';
import '../../shared/models/currency_item.dart';
import '../../shared/widgets/currency_picker_modal.dart';
import '../../shared/widgets/duplicate_prompt.dart';
import '../../core/services/receipt_extractor.dart';
import '../../app/theme/asm_theme.dart';

class ScanReceiptScreen extends StatefulWidget {
  const ScanReceiptScreen({super.key});

  @override
  State<ScanReceiptScreen> createState() => _ScanReceiptScreenState();
}

class _ScanReceiptScreenState extends State<ScanReceiptScreen> {
  final _picker = ImagePicker();
  Uint8List? _imageBytes;
  bool _isProcessing = false;
  bool _isSaving = false;
  String? _statusMessage;
  String? _errorMessage;

  // Receipt linked to this expense on save; a new image starts a new request
  String? _receiptStoragePath;
  String? _receiptFileName;
  String _idempotencyKey = const Uuid().v4();

  // Extracted/Verified Form Fields
  final _vendorController = TextEditingController();
  final _amountController = TextEditingController();
  final _invoiceController = TextEditingController();
  final _taxController = TextEditingController();
  final _descriptionController = TextEditingController();

  List<ExpenseCategory> _categories = [];
  List<CurrencyItem> _currencies = [];
  String? _selectedCategoryId;
  // Undetected values stay empty until the employee enters them; nothing defaults to today or AED.
  String? _selectedCurrency;
  DateTime? _selectedDate;
  bool _ocrRan = false;
  bool _verified = false;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  @override
  void dispose() {
    _vendorController.dispose();
    _amountController.dispose();
    _invoiceController.dispose();
    _taxController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final service = SupabaseService();
    final cats = await service.getCategories();
    final currs = await service.getCurrencies();
    if (mounted) {
      setState(() {
        _categories = cats;
        _currencies = currs;
        if (cats.isEmpty) {
          _errorMessage = 'Expense categories could not be loaded. Check your connection and reopen this screen.';
        }
      });
    }
  }

  /// Auto-detect the best matching category based on vendor name
  String? _detectCategoryForVendor(String? vendor) {
    if (vendor == null || vendor.isEmpty || _categories.isEmpty) return null;
    final v = vendor.toLowerCase();

    // Food & Dining
    if (v.contains('starbucks') || v.contains('coffee') || v.contains('costa') ||
        v.contains('madeena') || v.contains('restaurant') || v.contains('cafe') ||
        v.contains('food') || v.contains('meal') || v.contains('dining') ||
        v.contains('supermarket') || v.contains('grocery') || v.contains('kitchen')) {
      return _findCategoryId('FOOD_DINING');
    }
    // Fuel & Mileage
    if (v.contains('adnoc') || v.contains('enoc') || v.contains('fuel') ||
        v.contains('petrol') || v.contains('gas station') || v.contains('emarat')) {
      return _findCategoryId('FUEL_MILEAGE');
    }
    // Taxi & Rideshare
    if (v.contains('careem') || v.contains('uber') || v.contains('taxi') ||
        v.contains('cab') || v.contains('rideshare')) {
      return _findCategoryId('TAXI_RIDESHARE');
    }
    // Hotel & Accommodation
    if (v.contains('hotel') || v.contains('marriott') || v.contains('hilton') ||
        v.contains('rotana') || v.contains('novotel') || v.contains('radisson') ||
        v.contains('inn') || v.contains('lodge') || v.contains('resort')) {
      return _findCategoryId('HOTEL_LODGING');
    }
    // Travel & Airfare
    if (v.contains('airline') || v.contains('airways') || v.contains('air ') ||
        v.contains('etihad') || v.contains('emirates') || v.contains('flydubai') ||
        v.contains('flight') || v.contains('ticket')) {
      return _findCategoryId('TRAVEL_AIRFARE');
    }
    // Parking & Tolls
    if (v.contains('parking') || v.contains('salik') || v.contains('toll') ||
        v.contains('mawaqif')) {
      return _findCategoryId('PARKING_TOLLS');
    }
    // Telecommunications
    if (v.contains('etisalat') || v.contains('du ') || v.contains('telecom') ||
        v.contains('mobile') || v.contains('sim') || v.contains('roaming')) {
      return _findCategoryId('COMMUNICATIONS');
    }
    // Office & Supplies
    if (v.contains('office') || v.contains('stationery') || v.contains('supplies') ||
        v.contains('printing') || v.contains('paper')) {
      return _findCategoryId('OFFICE_SUPPLIES');
    }
    return null;
  }

  String? _findCategoryId(String code) {
    for (final c in _categories) {
      if (c.code == code) return c.id;
    }
    return null;
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (picked != null) {
        var bytes = await picked.readAsBytes();
        var mimeType = _detectImageMimeType(bytes);
        if (mimeType == null) {
          setState(() => _errorMessage = 'Unsupported or empty file. Please use a JPEG, PNG, WEBP or HEIC image of the receipt.');
          return;
        }

        // Bake EXIF orientation so sideways camera shots are upright for OCR & cloud AI
        try {
          final normalized = await compute(_normalizeOrientation, bytes);
          if (normalized != null && normalized.isNotEmpty) {
            bytes = normalized;
            mimeType = 'image/jpeg';
          }
        } catch (orientErr) {
          debugPrint('Image orientation normalization fallback: $orientErr');
        }

        _resetReceiptForm();
        setState(() {
          _imageBytes = bytes;
          _errorMessage = null;
        });
        _processOcr(bytes, picked.name, mimeType ?? 'image/jpeg');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Could not access image or camera.');
    }
  }

  /// Runs in a background isolate to decode EXIF tags, bake orientation upright,
  /// and re-encode to clean JPEG.
  static Uint8List? _normalizeOrientation(Uint8List rawBytes) {
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) return null;
    final upright = img.bakeOrientation(decoded);
    return Uint8List.fromList(img.encodeJpg(upright, quality: 88));
  }

  /// Identifies the image type from its leading bytes; null if unsupported.
  String? _detectImageMimeType(Uint8List b) {
    if (b.length < 12) return null;
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
    if (String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' && String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') return 'image/webp';
    if (String.fromCharCodes(b.sublist(4, 8)) == 'ftyp') {
      final brand = String.fromCharCodes(b.sublist(8, 12));
      if (const ['heic', 'heix', 'hevc', 'mif1', 'msf1'].contains(brand)) return 'image/heic';
    }
    return null;
  }

  /// Clears values from any previous receipt so they cannot carry over.
  void _resetReceiptForm() {
    _receiptStoragePath = null;
    _receiptFileName = null;
    _idempotencyKey = const Uuid().v4();
    _vendorController.clear();
    _amountController.clear();
    _invoiceController.clear();
    _taxController.clear();
    _selectedCurrency = null;
    _selectedDate = null;
    _selectedCategoryId = null;
    _ocrRan = false;
    _verified = false;
    _statusMessage = null;
  }

  void _openImagePreview() {
    if (_imageBytes == null) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white24),
              ),
              padding: const EdgeInsets.all(8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: InteractiveViewer(
                  panEnabled: true,
                  minScale: 0.5,
                  maxScale: 5.0,
                  child: Image.memory(_imageBytes!, fit: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: CircleAvatar(
                backgroundColor: Colors.black.withValues(alpha: 0.75),
                radius: 18,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 18),
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.of(ctx).pop(),
                  tooltip: 'Close preview',
                ),
              ),
            ),
            Positioned(
              bottom: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.pinch_outlined, color: Colors.white70, size: 14),
                    SizedBox(width: 6),
                    Text(
                      'Pinch or scroll to zoom in/out',
                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _processOcr(Uint8List bytes, String fileName, String mimeType) async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Uploading receipt securely to private storage...';
    });

    try {
      final uid = SupabaseService().currentUserId;
      if (uid == null) {
        setState(() => _errorMessage = 'Your session has expired. Please sign in again.');
        return;
      }

      final ext = mimeType.split('/').last == 'jpeg' ? 'jpg' : mimeType.split('/').last;
      final storagePath = '$uid/receipts/${const Uuid().v4()}.$ext';

      try {
        await SupabaseService().client.storage.from('receipts').uploadBinary(
              storagePath,
              bytes,
              fileOptions: FileOptions(contentType: mimeType, upsert: false),
            );
      } catch (uploadErr) {
        debugPrint('Receipt upload failed: $uploadErr');
        if (mounted) {
          setState(() {
            _statusMessage = null;
            _errorMessage = 'Receipt upload failed. Check your connection and select the image again.';
          });
        }
        return;
      }

      if (!mounted) return;
      _receiptStoragePath = storagePath;
      _receiptFileName = fileName;
      setState(() => _statusMessage = 'Reading receipt details...');

      final ocr = await ReceiptExtractor.extract(storagePath: storagePath);
      if (!mounted) return;

      setState(() {
        _ocrRan = true;
        if (ocr.isFailure) {
          _statusMessage = 'Receipt attached. ${ocr.message}';
          return;
        }

        if (ocr.vendor != null && ocr.vendor!.isNotEmpty) {
          _vendorController.text = ocr.vendor!;
        }
        if (ocr.invoiceNumber != null && ocr.invoiceNumber!.isNotEmpty) {
          _invoiceController.text = ocr.invoiceNumber!;
        }
        if (ocr.currency != null && ocr.currency!.isNotEmpty) {
          final detected = ocr.currency!.trim().toUpperCase();
          _selectedCurrency = detected;
          if (!_currencies.any((c) => c.code == detected)) {
            _currencies.add(CurrencyItem(code: detected, name: detected, symbol: detected));
          }
        } else {
          _selectedCurrency ??= 'AED';
        }
        if (ocr.totalMinor != null && ocr.totalMinor! > 0) {
          _amountController.text = MoneyUtils.formatAmount(ocr.totalMinor!).replaceAll(',', '');
        }
        if (ocr.taxMinor != null) {
          _taxController.text = MoneyUtils.formatAmount(ocr.taxMinor!).replaceAll(',', '');
        } else {
          _taxController.text = '0.00';
        }
        if (ocr.date != null && !ocr.date!.isAfter(DateTime.now())) {
          _selectedDate = ocr.date!;
        } else if (_selectedDate == null && _invoiceController.text.isNotEmpty) {
          final cleanInv = _invoiceController.text.replaceAll(RegExp(r'\D'), '');
          final m6 = RegExp(r'^(\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])').firstMatch(cleanInv);
          if (m6 != null) {
            final yy = int.parse(m6.group(1)!);
            final year = yy < 50 ? 2000 + yy : 1900 + yy;
            final month = int.parse(m6.group(2)!);
            final day = int.parse(m6.group(3)!);
            final inferredDate = DateTime(year, month, day);
            if (!inferredDate.isAfter(DateTime.now())) {
              _selectedDate = inferredDate;
            }
          }
        }

        final detectedCategoryId = _detectCategoryForVendor(ocr.vendor);
        if (detectedCategoryId != null) {
          _selectedCategoryId = detectedCategoryId;
        }

        _statusMessage = ocr.fieldSummary();
        if (ocr.usedSecondaryOcr) {
          _statusMessage = '${_statusMessage!} Receipt text was extracted using the secondary OCR service. Please verify the extracted values.';
        }
      });
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _saveVerifiedExpense({bool allowPossibleDuplicate = false}) async {
    if (_receiptStoragePath == null) {
      setState(() => _errorMessage = 'Attach a receipt image first. Use Record Expense for expenses without a receipt.');
      return;
    }
    final amountMinor = MoneyUtils.parseMinorUnits(_amountController.text);
    if (amountMinor == null || amountMinor <= 0) {
      setState(() => _errorMessage = 'Enter the receipt total as a positive amount with up to 2 decimals.');
      return;
    }
    // An empty VAT field, 0, -, none, or 'no tax' means zero VAT on the receipt.
    final taxText = _taxController.text.trim().toLowerCase();
    final isZeroOrNoTax = taxText.isEmpty ||
        taxText == '0' ||
        taxText == '0.00' ||
        taxText == '-' ||
        taxText == '--' ||
        taxText == 'none' ||
        taxText == 'null' ||
        taxText == 'nil' ||
        taxText == 'n/a' ||
        taxText == 'na' ||
        taxText.contains('no');
    final taxAmountMinor = isZeroOrNoTax ? 0 : (MoneyUtils.parseMinorUnits(taxText) ?? 0);
    if (_selectedCurrency == null) {
      setState(() => _errorMessage = 'Select the currency shown on the receipt.');
      return;
    }
    final expenseDate = _selectedDate;
    if (expenseDate == null) {
      setState(() => _errorMessage = 'Select the date printed on the receipt.');
      return;
    }
    if (!_verified) {
      setState(() => _errorMessage = 'Confirm that you checked the total, date, currency and VAT against the receipt.');
      return;
    }
    if (_vendorController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Vendor name is required.');
      return;
    }
    if (_selectedCategoryId == null) {
      setState(() => _errorMessage = 'Please select a category.');
      return;
    }

    // Verify exchange rate availability from server before submission
    if (_selectedCurrency != 'AED') {
      final rate = await SupabaseService().getExchangeRateToAed(_selectedCurrency!, expenseDate);
      if (rate == null || rate <= 0) {
        setState(() {
          _errorMessage = 'No exchange rate to AED is configured for $_selectedCurrency on '
              '${expenseDate.toIso8601String().split('T')[0]}. Please contact Finance.';
        });
        return;
      }
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final result = await SupabaseService().createExpense(
        idempotencyKey: _idempotencyKey,
        categoryId: _selectedCategoryId!,
        amountMinor: amountMinor,
        currencyCode: _selectedCurrency!,
        expenseDate: expenseDate,
        vendor: _vendorController.text.trim(),
        invoiceNumber: _invoiceController.text.trim().isEmpty ? null : _invoiceController.text.trim(),
        taxAmountMinor: taxAmountMinor,
        description: _descriptionController.text.trim().isEmpty ? 'Receipt scanned expense' : _descriptionController.text.trim(),
        receiptStoragePath: _receiptStoragePath,
        receiptFileName: _receiptFileName,
        receiptTotalMinor: amountMinor,
        allowPossibleDuplicate: allowPossibleDuplicate,
      );

      if (result['code'] == 'POSSIBLE_DUPLICATE' && mounted) {
        setState(() => _isSaving = false);
        if (await confirmPossibleDuplicate(context, result['message'] as String? ?? '')) {
          await _saveVerifiedExpense(allowPossibleDuplicate: true);
        }
        return;
      }

      if (result['success'] != true) {
        if (mounted) {
          setState(() => _errorMessage = result['message'] as String? ?? 'Expense could not be saved. Please review and try again.');
        }
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Expense verified and recorded successfully.'),
            backgroundColor: AsmTheme.statusApproved,
          ),
        );
        context.go('/expenses');
      }
    } catch (e) {
      debugPrint('Save verified expense failed: $e');
      if (mounted) {
        setState(() => _errorMessage = 'Could not reach the server. Check your connection and tap Save again; the expense will not be duplicated.');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan & Verify Receipt'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
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
                  style: const TextStyle(color: AsmTheme.statusRejected, fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Image Preview & Capture Buttons
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    if (_imageBytes != null)
                      GestureDetector(
                        onTap: _openImagePreview,
                        child: Stack(
                          children: [
                            Container(
                              height: 300,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F172A),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: AsmTheme.borderMedium),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.memory(_imageBytes!, fit: BoxFit.contain),
                              ),
                            ),
                            Positioned(
                              top: 8,
                              right: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.75),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: Colors.white24),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.zoom_in, color: Colors.white, size: 16),
                                    SizedBox(width: 4),
                                    Text(
                                      'Full Preview & Zoom',
                                      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Container(
                        height: 160,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: AsmTheme.surfaceLight,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AsmTheme.borderMedium, style: BorderStyle.solid),
                        ),
                        child: const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.document_scanner_outlined, size: 48, color: AsmTheme.textMuted),
                              SizedBox(height: 8),
                              Text('No receipt image selected', style: TextStyle(color: AsmTheme.textSecondary, fontSize: 13)),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 14),

                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.camera_alt_outlined, size: 18),
                            label: const Text('Camera'),
                            onPressed: _isProcessing ? null : () => _pickImage(ImageSource.camera),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.photo_library_outlined, size: 18),
                            label: const Text('Gallery'),
                            onPressed: _isProcessing ? null : () => _pickImage(ImageSource.gallery),
                          ),
                        ),
                      ],
                    ),

                    if (_statusMessage != null) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          if (_isProcessing) ...[
                            const SizedBox(
                              height: 14,
                              width: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              _statusMessage!,
                              style: const TextStyle(fontSize: 12, color: AsmTheme.primaryNavy, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Mandatory Employee Verification Section
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Employee Verification (Mandatory)',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AsmTheme.textPrimary),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'OCR is an assistant. Please check each field against your receipt before saving.',
                        style: TextStyle(fontSize: 12, color: AsmTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (_imageBytes != null)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.fullscreen, size: 16),
                    label: const Text('Preview Receipt', style: TextStyle(fontSize: 12)),
                    onPressed: _openImagePreview,
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Vendor
            const Text('Vendor Name *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _vendorController,
              decoration: const InputDecoration(hintText: 'Extracted merchant name'),
            ),
            const SizedBox(height: 14),

            // Category (Full width with isExpanded to prevent overflow)
            const Text('Category *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: _selectedCategoryId,
              isExpanded: true,
              hint: const Text('Select category'),
              items: _categories
                  .map((c) => DropdownMenuItem(
                        value: c.id,
                        child: Text(c.name, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (val) => setState(() => _selectedCategoryId = val),
              decoration: const InputDecoration(),
            ),
            const SizedBox(height: 14),

            // Invoice Number (Full width for long invoice numbers)
            const Text('Invoice Number (Optional)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _invoiceController,
              decoration: InputDecoration(
                hintText: _ocrRan ? 'Not on receipt (optional)' : 'As printed on receipt (optional)',
              ),
            ),
            const SizedBox(height: 14),

            // Total Amount & Currency
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Total Amount *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _amountController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(hintText: '0.00'),
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
                      const Text('Currency *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: () async {
                          final chosen = await CurrencyPickerModal.show(
                            context,
                            currencies: _currencies,
                            selectedCurrencyCode: _selectedCurrency,
                          );
                          if (chosen != null) {
                            setState(() {
                              _selectedCurrency = chosen.code;
                              if (!_currencies.any((c) => c.code == chosen.code)) {
                                _currencies.add(chosen);
                              }
                            });
                          }
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                            suffixIcon: Icon(Icons.arrow_drop_down, size: 22),
                          ),
                          child: Text(
                            _selectedCurrency ?? 'Select',
                            style: TextStyle(
                              fontWeight: _selectedCurrency != null ? FontWeight.w700 : FontWeight.w400,
                              fontSize: 14,
                              color: _selectedCurrency != null ? AsmTheme.textPrimary : AsmTheme.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Tax Amount & Date
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Tax / VAT (Optional)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _taxController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          hintText: '0.00 (optional)',
                          suffixIcon: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                InkWell(
                                  onTap: () => setState(() {
                                    if (_taxController.text.trim() == '0.00') {
                                      _taxController.clear();
                                    } else {
                                      _taxController.text = '0.00';
                                    }
                                  }),
                                  borderRadius: BorderRadius.circular(4),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: _taxController.text.trim() == '0.00'
                                          ? AsmTheme.primaryNavy.withValues(alpha: 0.08)
                                          : const Color(0xFFF1F5F9),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: _taxController.text.trim() == '0.00'
                                            ? AsmTheme.primaryNavy.withValues(alpha: 0.4)
                                            : const Color(0xFFCBD5E1),
                                        width: 0.8,
                                      ),
                                    ),
                                    child: Text(
                                      _taxController.text.trim() == '0.00' ? 'No Tax ✓' : 'No Tax',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: _taxController.text.trim() == '0.00'
                                            ? AsmTheme.primaryNavy
                                            : const Color(0xFF475569),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Receipt Date *', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 6),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _selectedDate ?? DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) setState(() => _selectedDate = picked);
                        },
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(_selectedDate?.toIso8601String().split('T')[0] ?? (_ocrRan ? 'Not detected' : 'Select date')),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Description
            const Text('Business Purpose / Notes (Optional)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(hintText: 'Client meeting, project reference, or remarks (optional)'),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _verified,
              onChanged: (v) => setState(() => _verified = v ?? false),
              title: const Text('I checked the total, date, currency and VAT against the receipt',
                  style: TextStyle(fontSize: 13)),
            ),
            const SizedBox(height: 12),

            // Confirm & Save Button
            ElevatedButton(
              onPressed: (_isProcessing || _isSaving) ? null : _saveVerifiedExpense,
              child: _isSaving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                    )
                  : const Text('Confirm & Save Verified Expense'),
            ),
          ],
        ),
      ),
    );
  }
}
