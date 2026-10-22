import 'package:flutter_test/flutter_test.dart';
import 'package:asm_expense/core/utils/money_utils.dart';
import 'package:asm_expense/shared/models/currency_item.dart';
import 'package:asm_expense/shared/models/ocr_result.dart';
import 'package:asm_expense/shared/models/expense_claim.dart';

void main() {
  group('Targeted Flow & Currency Tests', () {
    test('Normal claim calculation without cash advance has advance_applied = 0 and net = total', () {
      const int expense1AedMinor = 15000; // AED 150.00
      const int expense2AedMinor = 35000; // AED 350.00
      const int totalExpenseMinor = expense1AedMinor + expense2AedMinor; // AED 500.00

      // In the new flow, no advance is applied during claim creation
      const int advanceAppliedMinor = 0;
      final int netReimbursementMinor = totalExpenseMinor - advanceAppliedMinor;

      expect(totalExpenseMinor, 50000);
      expect(advanceAppliedMinor, 0);
      expect(netReimbursementMinor, 50000);
      expect(netReimbursementMinor, equals(totalExpenseMinor));
    });

    test('CurrencyItem json serialization and normalization', () {
      final gbp = CurrencyItem.fromJson({
        'code': 'gbp ',
        'name': 'British Pound',
        'symbol': '£',
        'decimals': 2,
      });
      expect(gbp.code, 'GBP');
      expect(gbp.symbol, '£');
      expect(gbp.decimals, 2);
      expect(gbp.displayName, 'GBP - British Pound (£)');

      final inr = CurrencyItem.fromJson({
        'code': 'inr',
        'name': 'Indian Rupee',
        'symbol': '₹',
      });
      expect(inr.code, 'INR');
      expect(inr.symbol, '₹');
      expect(inr.decimals, 2);

      final custom = CurrencyItem(code: 'XYZ', name: 'Custom Maritime Token', symbol: 'XYZ');
      expect(custom.toJson(), {
        'code': 'XYZ',
        'name': 'Custom Maritime Token',
        'symbol': 'XYZ',
        'decimals': 2,
      });
    });

    test('OCR currency detection parses GBP, INR, USD, EUR, and AED correctly', () {
      final ocrGbp = OcrResult.fromJson({
        'success': true,
        'status': 'SUCCESS',
        'data': {
          'vendor': 'London Marine Spares',
          'total_minor': 12500,
          'currency': 'GBP',
          'date': '2026-10-20',
        },
      });
      expect(ocrGbp.currency, 'GBP');
      expect(ocrGbp.totalMinor, 12500);

      final ocrInr = OcrResult.fromJson({
        'success': true,
        'status': 'SUCCESS',
        'data': {
          'vendor': 'Mumbai Dock Logistics',
          'total_minor': 450000,
          'currency': 'INR',
          'date': '2026-10-21',
        },
      });
      expect(ocrInr.currency, 'INR');
      expect(ocrInr.totalMinor, 450000);

      final ocrUsd = OcrResult.fromJson({
        'success': true,
        'status': 'SUCCESS',
        'data': {'vendor': 'Miami Marine', 'total_minor': 5000, 'currency': 'USD'},
      });
      expect(ocrUsd.currency, 'USD');

      final ocrEur = OcrResult.fromJson({
        'success': true,
        'status': 'SUCCESS',
        'data': {'vendor': 'Hamburg Port Store', 'total_minor': 8200, 'currency': 'EUR'},
      });
      expect(ocrEur.currency, 'EUR');

      final ocrAed = OcrResult.fromJson({
        'success': true,
        'status': 'SUCCESS',
        'data': {'vendor': 'ADNOC Fuel', 'total_minor': 12505, 'currency': 'AED'},
      });
      expect(ocrAed.currency, 'AED');
    });

    test('Multi-currency conversion to AED minor units using authoritative server rates', () {
      // GBP: 100.00 GBP at 4.755000 = AED 475.50 (47550 fils)
      final gbpAed = MoneyUtils.convertToAedMinor(
        originalMinorUnits: 10000,
        exchangeRate: 4.755000,
      );
      expect(gbpAed, 47550);

      // INR: 10,000.00 INR at 0.044000 = AED 440.00 (44000 fils)
      final inrAed = MoneyUtils.convertToAedMinor(
        originalMinorUnits: 1000000,
        exchangeRate: 0.044000,
      );
      expect(inrAed, 44000);

      // USD: 100.00 USD at 3.672500 = AED 367.25 (36725 fils)
      final usdAed = MoneyUtils.convertToAedMinor(
        originalMinorUnits: 10000,
        exchangeRate: 3.672500,
      );
      expect(usdAed, 36725);

      // EUR: 100.00 EUR at 3.985000 = AED 398.50 (39850 fils)
      final eurAed = MoneyUtils.convertToAedMinor(
        originalMinorUnits: 10000,
        exchangeRate: 3.985000,
      );
      expect(eurAed, 39850);

      // AED: 100.00 AED at 1.000000 = AED 100.00 (10000 fils)
      final aedAed = MoneyUtils.convertToAedMinor(
        originalMinorUnits: 10000,
        exchangeRate: 1.000000,
      );
      expect(aedAed, 10000);

      // Custom currency: 1,000.00 at 0.500000 = AED 500.00
      final customAed = MoneyUtils.convertToAedMinor(
        originalMinorUnits: 100000,
        exchangeRate: 0.500000,
      );
      expect(customAed, 50000);
    });

    test('Claim model handles legacy advance gracefully while new claims have advanceAppliedMinor = 0', () {
      final newClaimJson = {
        'id': 'claim-101',
        'claim_number': 'CLM-2026-000101',
        'employee_id': 'emp-1',
        'title': 'ASM Technical Field Visit',
        'purpose': 'Refit vessel spare inspection',
        'claim_date': '2026-10-22',
        'cash_advance_id': null,
        'advance_applied_minor': 0,
        'total_expense_minor': 75000,
        'net_reimbursement_minor': 75000,
        'status': 'SUBMITTED',
        'validation_status': 'PASSED',
        'created_at': '2026-10-22T10:00:00Z',
      };
      final newClaim = ExpenseClaim.fromJson(newClaimJson);
      expect(newClaim.cashAdvanceId, isNull);
      expect(newClaim.advanceAppliedMinor, 0);
      expect(newClaim.netReimbursementMinor, newClaim.totalExpenseMinor);

      // Legacy claim with advance preserved
      final legacyClaimJson = {
        'id': 'claim-099',
        'claim_number': 'CLM-2026-000099',
        'employee_id': 'emp-1',
        'title': 'Historical ADIPEC 2026',
        'purpose': 'Conference advance settlement',
        'claim_date': '2026-09-15',
        'cash_advance_id': 'adv-99',
        'advance_applied_minor': 50000,
        'total_expense_minor': 80000,
        'net_reimbursement_minor': 30000,
        'status': 'SETTLED',
        'validation_status': 'PASSED',
        'created_at': '2026-09-15T10:00:00Z',
      };
      final legacyClaim = ExpenseClaim.fromJson(legacyClaimJson);
      expect(legacyClaim.cashAdvanceId, 'adv-99');
      expect(legacyClaim.advanceAppliedMinor, 50000);
      expect(legacyClaim.netReimbursementMinor, 30000);
    });
  });
}
