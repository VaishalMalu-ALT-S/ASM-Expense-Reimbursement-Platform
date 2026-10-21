import 'package:flutter_test/flutter_test.dart';
import 'package:asm_expense/shared/models/ocr_result.dart';

void main() {
  group('OcrResult', () {
    test('FAILED response carries no receipt values', () {
      final r = OcrResult.fromJson({
        'success': false,
        'status': 'FAILED',
        'data': null,
        'message': 'The receipt could not be read automatically.',
      });
      expect(r.isFailure, isTrue);
      expect(r.vendor, isNull);
      expect(r.totalMinor, isNull);
      expect(r.date, isNull);
      expect(r.currency, isNull);
    });

    test('Values are ignored unless the server reports success', () {
      final r = OcrResult.fromJson({
        'success': false,
        'status': 'SUCCESS',
        'data': {'vendor': 'X', 'total_minor': 999},
      });
      expect(r.isFailure, isTrue);
      expect(r.totalMinor, isNull);
    });

    test('Unknown or missing status is treated as failure', () {
      expect(OcrResult.fromJson({'success': true, 'data': {'total_minor': 100}}).isFailure, isTrue);
    });

    test('PARTIAL keeps only extracted fields and reports missing ones', () {
      final r = OcrResult.fromJson({
        'success': true,
        'status': 'PARTIAL',
        'ocr_result_id': 'abc',
        'missing_fields': ['date', 'total_minor'],
        'data': {'vendor': 'ADNOC', 'total_minor': null, 'currency': 'AED', 'confidence_score': 0.7},
      });
      expect(r.status, OcrStatus.partial);
      expect(r.vendor, 'ADNOC');
      expect(r.totalMinor, isNull);
      expect(r.missingFields, ['date', 'total_minor']);
      expect(r.usedSecondaryOcr, isFalse);
    });

    test('Secondary OCR flag is read from the server response', () {
      final r = OcrResult.fromJson({
        'success': true,
        'status': 'SUCCESS',
        'fallback_used': true,
        'data': {'vendor': 'Shop', 'total_minor': 450, 'currency': 'AED', 'date': '2026-07-16'},
      });
      expect(r.usedSecondaryOcr, isTrue);
      expect(r.totalMinor, 450);
    });

    // Shape of the server result for the real ADNOC fuel receipt (identifiers altered).
    final adnoc = OcrResult.fromJson({
      'success': true,
      'status': 'PARTIAL',
      'missing_fields': ['currency'],
      'data': {
        'vendor': 'ADNOC',
        'vendor_raw': 'اد ADNOC TAX INVOTCL',
        'invoice_number': '26070000111122223333',
        'receipt_number': '30017',
        'date': '2026-07-12',
        'transaction_time': null,
        'tax_minor': 595,
        'tax_rate_percent': 5,
        'total_minor': 12505,
        'currency': null,
        'confidence_score': 0.8179,
        'uncertain_fields': ['total_minor'],
        'field_confidence': {'total_minor': 0.7051, 'date': 0.7602},
      },
    });

    test('Receipt-level fields are parsed', () {
      expect(adnoc.receiptNumber, '30017');
      expect(adnoc.taxRatePercent, 5);
      expect(adnoc.taxMinor, 595);
      expect(adnoc.totalMinor, 12505);
      expect(adnoc.date, DateTime(2026, 7, 12));
      expect(adnoc.currency, isNull);
      expect(adnoc.uncertainFields, ['total_minor']);
      expect(adnoc.fieldConfidence['total_minor'], 0.7051);
    });

    test('Field summary reports per-field status, not one overall confidence', () {
      final s = adnoc.fieldSummary();
      expect(s, contains('Read from receipt: vendor, date, VAT, invoice no., receipt no.'));
      expect(s, contains('Check carefully: total'));
      expect(s, contains('Not detected: currency'));
      expect(s, contains('Receipt no. 30017'));
      expect(s, isNot(contains('%')));
    });

    test('Undetected fields are reported, never filled', () {
      final r = OcrResult.fromJson({
        'success': true,
        'status': 'PARTIAL',
        'data': {'vendor': 'Corner Cafe', 'total_minor': 1850},
      });
      expect(r.date, isNull);
      expect(r.taxMinor, isNull);
      expect(r.invoiceNumber, isNull);
      expect(r.fieldSummary(), contains('Not detected: date, VAT, currency, invoice no., receipt no.'));
    });
  });
}
