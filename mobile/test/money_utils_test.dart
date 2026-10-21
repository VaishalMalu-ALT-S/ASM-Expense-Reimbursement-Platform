import 'package:flutter_test/flutter_test.dart';
import 'package:asm_expense/core/utils/money_utils.dart';

void main() {
  group('MoneyUtils Financial Integrity Tests', () {
    test('Converts decimal amounts to integer minor units accurately', () {
      expect(MoneyUtils.toMinorUnits(100.50), 10050);
      expect(MoneyUtils.toMinorUnits(500.00), 50000);
      expect(MoneyUtils.toMinorUnits(0.05), 5);
      expect(MoneyUtils.toMinorUnits(10000.00), 1000000);
    });

    test('Parses entered amounts to minor units without floating point', () {
      expect(MoneyUtils.parseMinorUnits('100.50'), 10050);
      expect(MoneyUtils.parseMinorUnits('1,000'), 100000);
      expect(MoneyUtils.parseMinorUnits('500.01'), 50001);
      expect(MoneyUtils.parseMinorUnits('9999.99'), 999999);
      expect(MoneyUtils.parseMinorUnits('0.1'), 10);
      expect(MoneyUtils.parseMinorUnits(' 10000.00 '), 1000000);
      expect(MoneyUtils.parseMinorUnits('-5'), isNull);
      expect(MoneyUtils.parseMinorUnits('12.345'), isNull);
      expect(MoneyUtils.parseMinorUnits('1e5'), isNull);
      expect(MoneyUtils.parseMinorUnits(''), isNull);
      expect(MoneyUtils.parseMinorUnits('abc'), isNull);
    });

    test('Converts minor units back to decimal double correctly', () {
      expect(MoneyUtils.toMajorUnits(10050), 100.50);
      expect(MoneyUtils.toMajorUnits(50000), 500.00);
      expect(MoneyUtils.toMajorUnits(5), 0.05);
    });

    test('Formats currency strings with correct ISO symbol and separators', () {
      expect(MoneyUtils.format(10050, currency: 'AED'), 'AED 100.50');
      expect(MoneyUtils.format(1000000, currency: 'AED'), 'AED 10,000.00');
    });

    test('Performs exact foreign exchange rate conversions to AED minor units', () {
      // 100 USD at 3.6725 = 367.25 AED (36725 fils)
      final aedMinor = MoneyUtils.convertToAedMinor(
        originalMinorUnits: 10000, // $100.00
        exchangeRate: 3.6725,
      );
      expect(aedMinor, 36725);
    });
  });
}
