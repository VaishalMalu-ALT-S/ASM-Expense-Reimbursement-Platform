import 'package:intl/intl.dart';

/// Centralized Financial & Currency Mathematics
/// Strictly operates in integer minor units (e.g. fils, cents) to guarantee precision.
class MoneyUtils {
  /// Converts decimal float or double input safely to integer minor units (cents/fils)
  static int toMinorUnits(double amount, [int decimals = 2]) {
    final factor = _pow10(decimals);
    return (amount * factor).round();
  }

  /// Parses user-entered decimal text (e.g. "1,250.50") into integer minor
  /// units without floating-point arithmetic. Returns null for invalid input.
  static int? parseMinorUnits(String input, [int decimals = 2]) {
    final text = input.trim().replaceAll(',', '');
    final pattern = decimals > 0 ? '^(\\d{1,12})(?:\\.(\\d{1,$decimals}))?\$' : '^(\\d{1,12})\$';
    final match = RegExp(pattern).firstMatch(text);
    if (match == null) return null;
    final whole = int.parse(match.group(1)!);
    final fraction = decimals > 0 ? (match.group(2) ?? '').padRight(decimals, '0') : '';
    return whole * _pow10(decimals) + (fraction.isEmpty ? 0 : int.parse(fraction));
  }

  /// Converts minor units (cents/fils) to standard decimal double for presentation
  static double toMajorUnits(int minorUnits, [int decimals = 2]) {
    final factor = _pow10(decimals);
    return minorUnits / factor;
  }

  /// Format money for corporate enterprise display
  /// E.g. AED 1,250.50
  static String format(int minorUnits, {String currency = 'AED', int decimals = 2}) {
    final major = toMajorUnits(minorUnits, decimals);
    final formatter = NumberFormat.currency(
      symbol: '$currency ',
      decimalDigits: decimals,
    );
    return formatter.format(major);
  }

  /// Format amount without currency symbol
  static String formatAmount(int minorUnits, [int decimals = 2]) {
    final major = toMajorUnits(minorUnits, decimals);
    final formatter = NumberFormat('#,##0.00');
    return formatter.format(major);
  }

  /// Convert foreign currency minor units to AED minor units using explicit exchange rate
  static int convertToAedMinor({
    required int originalMinorUnits,
    required double exchangeRate,
    int originalDecimals = 2,
    int aedDecimals = 2,
  }) {
    final originalMajor = toMajorUnits(originalMinorUnits, originalDecimals);
    final aedMajor = originalMajor * exchangeRate;
    return toMinorUnits(aedMajor, aedDecimals);
  }

  static int _pow10(int exp) {
    int res = 1;
    for (int i = 0; i < exp; i++) {
      res *= 10;
    }
    return res;
  }
}
