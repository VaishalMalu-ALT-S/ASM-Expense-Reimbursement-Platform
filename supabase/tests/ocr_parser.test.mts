// Regression tests for the Edge Function receipt parser (UAE thermal fuel receipt pattern).
// Run: node --test supabase/tests/ocr_parser.test.mts
// Fixture lines reproduce real NVIDIA Nemotron output for an ADNOC receipt (layout and OCR
// damage kept, identifier digits altered).
import { test } from "node:test";
import assert from "node:assert/strict";
import { finalizeOcr, fromMicroservice, fromTextLines, linesFromDetections } from "../functions/process-receipt-ocr/ocr_normalize.ts";

const ADNOC_OCR = [
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
];

const CLEAN = [
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
];

const parse = (lines: string[]) => finalizeOcr(fromTextLines(lines, []));

test("OCR-damaged ADNOC receipt: every visible field is read from its label", () => {
  const r = parse(ADNOC_OCR);
  assert.equal(r.vendor, "ADNOC");
  assert.match(r.vendor_raw ?? "", /اد ADNOC/);
  assert.equal(r.invoice_number, "26070000111122223333");
  assert.equal(r.receipt_number, "30017");
  assert.equal(r.date, "2026-07-12");
  assert.equal(r.tax_minor, 595);
  assert.equal(r.tax_rate_percent, 5);
  assert.equal(r.total_minor, 12505);
  assert.deepEqual(r.uncertain_fields, ["total_minor"], "symbol-damaged total is flagged");
  assert.equal(r.currency, null, "no explicit currency text survived OCR");
  assert.deepEqual(r.missing_fields, ["currency"]);
});

test("total is never the quantity, unit price, VAT or an identifier", () => {
  const r = parse(ADNOC_OCR);
  for (const wrong of [3801, 329, 595, 11910, 1212505]) assert.notEqual(r.total_minor, wrong);
});

test("clean bilingual receipt: Total Amount label, VAT summary, date with time, AED", () => {
  const r = parse(CLEAN);
  assert.equal(r.vendor, "ADNOC");
  assert.equal(r.total_minor, 12505);
  assert.deepEqual(r.uncertain_fields, [], "corroborated by payment and VAT summary");
  assert.equal(r.tax_minor, 595);
  assert.equal(r.tax_rate_percent, 5);
  assert.equal(r.date, "2026-07-12");
  assert.equal(r.transaction_time, "13:37:12");
  assert.equal(r.currency, "AED");
  assert.equal(r.invoice_number, "26070000111122223333");
  assert.equal(r.receipt_number, "30017");
  assert.equal(r.status, "SUCCESS");
});

test("receipt, invoice and terminal identifiers are never swapped", () => {
  const r = parse([
    "Shop", "TRN 100099990000001", "TID 03300001", "MID 976500001", "RRN 003000000001",
    "STAN 000023", "Approval Code 400011", "Receipt No: 30017", "Total 10.00",
  ]);
  assert.equal(r.invoice_number, null);
  assert.equal(r.receipt_number, "30017");
  assert.equal(r.total_minor, 1000);
});

test("missing invoice, date and VAT stay null (no INV-0000, no today, no 0.00)", () => {
  const r = parse(["Corner Cafe", "Total AED 18.50"]);
  assert.equal(r.invoice_number, null);
  assert.equal(r.date, null);
  assert.equal(r.tax_minor, null);
  assert.equal(r.tax_rate_percent, null);
  assert.equal(r.total_minor, 1850);
  assert.equal(r.currency, "AED");
  assert.ok(r.missing_fields.includes("date"));
});

test("'Tax Invoice' heading is not an invoice number", () => {
  assert.equal(parse(["Shop", "TAX INVOICE", "Total 5.00"]).invoice_number, null);
});

test("date formats: DD/MM/YYYY, YYYY-MM-DD, DD-MM-YY, DD/MM/YY, named month", () => {
  assert.equal(parse(["S", "Date: 05/03/2026"]).date, "2026-03-05");
  assert.equal(parse(["S", "2026-03-05 10:11"]).date, "2026-03-05");
  assert.equal(parse(["S", "Date 05-03-26"]).date, "2026-03-05");
  assert.equal(parse(["S", "05/03/26 09:15"]).date, "2026-03-05");
  assert.equal(parse(["S", "5 Mar 2026"]).date, "2026-03-05");
  assert.equal(parse(["S", "05/03/26 09:15"]).transaction_time, "09:15");
});

test("impossible or version-like dates are rejected, not reinterpreted", () => {
  assert.equal(parse(["S", "12-22-2026"]).date, null);
  assert.equal(parse(["S", "SW V1.0.19"]).date, null);
});

test("a clock time is never read as a VAT amount", () => {
  const r = parse(["S", "VAT code Amount VAT Rate VAT", "C 100.00 5% 13:37", "Total 105.00"]);
  assert.equal(r.tax_minor, null);
});

test("inline VAT forms", () => {
  assert.equal(parse(["S", "VAT 5% 12.00", "Total 252.00"]).tax_minor, 1200);
  assert.equal(parse(["S", "VAT 5% 12.00", "Total 252.00"]).tax_rate_percent, 5);
  assert.equal(parse(["S", "VAT Amount: 56.21", "Total 1,180.50"]).tax_minor, 5621);
  assert.equal(parse(["S", "Price inclusive of VAT", "Total 10.00"]).tax_minor, null);
});

test("VAT that disagrees with net x rate is flagged", () => {
  const r = parse(["S", "VAT Rate Amount", "C 100.00 5% 9.00", "Total 109.00"]);
  assert.equal(r.tax_minor, 900);
  assert.ok(r.uncertain_fields.includes("tax_minor"));
});

test("total label variants and subtotal exclusion", () => {
  assert.equal(parse(["S", "Sub Total 90.00", "Grand Total 94.50"]).total_minor, 9450);
  assert.equal(parse(["S", "Sub Total 90.00", "Grand Total 94.50"]).subtotal_minor, 9000);
  assert.equal(parse(["S", "Amount Due", "AED 40.00"]).total_minor, 4000);
  assert.equal(parse(["S", "Net Total: 12.00"]).total_minor, 1200);
  assert.equal(parse(["S", "Subtotal 20.00"]).total_minor, null);
  assert.equal(parse(["S", "Total Items 3"]).total_minor, null);
});

test("uncorroborated total is kept but flagged when other evidence disagrees", () => {
  const r = parse(["S", "Total 45.00", "Card 50.00"]);
  assert.equal(r.total_minor, 4500);
  assert.ok(r.uncertain_fields.includes("total_minor"));
});

test("Arabic currency evidence", () => {
  assert.equal(parse(["S", "الإجمالي 20.00 درهم", "Total 20.00"]).currency, "AED");
  assert.equal(parse(["S", "Total 20.00 Dhs"]).currency, "AED");
});

test("ADNOC is not used to infer AED", () => {
  assert.equal(parse(["ADNOC", "Total 20.00"]).currency, null);
});

test("Arabic-only vendor fragment yields to the Latin name below it", () => {
  const r = parse(["اد", "ADNOC", "TAX INVOICE", "Total 1.00"]);
  assert.equal(r.vendor, "ADNOC");
  assert.match(r.vendor_raw ?? "", /^اد ADNOC/);
});

test("punctuation-only and Arabic-only receipts", () => {
  assert.equal(parse(["-----", "Total 1.00"]).vendor, null);
  assert.equal(parse(["مطعم الريف", "Total 1.00"]).vendor, "مطعم الريف");
});

test("VAT is kept when the total could not be read", () => {
  const r = parse(["S", "VAT Rate", "C 119.10 5% 5.95"]);
  assert.equal(r.total_minor, null);
  assert.equal(r.tax_minor, 595);
});

test("field confidence comes from the provider line, never invented", () => {
  const withConf = finalizeOcr(fromTextLines(["Shop", "Total 10.00"], [0.9, 0.7], [0.9, 0.7]));
  assert.equal(withConf.field_confidence.total_minor, 0.7);
  const without = parse(["Shop", "Total 10.00"]);
  assert.deepEqual(without.field_confidence, {});
});

test("row grouping keeps line confidence as the lowest detection confidence", () => {
  const { lines, lineConfidences } = linesFromDetections([
    { text: "Total", confidence: 0.9, points: [{ x: 0.1, y: 0.5 }, { x: 0.2, y: 0.52 }] },
    { text: "10.00", confidence: 0.6, points: [{ x: 0.7, y: 0.5 }, { x: 0.8, y: 0.52 }] },
  ]);
  assert.deepEqual(lines, ["Total 10.00"]);
  assert.deepEqual(lineConfidences, [0.6]);
});

test("OCR service response passes new fields through validation", () => {
  const f = fromMicroservice({
    success: true, vendor: "ADNOC", receipt_number: "30017", transaction_time: "13:37:12",
    tax_rate_percent: 5, uncertain_fields: ["total_minor", "bogus"], field_confidence: { total_minor: 0.7, x: 1 },
    total_minor: 12505, tax_minor: 595, date: "2026-07-12", currency: "AED",
  });
  assert.equal(f?.receipt_number, "30017");
  assert.equal(f?.transaction_time, "13:37:12");
  assert.equal(f?.tax_rate_percent, 5);
  assert.deepEqual(f?.uncertain_fields, ["total_minor"]);
  assert.deepEqual(f?.field_confidence, { total_minor: 0.7 });
  const bad = fromMicroservice({ success: true, transaction_time: "25:99", tax_rate_percent: 500 });
  assert.equal(bad?.transaction_time, null);
  assert.equal(bad?.tax_rate_percent, null);
});

test("thermal receipt: Bill No is extracted as invoice_number and Tax Amount summary takes priority over item VAT", () => {
  const lines = [
    "EXPRESS AL MADEENA H/M BR-3,MUSAFFAH GARDENS,ABUDHABI",
    "Tel: 02-6263313 TAX INVOICE/ TRN:100071746000003",
    "Bill No : A665203/1 : رقم الفاتورة",
    "Bill Date : 16-07-2026 : تاريخ الفاتورة",
    "1 LUSINE CROI CHEESE 60GM 2.25",
    "AL RAWABI LMN MINT 200ML VAT@5.00% 0.10",
    "CASH",
    "Taxable Amount 4.29",
    "Tax Amount/ قيمة الضريبة 0.21",
    "Total Amount 4.50",
  ];
  const r = parse(lines);
  assert.equal(r.vendor, "EXPRESS AL MADEENA H M");
  assert.equal(r.invoice_number, "A665203/1");
  assert.equal(r.date, "2026-07-16");
  assert.equal(r.subtotal_minor, 429);
  assert.equal(r.tax_minor, 21);
  assert.equal(r.tax_rate_percent, 5);
  assert.equal(r.total_minor, 450);
});

test("OCR-damaged thermal receipt: Sill N No is read as invoice_number", () => {
  const lines = [
    "EXPRESS AL MADEENA H/M",
    "Sill N No 1005203/1 :  ,giiaal  al",
    "3ill Date :16-07-2026",
    "VAT@5.00% 0.10",
    "Tax Amount/ awaرl  ميم 0.21",
    "Total Amount/ Sueee l  الل 4.50",
  ];
  const r = parse(lines);
  assert.equal(r.invoice_number, "1005203/1");
  assert.equal(r.tax_minor, 21);
  assert.equal(r.total_minor, 450);
});

test("delivery platform receipt: skips aggregator, reads restaurant, spaced decimals, order and currency", () => {
  const lines = [
    "talabat #243",
    "Vindhya Bhavan Restaurant",
    "PO Box 2984, Abu Dhabi, UAE",
    "Tax Invoice: 3763233291",
    "Order Date: 16-Jul-2026 20:33",
    "Subtotal AED33. 00",
    "Total AED35. 65",
  ];
  const r = parse(lines);
  assert.equal(r.vendor, "Vindhya Bhavan Restaurant");
  assert.equal(r.invoice_number, "3763233291");
  assert.equal(r.date, "2026-07-16");
  assert.equal(r.transaction_time, "20:33");
  assert.equal(r.subtotal_minor, 3300);
  assert.equal(r.total_minor, 3565);
  assert.equal(r.currency, "AED");
});

test("thermal receipt: Inv. #: 69903 and Totai 15.00 are correctly parsed", () => {
  const lines = [
    "CHAAT MAHAL VEG RESTAURANT",
    "TEL: 02-6734567",
    "Inv. #: 69903",
    "Order: 199",
    "Date: 12/07/2026 20:28:20",
    "Totai 15.00",
  ];
  const r = parse(lines);
  assert.equal(r.vendor, "CHAAT MAHAL VEG RESTAURANT");
  assert.equal(r.invoice_number, "69903");
  assert.equal(r.date, "2026-07-12");
  assert.equal(r.transaction_time, "20:28:20");
  assert.equal(r.total_minor, 1500);
});

test("clustered VAT amount on predecessor line is extracted when own line is bare label", () => {
  const lines = [
    "EXPRESS AL MADEENA H/M",
    "Bill No: A677688/2",
    "Date: 16-07-2026",
    "Taxable Amount 6.67 0.33",
    "Tax Amount",
    "Total Amount 7.00",
  ];
  const r = parse(lines);
  assert.equal(r.subtotal_minor, 667);
  assert.equal(r.tax_minor, 33);
  assert.equal(r.total_minor, 700);
});

