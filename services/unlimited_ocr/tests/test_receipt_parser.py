"""Regression tests for receipt_parser (UAE thermal fuel receipt pattern).

Run: python -m unittest discover -s services/unlimited_ocr/tests
Fixture lines reproduce real NVIDIA Nemotron output for an ADNOC receipt
(layout and OCR damage kept, identifier digits altered). Same cases as
supabase/tests/ocr_parser.test.mts.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import receipt_parser as rp  # noqa: E402

ADNOC_OCR = [
    "اد ADNOC TAX INVOTCL TRN.100099990000001",
    "ADNCC Dlstribution",
    "612.612-BetweenTwuBridgen",
    "Price Suhtotal",
    "Ttem",
    "38 3.29 0 125 05",
    "Total Arount : 12125.05",
    "Paynent",
    "Bank 1: 125.05",
    "Token Number",
    "Approval Code 400011",
    "You could have earned 1250 pointal Sign up for ADNCC Rewarts Noww",
    "Price inclusive of VAT VAT Summary",
    "VAi code Arount VAI Rate VAii",
    "C 119.10 5% 5:95",
    "13:3: 12-07-2026",
    "Recelpt Nc: 30017",
    "Tnvo1ce No: 26070000111122223333",
    "Punp No: 2 Attendant TD 1550000001",
    "Employee TD: 100001",
    "IID:621 V V1.0.19 S  N DD242E40218",
    "APPROVED",
    "Celroval Code: 400011",
    "TID 03300001",
    "HID 976500001",
    "RRN 003000000001",
    "BATCH  000003",
    "STAN :000023",
    "Thank You Contact Us 22025812",
]

CLEAN = [
    "أدنوك ADNOC",
    "TAX INVOICE TRN 100099990000001",
    "ADNOC Distribution PO Box 4188 Abu Dhabi UAE",
    "Item Qty Price Subtotal",
    "ULG 95 (C) 38.01 3.29 AED 125.05",
    "Total Amount : AED 125.05",
    "Payment",
    "Bank AED 125.05",
    "VAT Summary",
    "VAT code Amount VAT Rate VAT(AED)",
    "C 119.10 5% 5.95",
    "Date: 12-07-2026 13:37:12",
    "Receipt No: 30017",
    "Invoice No: 26070000111122223333",
    "TID : 03300001",
    "RRN : 003000000001",
]


def parse(lines):
    return rp.parse_receipt(lines)


class AdnocReceipt(unittest.TestCase):
    def test_damaged_receipt_fields_from_labels(self):
        r = parse(ADNOC_OCR)
        self.assertEqual(r["vendor"], "ADNOC")
        self.assertIn("اد ADNOC", r["vendor_raw"])
        self.assertEqual(r["invoice_number"], "26070000111122223333")
        self.assertEqual(r["receipt_number"], "30017")
        self.assertEqual(r["date"], "2026-07-12")
        self.assertEqual(r["tax_minor"], 595)
        self.assertEqual(r["tax_rate_percent"], 5.0)
        self.assertEqual(r["total_minor"], 12505)
        self.assertEqual(r["uncertain_fields"], ["total_minor"])
        self.assertIsNone(r["currency"])

    def test_total_never_quantity_price_vat_or_id(self):
        r = parse(ADNOC_OCR)
        for wrong in (3801, 329, 595, 11910, 1212505):
            self.assertNotEqual(r["total_minor"], wrong)

    def test_clean_bilingual_receipt(self):
        r = parse(CLEAN)
        self.assertEqual(r["vendor"], "ADNOC")
        self.assertEqual(r["total_minor"], 12505)
        self.assertEqual(r["uncertain_fields"], [])
        self.assertEqual(r["tax_minor"], 595)
        self.assertEqual(r["tax_rate_percent"], 5.0)
        self.assertEqual(r["date"], "2026-07-12")
        self.assertEqual(r["transaction_time"], "13:37:12")
        self.assertEqual(r["currency"], "AED")
        self.assertEqual(r["invoice_number"], "26070000111122223333")
        self.assertEqual(r["receipt_number"], "30017")

    def test_identifiers_not_swapped(self):
        r = parse(["Shop", "TRN 100099990000001", "TID 03300001", "MID 976500001", "RRN 003000000001",
                   "STAN 000023", "Approval Code 400011", "Receipt No: 30017", "Total 10.00"])
        self.assertIsNone(r["invoice_number"])
        self.assertEqual(r["receipt_number"], "30017")
        self.assertEqual(r["total_minor"], 1000)


class NoFabrication(unittest.TestCase):
    def test_missing_fields_stay_none(self):
        r = parse(["Corner Cafe", "Total AED 18.50"])
        self.assertIsNone(r["invoice_number"])
        self.assertIsNone(r["date"])
        self.assertIsNone(r["tax_minor"])
        self.assertIsNone(r["tax_rate_percent"])
        self.assertIsNone(r["subtotal_minor"], "subtotal is never derived")
        self.assertEqual(r["total_minor"], 1850)

    def test_tax_invoice_heading_not_invoice_number(self):
        self.assertIsNone(parse(["Shop", "TAX INVOICE", "Total 5.00"])["invoice_number"])

    def test_adnoc_does_not_imply_aed(self):
        self.assertIsNone(parse(["ADNOC", "Total 20.00"])["currency"])

    def test_field_confidence_only_from_provider(self):
        self.assertEqual(rp.parse_receipt(["Shop", "Total 10.00"], [0.9, 0.7])["field_confidence"]["total_minor"], 0.7)
        self.assertEqual(parse(["Shop", "Total 10.00"])["field_confidence"], {})


class Dates(unittest.TestCase):
    def test_formats(self):
        self.assertEqual(parse(["S", "Date: 05/03/2026"])["date"], "2026-03-05")
        self.assertEqual(parse(["S", "2026-03-05 10:11"])["date"], "2026-03-05")
        self.assertEqual(parse(["S", "Date 05-03-26"])["date"], "2026-03-05")
        self.assertEqual(parse(["S", "05/03/26 09:15"])["date"], "2026-03-05")
        self.assertEqual(parse(["S", "5 Mar 2026"])["date"], "2026-03-05")
        self.assertEqual(parse(["S", "05/03/26 09:15"])["transaction_time"], "09:15")

    def test_rejected_not_reinterpreted(self):
        self.assertIsNone(parse(["S", "12-22-2026"])["date"])
        self.assertIsNone(parse(["S", "SW V1.0.19"])["date"])


class VatAndTotal(unittest.TestCase):
    def test_clock_time_not_vat(self):
        self.assertIsNone(parse(["S", "VAT code Amount VAT Rate VAT", "C 100.00 5% 13:37", "Total 105.00"])["tax_minor"])

    def test_inline_vat(self):
        self.assertEqual(parse(["S", "VAT 5% 12.00", "Total 252.00"])["tax_minor"], 1200)
        self.assertEqual(parse(["S", "VAT 5% 12.00", "Total 252.00"])["tax_rate_percent"], 5.0)
        self.assertEqual(parse(["S", "VAT Amount: 56.21", "Total 1,180.50"])["tax_minor"], 5621)
        self.assertIsNone(parse(["S", "Price inclusive of VAT", "Total 10.00"])["tax_minor"])

    def test_inconsistent_vat_flagged(self):
        r = parse(["S", "VAT Rate Amount", "C 100.00 5% 9.00", "Total 109.00"])
        self.assertEqual(r["tax_minor"], 900)
        self.assertIn("tax_minor", r["uncertain_fields"])

    def test_total_labels(self):
        self.assertEqual(parse(["S", "Sub Total 90.00", "Grand Total 94.50"])["total_minor"], 9450)
        self.assertEqual(parse(["S", "Sub Total 90.00", "Grand Total 94.50"])["subtotal_minor"], 9000)
        self.assertEqual(parse(["S", "Amount Due", "AED 40.00"])["total_minor"], 4000)
        self.assertEqual(parse(["S", "Net Total: 12.00"])["total_minor"], 1200)
        self.assertIsNone(parse(["S", "Subtotal 20.00"])["total_minor"])
        self.assertIsNone(parse(["S", "Total Items 3"])["total_minor"])

    def test_conflicting_evidence_flags_total(self):
        r = parse(["S", "Total 45.00", "Card 50.00"])
        self.assertEqual(r["total_minor"], 4500)
        self.assertIn("total_minor", r["uncertain_fields"])

    def test_vat_kept_without_total(self):
        r = parse(["S", "VAT Rate", "C 119.10 5% 5.95"])
        self.assertIsNone(r["total_minor"])
        self.assertEqual(r["tax_minor"], 595)


class Bilingual(unittest.TestCase):
    def test_arabic_currency(self):
        self.assertEqual(parse(["S", "الإجمالي 20.00 درهم", "Total 20.00"])["currency"], "AED")
        self.assertEqual(parse(["S", "Total 20.00 Dhs"])["currency"], "AED")

    def test_punctuation_and_arabic_only(self):
        self.assertIsNone(parse(["-----", "Total 1.00"])["vendor"])
        self.assertEqual(parse(["مطعم الريف", "Total 1.00"])["vendor"], "مطعم الريف")

    def test_arabic_fragment_yields_to_latin_name(self):
        r = parse(["اد", "ADNOC", "TAX INVOICE", "Total 1.00"])
        self.assertEqual(r["vendor"], "ADNOC")
        self.assertTrue(r["vendor_raw"].startswith("اد ADNOC"))


if __name__ == "__main__":
    unittest.main()
