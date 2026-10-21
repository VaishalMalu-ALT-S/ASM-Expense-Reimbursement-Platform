import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../shared/models/ocr_result.dart';

/// Reads an uploaded receipt through the `process-receipt-ocr` Edge Function.
/// OCR secrets stay server-side. Any failure is returned as
/// [OcrStatus.failed] so the employee enters the details manually.
class ReceiptExtractor {
  static const Duration _timeout = Duration(seconds: 45);

  static Future<OcrResult> extract({required String storagePath}) async {
    try {
      final res = await Supabase.instance.client.functions
          .invoke('process-receipt-ocr', body: {'receiptStoragePath': storagePath})
          .timeout(_timeout);
      final data = res.data;
      if (data is! Map) {
        return OcrResult.failed('The receipt could not be read automatically. Please enter the details manually.');
      }
      return OcrResult.fromJson(Map<String, dynamic>.from(data));
    } on TimeoutException {
      return OcrResult.failed('Reading the receipt took too long. Please enter the details manually.');
    } catch (e) {
      debugPrint('Receipt OCR unavailable: $e');
      return OcrResult.failed('Receipt reading is unavailable right now. Please enter the details manually.');
    }
  }
}
