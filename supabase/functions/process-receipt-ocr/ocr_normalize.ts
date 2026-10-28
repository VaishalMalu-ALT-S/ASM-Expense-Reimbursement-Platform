// Normalization of untrusted OCR / AI output into receipt fields.
// Every field is either a validated value or null; nothing is defaulted or
// invented. Amounts are converted to integer minor units from their decimal
// string form, never through floating-point arithmetic.

export type OcrStatus = "SUCCESS" | "PARTIAL" | "FAILED";

export interface OcrFields {
  vendor: string | null;
  /** Vendor line exactly as read (e.g. bilingual), kept for audit. */
  vendor_raw: string | null;
  invoice_number: string | null;
  receipt_number: string | null;
  date: string | null;
  transaction_time: string | null;
  subtotal_minor: number | null;
  tax_minor: number | null;
  tax_rate_percent: number | null;
  total_minor: number | null;
  currency: string | null;
  confidence_score: number | null;
  /** Fields that were read but need particular care when verifying. */
  uncertain_fields: string[];
  /** Provider confidence of the text line each field was read from. */
  field_confidence: Record<string, number>;
}

export interface OcrOutcome extends OcrFields {
  status: OcrStatus;
  missing_fields: string[];
}

export const SUPPORTED_CURRENCIES = [
  "AED", "USD", "EUR", "GBP", "INR", "SAR", "QAR", "OMR", "BHD", "KWD", "SGD", "JPY", "CHF", "CAD", "AUD"
];
export const REQUIRED_FIELDS: (keyof OcrFields)[] = ["vendor", "date", "total_minor", "currency"];
export const VALUE_FIELDS = [
  "vendor", "invoice_number", "receipt_number", "date", "transaction_time",
  "subtotal_minor", "tax_minor", "tax_rate_percent", "total_minor", "currency",
] as const;

export const EMPTY_FIELDS: OcrFields = {
  vendor: null,
  vendor_raw: null,
  invoice_number: null,
  receipt_number: null,
  date: null,
  transaction_time: null,
  subtotal_minor: null,
  tax_minor: null,
  tax_rate_percent: null,
  total_minor: null,
  currency: null,
  confidence_score: null,
  uncertain_fields: [],
  field_confidence: {},
};

/** Decimal major-unit value ("1,250.50", "AED 12.5", 12.5) -> minor units. */
export function majorToMinor(value: unknown): number | null {
  let s: string;
  if (typeof value === "number") {
    if (!Number.isFinite(value) || value < 0) return null;
    s = String(value);
  } else if (typeof value === "string") {
    s = value;
  } else {
    return null;
  }
  s = s.trim()
    .replace(/,/g, "")
    .replace(/^(?:AED|DHS?|USD|EUR|GBP|\$|€|£)\s*/i, "")
    .replace(/\s*(?:AED|DHS?|USD|EUR|GBP)$/i, "")
    .replace(/\s+/g, "");
  const m = s.match(/^(\d{1,9})(?:\.(\d{1,2}))?$/);
  if (!m) return null;
  return Number(m[1]) * 100 + Number((m[2] ?? "").padEnd(2, "0"));
}

/** Value that is already in minor units (e.g. from the OCR microservice). */
export function minorInt(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : null;
}

export function normalizeText(value: unknown, maxLength: number): string | null {
  if (typeof value !== "string") return null;
  const clean = value.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  return clean.length > 0 ? clean.slice(0, maxLength) : null;
}

/** Accepts YYYY-MM-DD only, and only if it is a real calendar date. */
export function normalizeDate(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const m = value.trim().match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!m) return null;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) return null;
  return m[0];
}

/** Converts DD-MM-YYYY / DD/MM/YY / YYYY.MM.DD style matches to YYYY-MM-DD. */
export function looseDateToIso(raw: string): string | null {
  const parts = raw.replace(/[./]/g, "-").split("-");
  if (parts.length !== 3) return null;
  let [a, b, c] = parts;
  if (a.length === 4) return normalizeDate(`${a}-${b.padStart(2, "0")}-${c.padStart(2, "0")}`);
  if (c.length === 2) c = `20${c}`;
  return normalizeDate(`${c}-${b.padStart(2, "0")}-${a.padStart(2, "0")}`);
}

export function normalizeCurrency(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const c = value.trim().toUpperCase();
  const mapped = c === "DHS" || c === "DH" || c === "DIRHAM" || c === "DIRHAMS" ? "AED" : c;
  return SUPPORTED_CURRENCIES.includes(mapped) ? mapped : null;
}

function normalizeTime(value: unknown): string | null {
  return typeof value === "string" && /^([01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$/.test(value) ? value : null;
}

function normalizeRate(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value > 0 && value <= 100 ? value : null;
}

function normalizeFieldList(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((v): v is string => typeof v === "string" && (VALUE_FIELDS as readonly string[]).includes(v))
    : [];
}

function normalizeFieldConfidence(value: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      const c = normalizeConfidence(v);
      if ((VALUE_FIELDS as readonly string[]).includes(k) && c !== null) out[k] = c;
    }
  }
  return out;
}

export function normalizeConfidence(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1
    ? Math.round(value * 10000) / 10000
    : null;
}

/** Final consistency checks and status classification. */
export function finalizeOcr(fields: OcrFields | null): OcrOutcome {
  const f: OcrFields = {
    ...EMPTY_FIELDS,
    ...(fields ?? {}),
    uncertain_fields: [...(fields?.uncertain_fields ?? [])],
    field_confidence: { ...(fields?.field_confidence ?? {}) },
  };
  if (f.total_minor !== null && f.total_minor <= 0) f.total_minor = null;
  if (f.tax_minor !== null && f.total_minor !== null && f.tax_minor >= f.total_minor) f.tax_minor = null;
  if (f.subtotal_minor !== null && (f.total_minor === null || f.subtotal_minor > f.total_minor)) f.subtotal_minor = null;
  for (const k of VALUE_FIELDS) {
    if (f[k] === null) delete f.field_confidence[k];
  }
  f.uncertain_fields = [...new Set(f.uncertain_fields)].filter((k) => f[k as keyof OcrFields] !== null);

  const extracted = VALUE_FIELDS.filter((k) => f[k] !== null);
  const missing = REQUIRED_FIELDS.filter((k) => f[k] === null);

  let status: OcrStatus = "SUCCESS";
  if (fields === null || extracted.length === 0) status = "FAILED";
  else if (missing.length > 0) status = "PARTIAL";

  if (status === "FAILED") {
    return { ...EMPTY_FIELDS, uncertain_fields: [], field_confidence: {}, status, missing_fields: [...REQUIRED_FIELDS] };
  }
  return { ...f, status, missing_fields: missing };
}

/** Output of the ASM OCR microservice (amounts already in minor units). */
export function fromMicroservice(json: any): OcrFields | null {
  if (!json || json.success !== true) return null;
  return {
    vendor: normalizeText(json.vendor, 200),
    vendor_raw: normalizeText(json.vendor_raw, 300),
    invoice_number: normalizeText(json.invoice_number, 100),
    receipt_number: normalizeText(json.receipt_number, 60),
    date: normalizeDate(json.date),
    transaction_time: normalizeTime(json.transaction_time),
    subtotal_minor: minorInt(json.subtotal_minor),
    tax_minor: minorInt(json.tax_minor),
    tax_rate_percent: normalizeRate(json.tax_rate_percent),
    total_minor: minorInt(json.total_minor),
    currency: normalizeCurrency(json.currency),
    confidence_score: normalizeConfidence(json.confidence_score),
    uncertain_fields: normalizeFieldList(json.uncertain_fields),
    field_confidence: normalizeFieldConfidence(json.field_confidence),
  };
}

export interface TextDetection {
  text: string;
  confidence?: unknown;
  points?: { x: number; y: number }[];
}

/**
 * Reading-order lines from NVIDIA detections. NVIDIA returns label and amount
 * of one printed row as separate detections ("Total AED" | "199.50");
 * detections whose vertical centres lie within half a box height form one
 * row, joined left to right. Without geometry the provider order is kept.
 */
export function linesFromDetections(
  detections: TextDetection[],
): { lines: string[]; confidences: number[]; lineConfidences: (number | null)[] } {
  const rawItems = detections
    .filter((d) => typeof d.text === "string" && d.text.trim())
    .map((d) => {
      const ys = (d.points ?? []).map((p) => p.y).filter((v) => typeof v === "number");
      const xs = (d.points ?? []).map((p) => p.x).filter((v) => typeof v === "number");
      const y0 = ys.length ? Math.min(...ys) : NaN;
      const y1 = ys.length ? Math.max(...ys) : NaN;
      const x0 = xs.length ? Math.min(...xs) : 0;
      const x1 = xs.length ? Math.max(...xs) : 0;
      return {
        text: d.text.trim(),
        confidence: typeof d.confidence === "number" ? d.confidence : NaN,
        y0, y1, x0, x1,
      };
    });

  const confidences = rawItems.map((i) => i.confidence).filter((c) => Number.isFinite(c));
  const minConf = (group: typeof rawItems) => {
    const c = group.map((i) => i.confidence).filter((v) => Number.isFinite(v));
    return c.length ? Math.min(...c) : null;
  };

  if (rawItems.length === 0 || rawItems.some((i) => !Number.isFinite(i.y0))) {
    return { lines: rawItems.map((i) => i.text), confidences, lineConfidences: rawItems.map((i) => minConf([i])) };
  }

  // Detect if text detections are sideways (rotated 90 deg by camera sensor orientation).
  // Horizontal printed text typically has width >= height for multi-character words.
  // When rotated 90 deg, individual word boxes are narrow and very tall (w/h < 0.6).
  let tallBoxes = 0;
  let wideBoxes = 0;
  for (const it of rawItems) {
    const w = it.x1 - it.x0;
    const h = it.y1 - it.y0;
    if (w > 0 && h > 0) {
      if (w / h < 0.6) tallBoxes++;
      else if (w / h > 1.2) wideBoxes++;
    }
  }

  // If the majority of words are oriented vertically, rotate coordinates 270 deg CCW (90 deg CW).
  const isSideways = rawItems.length >= 4 && tallBoxes > wideBoxes * 2;
  const items = rawItems.map((it) => {
    if (!isSideways) {
      return { text: it.text, confidence: it.confidence, y0: it.y0, y1: it.y1, x: it.x0 };
    }
    // Rotate 270 deg CCW: new_x = 1 - old_y, new_y = old_x
    return {
      text: it.text,
      confidence: it.confidence,
      y0: it.x0,
      y1: it.x1,
      x: 1.0 - it.y1,
    };
  });

  const rows: { items: typeof items }[] = [];
  for (const it of [...items].sort((a, b) => (a.y0 + a.y1) - (b.y0 + b.y1))) {
    const centre = (it.y0 + it.y1) / 2;
    const height = Math.max(it.y1 - it.y0, 1e-6);
    const row = rows[rows.length - 1];
    if (row) {
      const rowCenter = row.items.reduce((s, x) => s + (x.y0 + x.y1) / 2, 0) / row.items.length;
      const rowHeight = row.items.reduce((s, x) => s + (x.y1 - x.y0), 0) / row.items.length;
      const verticalDist = Math.abs(centre - rowCenter);
      const maxH = Math.max(height, rowHeight);
      const tolerance = isSideways ? Math.max(0.014, 0.7 * maxH) : 0.55 * maxH;
      if (verticalDist < tolerance) {
        row.items.push(it);
        continue;
      }
    }
    rows.push({ items: [it] });
  }

  return {
    lines: rows.map((r) => [...r.items].sort((a, b) => a.x - b.x).map((i) => i.text).join(" ")),
    confidences,
    lineConfidences: rows.map((r) => minConf(r.items as any)),
  };
}

// ---------------------------------------------------------------------------
// Contextual receipt parser. Values are taken only from labelled positions;
// nothing is chosen because it is the largest, first or last number.
// Kept rule-for-rule in step with services/unlimited_ocr/receipt_parser.py.
// ---------------------------------------------------------------------------

const ARABIC_RUN = /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]+/g;
/** Two-decimal amount with optional thousands separators; handles thermal spacing ("35. 65"). */
const MONEY_RE = /(?<![\d.,:])(\d{1,3}(?:,\d{3})+\.\s*\d{2}|\d+\.\s*\d{2})(?!\d|[.,]\d)/g;
/** Table-cell amount where thermal OCR may print the decimal point as ':' ("5:95"). */
const CELL_MONEY_RE = /(?<![\d.,:])(\d{1,6})([.:])(\d{2})(?![\d.,:])/g;
const CURRENCY_WORD_RE = /\b(?:AED|DHS|DIRHAMS?|USD|EUR)(?![A-Za-z])|درهم|د\.?\s?إ/gi;

const SUBTOTAL_RE = /\b(?:su[bhn]\s*-?\s*tota[li|1]|taxab[li|1]e\s*(?:amount)?|net\s*amount)\b|المبلغ\s*الخاضع|الخاضع\s*للضريبة/i;
const SUBTOTAL_EXCLUDE_RE = /\b(?:item|qty|description|price)\s+su[bhn]total\b/i;
const TOTAL_STRONG_RE = /\b(?:grand\s*tota[li|1]|net\s*tota[li|1]|total\s*(?:due|payable)|amount\s*(?:due|payable)|balance\s*due)\b|المبلغ\s*الإجمالي|المبلغ\s*الاجمالي|صافي\s*المبلغ|\bilaaall\b/i;
const TOTAL_RE = /\btota[li|1]\b|\bمجموع\b|\bالإجمالي\b|\bالاجمالي\b|\bالمبلغ\b/i;
const TOTAL_EXCLUDE_RE = /\btota[li|1]\s*(?:vat|tax|qty|quantity|items?|discount|savings?|points?|excl\w*|before)\b|\bpoints?\b/i;
const PAYMENT_RE = /\b(?:pa[yv]\w*|paid|bank|card|credit|debit|visa|mastercard|master\s*card|amex|tender\w*|nfc|apple\s*pay|google\s*pay)\b/i;
const VATISH_RE = /\bva[t1il!|]\b|\bvat|\btax\b/i;
const VAT_SUMMARY_RE = /\b(?:tax\s*amount|vat\s*amount|total\s*vat|total\s*tax|net\s*vat)\b|قيمة\s*الضريبة|مبلغ\s*الضريبة/i;
const VAT_LINE_RE = /\b(?:vat|tax)\b/i;
const VAT_LINE_EXCLUDE_RE = /\b(?:ta[xk]\s*inv\w*|vat\s*(?:no|reg\w*|#|number|id)|trn|inclusive|incl\.?|excl\w*|summary|taxab[li|1]e)\b/i;
const PERCENT_RE = /(\d{1,2}(?:\.\d{1,2})?)\s*%/;
const DATE_LABEL_RE = /\b(?:d[a@]te|dated|dt|till)\b/i;
const TIME_RE = /(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?(?![\d:])/;
const NUMBER_MARK = String.raw`(?:\b(?:n[o0c]\b\.?|no\.|num(?:ber)?\b\.?|[o0]\b)|#)`;
const ID_VALUE = String.raw`([A-Za-z0-9][A-Za-z0-9\/\-_]{2,39})`;
// OCR-tolerant labels: "Tnvo1ce No", "Recelpt Nc", "Bill No", "Sill N No", "Inv. #: 69903", "رقم الفاتورة".
// A number marker or colon is required, so a "Tax Invoice" heading is never read as an invoice number.
const INVOICE_PRIMARY_RE = new RegExp(
  String.raw`(?:^|[^\w])(?:(?:[i1l|t]nv[o0][i1l]ce|inv|[b83s][i1l|]ll|b\.?no|bill)\b[\s\w.#\-]*?${NUMBER_MARK}|(?:[i1l|t]nv[o0][i1l]ce|inv|[b83s][i1l|]ll)\s*[:#]|(?:^|\s)no\s*[:#]|رقم\s*الفاتور[ةه]|فاتور[ةه]\s*رقم|رقم\s*الإيصال|رقم\s*الايصال)\s*[:.#\-]*\s*${ID_VALUE}`,
  "i",
);
const INVOICE_ORDER_RE = new RegExp(
  String.raw`(?:^|[^\w])(?:order\s*(?:no|#|num)|talabat\s*#)\s*[:.#\-]*\s*${ID_VALUE}`,
  "i",
);
const RECEIPT_RE = new RegExp(
  String.raw`(?:^|[^A-Za-z])(?:(?:r[e3]c[e3][i1l]pt|rcpt|rct)\s*${NUMBER_MARK}|r[e3]c[e3][i1l]pt\s*[:#])\s*[:.#\-]*\s*${ID_VALUE}`,
  "i",
);
const VENDOR_CUT_RE = /\b(?:ta[xk]\s+[i1l|t][nm]\w*|tax\s*receipt|trn\b|tsn\b|vat\s*(?:no|reg\w*|#)|tel\b|phone\b|mob\w*|p\.?\s*o\.?\s*box|po\s*box|box\s*\d|branch\b|br-\d+|fax\b)|\d{8,}/i;
const VENDOR_SKIP_RE = /^(?:tax\s*invoice|invoice|receipt|welcome|date|cashier|order|customer\s*copy|merchant\s*copy|duplicate|original|talabat|noon)\b/i;
const MONTHS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12,
};

interface Amount { text: string; minor: number }

function moneyIn(text: string): Amount[] {
  const out: Amount[] = [];
  for (const m of text.matchAll(MONEY_RE)) {
    const clean = m[1].replace(/[\s,]/g, "");
    const minor = majorToMinor(clean);
    if (minor !== null) out.push({ text: clean, minor });
  }
  return out;
}

function cellMoneyIn(text: string): Amount[] {
  const out: Amount[] = [];
  for (const m of text.matchAll(CELL_MONEY_RE)) {
    // "13:37" is a clock time, not an amount.
    if (m[2] === ":" && Number(m[1]) <= 23 && Number(m[3]) <= 59) continue;
    const minor = majorToMinor(`${m[1]}.${m[3]}`);
    if (minor !== null) out.push({ text: `${m[1]}.${m[3]}`, minor });
  }
  return out;
}

/** Line that carries amounts but no label of its own. */
function isBare(text: string): boolean {
  return !/[A-Za-z\u0600-\u06FF]/.test(text.replace(CURRENCY_WORD_RE, ""));
}

interface VatResult { tax: number | null; rate: number | null; net: number | null; line: number; uncertain: boolean }

function parseVat(lines: string[]): VatResult {
  // 1. VAT summary table: a header naming the rate, then rows "code  net  rate%  vat".
  for (let i = 0; i < lines.length; i++) {
    if (!/\brate\b/i.test(lines[i]) || !VATISH_RE.test(lines[i])) continue;
    let tax = 0, net = 0, found = 0, netKnown = true;
    const rates = new Set<number>();
    let last = i;
    for (let j = i + 1; j < Math.min(lines.length, i + 5); j++) {
      const pm = lines[j].match(PERCENT_RE);
      if (!pm || pm.index === undefined) {
        if (found) break;
        continue;
      }
      const after = cellMoneyIn(lines[j].slice(pm.index + pm[0].length));
      if (after.length === 0) continue;
      const before = cellMoneyIn(lines[j].slice(0, pm.index));
      tax += after[0].minor;
      if (before.length) net += before[before.length - 1].minor;
      else netKnown = false;
      rates.add(Number(pm[1]));
      found++;
      last = j;
    }
    if (found) {
      const rate = rates.size === 1 ? [...rates][0] : null;
      const hasNet = netKnown && net > 0;
      // Rounded VAT must agree with net x rate to within one minor unit, or match standard 5% UAE VAT.
      const isUaeVat = Math.abs(tax * 100 - net * 5) <= 100;
      const consistent = !hasNet || rate === null || Math.abs(tax * 100 - net * rate) <= 100 || isUaeVat;
      return { tax, rate: isUaeVat && rate === 6 ? 5 : rate, net: hasNet ? net : null, line: last, uncertain: !consistent };
    }
  }

  // Helper to discover tax rate anywhere on the receipt if not on the VAT summary line itself.
  const findFallbackRate = (): number | null => {
    for (const l of lines) {
      const pm = l.match(PERCENT_RE);
      if (pm && VATISH_RE.test(l)) {
        const val = Number(pm[1]);
        if (val > 0 && val <= 30) return val;
      }
    }
    return null;
  };

  // 2. Explicit summary Tax/VAT line: "Tax Amount: 0.21", "VAT Amount: 5.95", "قيمة الضريبة 0.21", "Total VAT AED 4.50"
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (!VAT_SUMMARY_RE.test(l) || VAT_LINE_EXCLUDE_RE.test(l)) continue;
    const pm = l.match(PERCENT_RE);
    const rate = pm ? Number(pm[1]) : findFallbackRate();

    const own = moneyIn(l);
    if (own.length) {
      return { tax: own[own.length - 1].minor, rate, net: null, line: i, uncertain: false };
    }
    if (i + 1 < lines.length && isBare(lines[i + 1]) && moneyIn(lines[i + 1]).length) {
      const next = moneyIn(lines[i + 1]);
      return { tax: next[0].minor, rate, net: null, line: i + 1, uncertain: false };
    }
    if (i > 0) {
      const prev = moneyIn(lines[i - 1]);
      if (prev.length) {
        if (isBare(lines[i - 1]) || prev.length > 1) {
          return { tax: prev[prev.length - 1].minor, rate, net: null, line: i - 1, uncertain: false };
        }
      }
    }
  }

  // 3. Inline VAT line fallback: "VAT 5% 12.00", skipping item-level notes like "@ 5.00%"
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (!VAT_LINE_RE.test(l) || VAT_LINE_EXCLUDE_RE.test(l)) continue;
    if (/@\s*\d/.test(l)) continue;
    const pm = l.match(PERCENT_RE);
    const amounts = moneyIn(pm && pm.index !== undefined ? l.slice(pm.index + pm[0].length) : l);
    if (amounts.length === 0) continue;
    return { tax: (pm ? amounts[0] : amounts[amounts.length - 1]).minor, rate: pm ? Number(pm[1]) : null, net: null, line: i, uncertain: false };
  }
  return { tax: null, rate: null, net: null, line: -1, uncertain: false };
}

/** Amounts printed independently of the total line (card/bank payment, VAT summary net + VAT). */
function totalEvidence(lines: string[], vat: VatResult): Amount[] {
  const ev: Amount[] = [];
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (!PAYMENT_RE.test(l) || TOTAL_RE.test(l) || SUBTOTAL_RE.test(l)) continue;
    const own = moneyIn(l);
    if (own.length) ev.push(...own);
    else if (i + 1 < lines.length && isBare(lines[i + 1])) ev.push(...moneyIn(lines[i + 1]));
  }
  if (vat.tax !== null && vat.net !== null && !vat.uncertain) {
    const sum = vat.tax + vat.net;
    ev.push({ text: (sum / 100).toFixed(2), minor: sum });
  }
  return ev;
}

interface TotalResult { minor: number | null; line: number; uncertain: boolean }

function parseTotal(lines: string[], evidence: Amount[]): TotalResult {
  const labelled = (re: RegExp) => {
    for (let i = 0; i < lines.length; i++) {
      const l = lines[i];
      const m = l.match(re);
      if (!m || m.index === undefined || SUBTOTAL_RE.test(l) || TOTAL_EXCLUDE_RE.test(l)) continue;
      const own = moneyIn(l.slice(m.index + m[0].length));
      if (own.length) return { amount: own[own.length - 1], line: i };
      const splitDot = l.match(/(?<![\d.])(\d+)\.\s*$/);
      if (splitDot && i + 1 < lines.length && isBare(lines[i + 1])) {
        const nextDigits = lines[i + 1].trim().match(/^(\d{2})\b/);
        if (nextDigits) {
          const combined = splitDot[1] + "." + nextDigits[1];
          const minor = majorToMinor(combined);
          if (minor !== null) return { amount: { text: combined, minor }, line: i };
        }
      }
      if (i + 1 < lines.length && isBare(lines[i + 1]) && moneyIn(lines[i + 1]).length) {
        return { amount: moneyIn(lines[i + 1])[0], line: i + 1 };
      }
      if (i > 0 && isBare(lines[i - 1]) && moneyIn(lines[i - 1]).length) {
        const prev = moneyIn(lines[i - 1]);
        return { amount: prev[prev.length - 1], line: i - 1 };
      }
    }
    return null;
  };
  const hit = labelled(TOTAL_STRONG_RE) ?? labelled(TOTAL_RE);
  if (!hit) return { minor: null, line: -1, uncertain: false };

  const raw = hit.amount;
  if (evidence.length === 0 || evidence.some((e) => e.minor === raw.minor)) {
    return { minor: raw.minor, line: hit.line, uncertain: false };
  }
  // A currency symbol (e.g. the UAE dirham sign) read as one or two leading
  // digits ("12125.05" for "<sign>125.05"): accept the independently printed
  // amount it ends with, and flag the total for verification.
  const suffix = evidence.find((e) => raw.text !== e.text && raw.text.endsWith(e.text) && raw.text.length - e.text.length <= 2);
  if (suffix) return { minor: suffix.minor, line: hit.line, uncertain: true };
  return { minor: raw.minor, line: hit.line, uncertain: true };
}

interface DateResult { iso: string | null; time: string | null; line: number }

/** Day-first (UAE) date; an impossible day/month is rejected, never reinterpreted. */
function dateFromParts(day: number, month: number, year: number): string | null {
  const y = year < 100 ? 2000 + year : year;
  const pad = (n: number) => String(n).padStart(2, "0");
  return normalizeDate(`${y}-${pad(month)}-${pad(day)}`);
}

function dateIn(text: string): { iso: string; index: number; length: number } | null {
  const iso = text.match(/(?<!\d)(20\d{2})[-\/.](\d{1,2})[-\/.](\d{1,2})(?!\d)/);
  if (iso && iso.index !== undefined) {
    const v = normalizeDate(`${iso[1]}-${iso[2].padStart(2, "0")}-${iso[3].padStart(2, "0")}`);
    if (v) return { iso: v, index: iso.index, length: iso[0].length };
  }
  const patterns = [
    /(?<![\d.])(\d{1,2})[-\/.](\d{1,2})[-\/.](20\d{2})(?!\d)/,
    // Two-digit years only with '-' or '/', so version strings like "1.0.19" are not dates.
    /(?<![\w.\/-])(\d{1,2})[-\/](\d{1,2})[-\/](\d{2})(?![\d\/-])/,
  ];
  for (const re of patterns) {
    const m = text.match(re);
    if (m && m.index !== undefined) {
      const d = dateFromParts(Number(m[1]), Number(m[2]), Number(m[3]));
      if (d) return { iso: d, index: m.index, length: m[0].length };
    }
  }
  const named = text.match(/(?<!\d)(\d{1,2})[\s\-\/.]*(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?[\s\-\/.,]*(20\d{2}|\d{2})(?!\d)/i);
  if (named && named.index !== undefined) {
    const d = dateFromParts(Number(named[1]), MONTHS[named[2].toLowerCase()], Number(named[3]));
    if (d) return { iso: d, index: named.index, length: named[0].length };
  }
  return null;
}

function timeIn(text: string): string | null {
  const t = text.match(TIME_RE);
  return t ? `${t[1].padStart(2, "0")}:${t[2]}${t[3] ? `:${t[3]}` : ""}` : null;
}

function parseDate(lines: string[], invoiceNumber?: string | null): DateResult {
  const order = [
    ...lines.map((l, i) => ({ l, i })).filter((x) => DATE_LABEL_RE.test(x.l)),
    ...lines.map((l, i) => ({ l, i })),
  ];
  for (const { l, i } of order) {
    const d = dateIn(l);
    if (!d) continue;
    // Time printed after the date is preferred ("12-07-2026 13:37:12").
    const time = timeIn(l.slice(d.index + d.length)) ?? timeIn(l.slice(0, d.index));
    return { iso: d.iso, time, line: i };
  }
  // Fallback: If no date line found, check if the invoice number starts with a valid YYMMDD or YYYYMMDD timestamp
  if (invoiceNumber) {
    const cleanInv = invoiceNumber.replace(/\D/g, "");
    const m6 = cleanInv.match(/^(\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])([01]\d|2[0-3])([0-5]\d)/);
    if (m6) {
      const year = Number(m6[1]) < 50 ? 2000 + Number(m6[1]) : 1900 + Number(m6[1]);
      const iso = dateFromParts(Number(m6[3]), Number(m6[2]), year);
      if (iso) return { iso, time: `${m6[4]}:${m6[5]}`, line: -1 };
    }
  }
  return { iso: null, time: null, line: -1 };
}

function isDateLike(str: string): boolean {
  return /^\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3})[-/.]\d{2,4}$/.test(str);
}

function parseId(lines: string[], primaryRe: RegExp, fallbackRe?: RegExp): { value: string | null; line: number } {
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(primaryRe);
    if (m && /\d/.test(m[1]) && !isDateLike(m[1])) return { value: m[1].replace(/[:#]+$/, ""), line: i };
  }
  if (fallbackRe) {
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(fallbackRe);
      if (m && /\d/.test(m[1]) && !isDateLike(m[1])) return { value: m[1].replace(/[:#]+$/, ""), line: i };
    }
  }
  return { value: null, line: -1 };
}

/** Vendor display name plus the raw line. Bilingual names keep the Latin part for display. */
function parseVendor(lines: string[]): { vendor: string | null; raw: string | null; line: number } {
  // An Arabic-only name line is used only when no Latin name follows within two lines.
  let arabic: { vendor: string; raw: string; line: number } | null = null;
  for (let i = 0; i < Math.min(lines.length, 8); i++) {
    if (arabic && i > arabic.line + 2) break;
    const original = lines[i];
    if (moneyIn(original).length || TOTAL_RE.test(original) || (SUBTOTAL_RE.test(original) && !SUBTOTAL_EXCLUDE_RE.test(original))) continue;
    const cut = original.match(VENDOR_CUT_RE);
    const head = (cut && cut.index !== undefined ? original.slice(0, cut.index) : original)
      .replace(/[^\p{L}\p{N}&'.\- ]/gu, " ").replace(/\s+/g, " ").trim();
    const digits = head.replace(/[\s\-+().]/g, "");
    if (head.length < 2 || /^\d+$/.test(digits) || VENDOR_SKIP_RE.test(head)) continue;
    const latin = head.replace(ARABIC_RUN, " ").replace(/\s+/g, " ").trim().replace(/^[\s.\-']+|[\s.\-']+$/g, "");
    if (/[A-Za-z].*[A-Za-z]/.test(latin)) {
      const raw = arabic ? `${arabic.raw} ${original}` : original;
      return { vendor: normalizeText(latin, 200), raw: normalizeText(raw, 300), line: i };
    }
    if (!arabic && /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]{2}/.test(head)) {
      arabic = { vendor: head, raw: original, line: i };
    }
  }
  return arabic
    ? { vendor: normalizeText(arabic.vendor, 200), raw: normalizeText(arabic.raw, 300), line: arabic.line }
    : { vendor: null, raw: null, line: -1 };
}

function parseCurrency(lines: string[]): { currency: string | null; line: number } {
  for (let i = 0; i < lines.length; i++) {
    // Check for explicit currency symbols: £ -> GBP, ₹ / Rs -> INR, € -> EUR, $ -> USD
    if (/[£]\s*\d|\d\s*[£]|\bGBP\b/i.test(lines[i])) {
      return { currency: "GBP", line: i };
    }
    if (/[₹]\s*\d|\d\s*[₹]|\b(?:INR|RS\.?|RUPEES?)\b/i.test(lines[i])) {
      return { currency: "INR", line: i };
    }
    if (/[€]\s*\d|\d\s*[€]|\bEUR\b/i.test(lines[i])) {
      return { currency: "EUR", line: i };
    }
    if (/\b(?:SAR|SR|RIYALS?)\b/i.test(lines[i])) {
      return { currency: "SAR", line: i };
    }
    if (/\b(?:QAR|QR)\b/i.test(lines[i])) {
      return { currency: "QAR", line: i };
    }
    const m = lines[i].match(/\b(AED|DHS|DIRHAMS?|USD|EUR|GBP|INR|SAR|QAR|OMR|BHD|KWD|SGD|JPY|CHF|CAD|AUD)(?![A-Za-z])|(درهم|د\.?\s?إ)/i);
    if (m) return { currency: m[2] ? "AED" : normalizeCurrency(m[1]), line: i };
    if (/[$]\s*\d|\d\s*[$]|\bUSD\b/i.test(lines[i])) {
      return { currency: "USD", line: i };
    }
  }
  // If UAE indicators are present (UAE TRN, Abu Dhabi, Dubai, etc.), infer AED
  for (let i = 0; i < lines.length; i++) {
    if (/\b(?:TRN\s*[:#]?\s*100\d{12}|Abu\s*Dhabi|Dubai|Sharjah|Ajman|Fujairah|Ras\s*Al\s*Khaimah|\bUAE\b)/i.test(lines[i])) {
      return { currency: "AED", line: i };
    }
  }
  return { currency: null, line: -1 };
}

/** Raw text lines (reading order) from NVIDIA Nemotron OCR or Tesseract. */
export function fromTextLines(
  lines: string[],
  confidences: number[],
  lineConfidences: (number | null)[] = [],
): OcrFields | null {
  const kept = lines.map((l, i) => ({ text: l.trim(), conf: lineConfidences[i] ?? null })).filter((x) => x.text);
  if (kept.length === 0) return null;
  const textLines = kept.map((x) => x.text);
  const confOf = (line: number) => (line >= 0 ? normalizeConfidence(kept[line].conf) : null);

  const vendor = parseVendor(textLines);
  const invoice = parseId(textLines, INVOICE_PRIMARY_RE, INVOICE_ORDER_RE);
  const receipt = parseId(textLines, RECEIPT_RE);
  const date = parseDate(textLines, invoice.value);
  const vat = parseVat(textLines);
  const total = parseTotal(textLines, totalEvidence(textLines, vat));
  const currency = parseCurrency(textLines);

  const uncertain: string[] = [];
  if (total.uncertain) uncertain.push("total_minor");
  if (vat.uncertain) uncertain.push("tax_minor");

  const fieldConfidence: Record<string, number> = {};
  const lineOf: Record<string, number> = {
    vendor: vendor.line, invoice_number: invoice.line, receipt_number: receipt.line, date: date.line,
    transaction_time: date.time ? date.line : -1, total_minor: total.line, tax_minor: vat.line,
    tax_rate_percent: vat.rate !== null ? vat.line : -1, currency: currency.line,
  };
  for (const [k, line] of Object.entries(lineOf)) {
    const c = confOf(line);
    if (c !== null) fieldConfidence[k] = c;
  }

  const validConf = confidences.filter((c) => typeof c === "number" && Number.isFinite(c));
  return {
    vendor: vendor.vendor,
    vendor_raw: vendor.raw,
    invoice_number: invoice.value ? normalizeText(invoice.value, 100) : null,
    receipt_number: receipt.value ? normalizeText(receipt.value, 60) : null,
    date: date.iso,
    transaction_time: date.time,
    // Only a printed, labelled subtotal is reported; it is never derived.
    subtotal_minor: parseLabelledSubtotal(textLines, vat.net),
    tax_minor: vat.tax,
    tax_rate_percent: vat.rate,
    total_minor: total.minor,
    currency: currency.currency,
    confidence_score: validConf.length
      ? normalizeConfidence(validConf.reduce((a, b) => a + b, 0) / validConf.length)
      : null,
    uncertain_fields: uncertain,
    field_confidence: fieldConfidence,
  };
}

function parseLabelledSubtotal(lines: string[], vatNet: number | null): number | null {
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (SUBTOTAL_EXCLUDE_RE.test(l)) continue;
    const m = l.match(SUBTOTAL_RE);
    if (!m || m.index === undefined) continue;
    const own = moneyIn(l.slice(m.index + m[0].length));
    if (own.length) return own[0].minor;
    if (i + 1 < lines.length && isBare(lines[i + 1])) {
      const next = moneyIn(lines[i + 1]);
      if (next.length) return next[0].minor;
    }
  }
  return vatNet ?? null;
}

/** JSON object produced by the Groq vision model (untrusted). */
export function fromGroq(extracted: any): OcrFields | null {
  if (!extracted || typeof extracted !== "object") return null;
  return {
    ...EMPTY_FIELDS,
    uncertain_fields: [],
    field_confidence: {},
    vendor: normalizeText(extracted.vendor, 200),
    invoice_number: normalizeText(extracted.invoice_number, 100),
    date: normalizeDate(extracted.date),
    subtotal_minor: majorToMinor(extracted.subtotal),
    tax_minor: majorToMinor(extracted.tax),
    total_minor: majorToMinor(extracted.total),
    currency: normalizeCurrency(extracted.currency),
    confidence_score: null,
  };
}
