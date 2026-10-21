enum OcrStatus { success, partial, failed }

/// Result of the server-side `process-receipt-ocr` Edge Function.
/// Every field is advisory and may be null; the employee must verify all
/// values before the expense is saved.
class OcrResult {
  final OcrStatus status;
  final String? ocrResultId;
  final String? vendor;
  final String? invoiceNumber;
  final String? receiptNumber;
  final DateTime? date;
  final String? transactionTime;
  final int? subtotalMinor;
  final int? taxMinor;
  final double? taxRatePercent;
  final int? totalMinor;
  final String? currency;
  final double? confidenceScore;
  final List<String> missingFields;

  /// Fields that were read but need particular care (e.g. a damaged amount).
  final List<String> uncertainFields;

  /// Provider confidence of the text line each field came from (absent when
  /// the provider gives none).
  final Map<String, double> fieldConfidence;
  final String message;

  /// True when the secondary OCR service produced this result.
  final bool usedSecondaryOcr;

  const OcrResult({
    required this.status,
    required this.message,
    this.ocrResultId,
    this.vendor,
    this.invoiceNumber,
    this.receiptNumber,
    this.date,
    this.transactionTime,
    this.subtotalMinor,
    this.taxMinor,
    this.taxRatePercent,
    this.totalMinor,
    this.currency,
    this.confidenceScore,
    this.missingFields = const [],
    this.uncertainFields = const [],
    this.fieldConfidence = const {},
    this.usedSecondaryOcr = false,
  });

  bool get isFailure => status == OcrStatus.failed;

  factory OcrResult.failed(String message) => OcrResult(status: OcrStatus.failed, message: message);

  factory OcrResult.fromJson(Map<String, dynamic> json) {
    final status = switch (json['status']) {
      'SUCCESS' => OcrStatus.success,
      'PARTIAL' => OcrStatus.partial,
      _ => OcrStatus.failed,
    };
    final message = json['message'] as String? ??
        'The receipt could not be read automatically. Please enter the details manually.';
    final data = json['data'];
    if (status == OcrStatus.failed || json['success'] != true || data is! Map) {
      return OcrResult.failed(message);
    }

    int? minor(Object? v) => v is int && v >= 0 ? v : null;
    final conf = data['field_confidence'];

    return OcrResult(
      status: status,
      message: message,
      ocrResultId: json['ocr_result_id'] as String?,
      vendor: data['vendor'] as String?,
      invoiceNumber: data['invoice_number'] as String?,
      receiptNumber: data['receipt_number'] as String?,
      date: data['date'] is String ? DateTime.tryParse(data['date'] as String) : null,
      transactionTime: data['transaction_time'] as String?,
      subtotalMinor: minor(data['subtotal_minor']),
      taxMinor: minor(data['tax_minor']),
      taxRatePercent: (data['tax_rate_percent'] as num?)?.toDouble(),
      totalMinor: minor(data['total_minor']),
      currency: data['currency'] as String?,
      confidenceScore: (data['confidence_score'] as num?)?.toDouble(),
      missingFields: (json['missing_fields'] as List?)?.whereType<String>().toList() ?? const [],
      uncertainFields: (data['uncertain_fields'] as List?)?.whereType<String>().toList() ?? const [],
      fieldConfidence: conf is Map
          ? {
              for (final e in conf.entries)
                if (e.key is String && e.value is num) e.key as String: (e.value as num).toDouble(),
            }
          : const {},
      usedSecondaryOcr: json['fallback_used'] == true,
    );
  }

  static const _labels = {
    'vendor': 'vendor',
    'date': 'date',
    'total_minor': 'total',
    'tax_minor': 'VAT',
    'currency': 'currency',
    'invoice_number': 'invoice no.',
    'receipt_number': 'receipt no.',
  };

  /// Per-field status for the employee: read, needs a careful check, or not
  /// detected. No single overall confidence is shown for all fields.
  String fieldSummary() {
    final present = <String, bool>{
      'vendor': vendor != null,
      'date': date != null,
      'total_minor': totalMinor != null,
      'tax_minor': taxMinor != null,
      'currency': currency != null,
      'invoice_number': invoiceNumber != null,
      'receipt_number': receiptNumber != null,
    };
    final read = [for (final k in _labels.keys) if (present[k]! && !uncertainFields.contains(k)) _labels[k]!];
    final check = [for (final k in _labels.keys) if (present[k]! && uncertainFields.contains(k)) _labels[k]!];
    final missing = [for (final k in _labels.keys) if (!present[k]!) _labels[k]!];
    final parts = <String>[
      if (read.isNotEmpty) 'Read from receipt: ${read.join(', ')}.',
      if (check.isNotEmpty) 'Check carefully: ${check.join(', ')} (the printed value was partly unclear).',
      if (missing.isNotEmpty) 'Not detected: ${missing.join(', ')}.',
      if (receiptNumber != null) 'Receipt no. $receiptNumber.',
      'Verify every field against the receipt before saving.',
    ];
    return parts.join(' ');
  }
}
