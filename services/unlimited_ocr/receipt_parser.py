"""Contextual receipt parser for OCR text lines (NVIDIA Nemotron or Tesseract).

Values are taken only from labelled positions; nothing is chosen because it is
the largest, first or last number on the receipt. Undetected fields are None.
Kept rule-for-rule in step with
supabase/functions/process-receipt-ocr/ocr_normalize.ts (fromTextLines).
"""
import re
from datetime import date as _date
from typing import Dict, List, Optional, Sequence, Tuple

ARABIC_RUN = re.compile(r"[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]+")
# Two-decimal amount with optional thousands separators; handles thermal spacing ("35. 65").
MONEY_RE = re.compile(r"(?<![\d.,:])(\d{1,3}(?:,\d{3})+\.\s*\d{2}|\d+\.\s*\d{2})(?!\d|[.,]\d)")
# Table-cell amount where thermal OCR may print the decimal point as ':' ("5:95").
CELL_MONEY_RE = re.compile(r"(?<![\d.,:])(\d{1,6})([.:])(\d{2})(?![\d.,:])")
CURRENCY_WORD_RE = re.compile(r"\b(?:AED|DHS|DIRHAMS?|USD|EUR)(?![A-Za-z])|درهم|د\.?\s?إ", re.IGNORECASE)

SUBTOTAL_RE = re.compile(r"\b(?:su[bhn]\s*-?\s*tota[li|1]|taxab[li|1]e\s*(?:amount)?|net\s*amount)\b|المبلغ\s*الخاضع|الخاضع\s*للضريبة", re.IGNORECASE)
SUBTOTAL_EXCLUDE_RE = re.compile(r"\b(?:item|qty|description|price)\s+su[bhn]total\b", re.IGNORECASE)
TOTAL_STRONG_RE = re.compile(
    r"\b(?:grand\s*tota[li|1]|net\s*tota[li|1]|total\s*(?:due|payable)|amount\s*(?:due|payable)|balance\s*due)\b|المبلغ\s*الإجمالي|المبلغ\s*الاجمالي|صافي\s*المبلغ|\bilaaall\b", re.IGNORECASE)
TOTAL_RE = re.compile(r"\btota[li|1]\b|\bمجموع\b|\bالإجمالي\b|\bالاجمالي\b|\bالمبلغ\b", re.IGNORECASE)
TOTAL_EXCLUDE_RE = re.compile(
    r"\btota[li|1]\s*(?:vat|tax|qty|quantity|items?|discount|savings?|points?|excl\w*|before)\b|\bpoints?\b", re.IGNORECASE)
PAYMENT_RE = re.compile(
    r"\b(?:pa[yv]\w*|paid|bank|card|credit|debit|visa|mastercard|master\s*card|amex|tender\w*|nfc|apple\s*pay|google\s*pay)\b",
    re.IGNORECASE)
VATISH_RE = re.compile(r"\bva[t1il!|]\b|\bvat|\btax\b", re.IGNORECASE)
VAT_SUMMARY_RE = re.compile(
    r"\b(?:tax\s*amount|vat\s*amount|total\s*vat|total\s*tax|net\s*vat)\b|قيمة\s*الضريبة|مبلغ\s*الضريبة",
    re.IGNORECASE)
VAT_LINE_RE = re.compile(r"\b(?:vat|tax)\b", re.IGNORECASE)
VAT_LINE_EXCLUDE_RE = re.compile(
    r"\b(?:ta[xk]\s*inv\w*|vat\s*(?:no|reg\w*|#|number|id)|trn|inclusive|incl\.?|excl\w*|summary|taxab[li|1]e)\b",
    re.IGNORECASE)
PERCENT_RE = re.compile(r"(\d{1,2}(?:\.\d{1,2})?)\s*%")
DATE_LABEL_RE = re.compile(r"\b(?:d[a@]te|dated|dt|till)\b", re.IGNORECASE)
TIME_RE = re.compile(r"(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?(?![\d:])")
_NUMBER_MARK = r"(?:\b(?:n[o0c]\b\.?|no\.|num(?:ber)?\b\.?|[o0]\b)|#)"
_ID_VALUE = r"([A-Za-z0-9][A-Za-z0-9/\-_]{2,39})"
# OCR-tolerant labels: "Tnvo1ce No", "Recelpt Nc", "Bill No", "Sill N No", "Inv. #: 69903", "رقم الفاتورة".
# A number marker or colon is required, so a "Tax Invoice" heading is never read as an invoice number.
INVOICE_PRIMARY_RE = re.compile(
    r"(?:^|[^\w])(?:(?:[i1l|t]nv[o0][i1l]ce|inv|[b83s][i1l|]ll|b\.?no|bill)\b[\s\w.#\-]*?" + _NUMBER_MARK + r"|(?:[i1l|t]nv[o0][i1l]ce|inv|[b83s][i1l|]ll)\s*[:#]|(?:^|\s)no\s*[:#]|رقم\s*الفاتور[ةه]|فاتور[ةه]\s*رقم|رقم\s*الإيصال|رقم\s*الايصال)\s*[:.#\-]*\s*" + _ID_VALUE,
    re.IGNORECASE)
INVOICE_ORDER_RE = re.compile(
    r"(?:^|[^\w])(?:order\s*(?:no|#|num)|talabat\s*#)\s*[:.#\-]*\s*" + _ID_VALUE,
    re.IGNORECASE)
RECEIPT_RE = re.compile(
    r"(?:^|[^A-Za-z])(?:(?:r[e3]c[e3][i1l]pt|rcpt|rct)\s*" + _NUMBER_MARK + r"|r[e3]c[e3][i1l]pt\s*[:#])\s*[:.#\-]*\s*" + _ID_VALUE,
    re.IGNORECASE)
VENDOR_CUT_RE = re.compile(
    r"\b(?:ta[xk]\s+[i1l|t][nm]\w*|tax\s*receipt|trn\b|tsn\b|vat\s*(?:no|reg\w*|#)|tel\b|phone\b|mob\w*|p\.?\s*o\.?\s*box|po\s*box|box\s*\d|branch\b|br-\d+|fax\b)|\d{8,}",
    re.IGNORECASE)
VENDOR_SKIP_RE = re.compile(
    r"^(?:tax\s*invoice|invoice|receipt|welcome|date|cashier|order|customer\s*copy|merchant\s*copy|duplicate|original|talabat|noon)\b",
    re.IGNORECASE)
MONTHS = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8,
          "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12}

Amount = Tuple[str, int]


def to_minor(amount: str) -> Optional[int]:
    """Decimal string to minor units without float arithmetic."""
    clean = re.sub(r"[\s,]", "", amount).strip()
    m = re.fullmatch(r"(\d{1,9})(?:\.(\d{1,2}))?", clean)
    if not m:
        return None
    return int(m.group(1)) * 100 + int((m.group(2) or "").ljust(2, "0"))


def money_in(text: str) -> List[Amount]:
    out = []
    for m in MONEY_RE.finditer(text):
        clean = re.sub(r"[\s,]", "", m.group(1))
        minor = to_minor(clean)
        if minor is not None:
            out.append((clean, minor))
    return out


def cell_money_in(text: str) -> List[Amount]:
    out = []
    for m in CELL_MONEY_RE.finditer(text):
        # "13:37" is a clock time, not an amount.
        if m.group(2) == ":" and int(m.group(1)) <= 23 and int(m.group(3)) <= 59:
            continue
        s = f"{m.group(1)}.{m.group(3)}"
        out.append((s, to_minor(s)))
    return out


def is_bare(text: str) -> bool:
    """Line that carries amounts but no label of its own."""
    return not re.search(r"[A-Za-z\u0600-\u06FF]", CURRENCY_WORD_RE.sub("", text))


def parse_vat(lines: Sequence[str]) -> dict:
    # 1. VAT summary table: a header naming the rate, then rows "code  net  rate%  vat".
    for i, header in enumerate(lines):
        if not re.search(r"\brate\b", header, re.IGNORECASE) or not VATISH_RE.search(header):
            continue
        tax = net = found = 0
        net_known = True
        rates = set()
        last = i
        for j in range(i + 1, min(len(lines), i + 5)):
            pm = PERCENT_RE.search(lines[j])
            if not pm:
                if found:
                    break
                continue
            after = cell_money_in(lines[j][pm.end():])
            if not after:
                continue
            before = cell_money_in(lines[j][:pm.start()])
            tax += after[0][1]
            if before:
                net += before[-1][1]
            else:
                net_known = False
            rates.add(float(pm.group(1)))
            found += 1
            last = j
        if found:
            rate = next(iter(rates)) if len(rates) == 1 else None
            has_net = net_known and net > 0
            # Rounded VAT must agree with net x rate to within one minor unit, or match standard 5% UAE VAT.
            is_uae_vat = abs(tax * 100 - net * 5) <= 100
            consistent = not has_net or rate is None or abs(tax * 100 - net * rate) <= 100 or is_uae_vat
            return {"tax": tax, "rate": 5.0 if is_uae_vat and rate == 6 else rate, "net": net if has_net else None, "line": last, "uncertain": not consistent}

    # Helper to discover tax rate anywhere on the receipt if not on the VAT summary line itself.
    def find_fallback_rate() -> Optional[float]:
        for l in lines:
            pm = PERCENT_RE.search(l)
            if pm and VATISH_RE.search(l):
                val = float(pm.group(1))
                if 0 < val <= 30:
                    return val
        return None

    # 2. Explicit summary Tax/VAT line: "Tax Amount: 0.21", "VAT Amount: 5.95", "قيمة الضريبة 0.21", "Total VAT AED 4.50"
    for i, line in enumerate(lines):
        if not VAT_SUMMARY_RE.search(line) or VAT_LINE_EXCLUDE_RE.search(line):
            continue
        pm = PERCENT_RE.search(line)
        rate = float(pm.group(1)) if pm else find_fallback_rate()

        own = money_in(line)
        if own:
            return {"tax": own[-1][1], "rate": rate, "net": None, "line": i, "uncertain": False}
        if i + 1 < len(lines) and is_bare(lines[i + 1]):
            next_amounts = money_in(lines[i + 1])
            if next_amounts:
                return {"tax": next_amounts[0][1], "rate": rate, "net": None, "line": i + 1, "uncertain": False}
        if i > 0:
            prev_amounts = money_in(lines[i - 1])
            if prev_amounts and (is_bare(lines[i - 1]) or len(prev_amounts) > 1):
                return {"tax": prev_amounts[-1][1], "rate": rate, "net": None, "line": i - 1, "uncertain": False}

    # 3. Inline VAT line fallback: "VAT 5% 12.00", skipping item-level notes like "@ 5.00%"
    for i, line in enumerate(lines):
        if not VAT_LINE_RE.search(line) or VAT_LINE_EXCLUDE_RE.search(line):
            continue
        if re.search(r"@\s*\d", line):
            continue
        pm = PERCENT_RE.search(line)
        amounts = money_in(line[pm.end():] if pm else line)
        if not amounts:
            continue
        return {"tax": (amounts[0] if pm else amounts[-1])[1], "rate": float(pm.group(1)) if pm else None,
                "net": None, "line": i, "uncertain": False}
    return {"tax": None, "rate": None, "net": None, "line": -1, "uncertain": False}


def total_evidence(lines: Sequence[str], vat: dict) -> List[Amount]:
    """Amounts printed independently of the total line (card/bank payment, VAT summary net + VAT)."""
    ev: List[Amount] = []
    for i, line in enumerate(lines):
        if not PAYMENT_RE.search(line) or TOTAL_RE.search(line) or SUBTOTAL_RE.search(line):
            continue
        own = money_in(line)
        if own:
            ev.extend(own)
        elif i + 1 < len(lines) and is_bare(lines[i + 1]):
            ev.extend(money_in(lines[i + 1]))
    if vat["tax"] is not None and vat["net"] is not None and not vat["uncertain"]:
        total = vat["tax"] + vat["net"]
        ev.append((f"{total // 100}.{total % 100:02d}", total))
    return ev


def parse_total(lines: Sequence[str], evidence: List[Amount]) -> dict:
    def labelled(rx):
        for i, line in enumerate(lines):
            m = rx.search(line)
            if not m or SUBTOTAL_RE.search(line) or TOTAL_EXCLUDE_RE.search(line):
                continue
            own = money_in(line[m.end():])
            if own:
                return own[-1], i
            split_dot = re.search(r"(?<![\d.])(\d+)\.\s*$", line)
            if split_dot and i + 1 < len(lines) and is_bare(lines[i + 1]):
                next_digits = re.match(r"^(\d{2})\b", lines[i + 1].strip())
                if next_digits:
                    combined = split_dot.group(1) + "." + next_digits.group(1)
                    minor = to_minor(combined)
                    if minor is not None:
                        return (combined, minor), i
            if i + 1 < len(lines) and is_bare(lines[i + 1]) and money_in(lines[i + 1]):
                return money_in(lines[i + 1])[0], i + 1
            if i > 0 and is_bare(lines[i - 1]) and money_in(lines[i - 1]):
                return money_in(lines[i - 1])[-1], i - 1
        return None

    hit = labelled(TOTAL_STRONG_RE) or labelled(TOTAL_RE)
    if not hit:
        return {"minor": None, "line": -1, "uncertain": False}
    (raw_text, raw_minor), line = hit
    if not evidence or any(e[1] == raw_minor for e in evidence):
        return {"minor": raw_minor, "line": line, "uncertain": False}
    # A currency symbol (e.g. the UAE dirham sign) read as one or two leading
    # digits ("12125.05" for "<sign>125.05"): accept the independently printed
    # amount it ends with, and flag the total for verification.
    for e_text, e_minor in evidence:
        if raw_text != e_text and raw_text.endswith(e_text) and len(raw_text) - len(e_text) <= 2:
            return {"minor": e_minor, "line": line, "uncertain": True}
    return {"minor": raw_minor, "line": line, "uncertain": True}


def _iso(year: int, month: int, day: int) -> Optional[str]:
    try:
        return _date(2000 + year if year < 100 else year, month, day).isoformat()
    except ValueError:
        return None


def date_in(text: str) -> Optional[Tuple[str, int, int]]:
    """(iso, start, end). Day-first (UAE); an impossible day/month is rejected, never reinterpreted."""
    m = re.search(r"(?<!\d)(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)", text)
    if m:
        v = _iso(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        if v:
            return v, m.start(), m.end()
    for rx in (r"(?<![\d.])(\d{1,2})[-/.](\d{1,2})[-/.](20\d{2})(?!\d)",
               # Two-digit years only with '-' or '/', so version strings like "1.0.19" are not dates.
               r"(?<![\w./-])(\d{1,2})[-/](\d{1,2})[-/](\d{2})(?![\d/-])"):
        m = re.search(rx, text)
        if m:
            v = _iso(int(m.group(3)), int(m.group(2)), int(m.group(1)))
            if v:
                return v, m.start(), m.end()
    m = re.search(r"(?<!\d)(\d{1,2})[\s\-/.]*(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?[\s\-/.,]*(20\d{2}|\d{2})(?!\d)",
                  text, re.IGNORECASE)
    if m:
        v = _iso(int(m.group(3)), MONTHS[m.group(2).lower()], int(m.group(1)))
        if v:
            return v, m.start(), m.end()
    return None


def _time_in(text: str) -> Optional[str]:
    t = TIME_RE.search(text)
    if not t:
        return None
    return f"{int(t.group(1)):02d}:{t.group(2)}" + (f":{t.group(3)}" if t.group(3) else "")


def parse_date(lines: Sequence[str], invoice_number: Optional[str] = None) -> dict:
    order = [i for i, l in enumerate(lines) if DATE_LABEL_RE.search(l)] + list(range(len(lines)))
    for i in order:
        found = date_in(lines[i])
        if not found:
            continue
        iso, start, end = found
        # Time printed after the date is preferred ("12-07-2026 13:37:12").
        time = _time_in(lines[i][end:]) or _time_in(lines[i][:start])
        return {"iso": iso, "time": time, "line": i}
    if invoice_number:
        clean_inv = re.sub(r"\D", "", invoice_number)
        m6 = re.match(r"^(\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])([01]\d|2[0-3])([0-5]\d)", clean_inv)
        if m6:
            year = 2000 + int(m6.group(1)) if int(m6.group(1)) < 50 else 1900 + int(m6.group(1))
            iso = _iso(year, int(m6.group(2)), int(m6.group(3)))
            if iso:
                return {"iso": iso, "time": f"{m6.group(4)}:{m6.group(5)}", "line": -1}
    return {"iso": None, "time": None, "line": -1}


def is_date_like(s: str) -> bool:
    return bool(re.match(r"^\d{1,2}[-/.](?:\d{1,2}|[A-Za-z]{3})[-/.]\d{2,4}$", s))


def parse_id(lines: Sequence[str], primary_rx, fallback_rx=None) -> Tuple[Optional[str], int]:
    for i, line in enumerate(lines):
        m = primary_rx.search(line)
        if m and re.search(r"\d", m.group(1)) and not is_date_like(m.group(1)):
            return re.sub(r"[:#]+$", "", m.group(1)), i
    if fallback_rx:
        for i, line in enumerate(lines):
            m = fallback_rx.search(line)
            if m and re.search(r"\d", m.group(1)) and not is_date_like(m.group(1)):
                return re.sub(r"[:#]+$", "", m.group(1)), i
    return None, -1


def parse_vendor(lines: Sequence[str]) -> Tuple[Optional[str], Optional[str], int]:
    """Vendor display name, raw line(s) and line index. Bilingual names keep the Latin part for display."""
    arabic = None
    for i, original in enumerate(lines[:8]):
        if arabic and i > arabic[2] + 2:
            break
        if money_in(original) or TOTAL_RE.search(original) or (SUBTOTAL_RE.search(original) and not SUBTOTAL_EXCLUDE_RE.search(original)):
            continue
        cut = VENDOR_CUT_RE.search(original)
        head = original[:cut.start()] if cut else original
        head = re.sub(r"\s+", " ", re.sub(r"[^\w&'.\- ]", " ", head)).strip()
        digits = re.sub(r"[\s\-+().]", "", head)
        if len(head) < 2 or digits.isdigit() or VENDOR_SKIP_RE.search(head):
            continue
        latin = re.sub(r"\s+", " ", ARABIC_RUN.sub(" ", head)).strip().strip(" .-'")
        if re.search(r"[A-Za-z].*[A-Za-z]", latin):
            raw = f"{arabic[1]} {original}" if arabic else original
            return latin[:200], raw.strip()[:300], i
        if not arabic and re.search(r"[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]{2}", head):
            arabic = (head, original, i)
    if arabic:
        return arabic[0][:200], arabic[1].strip()[:300], arabic[2]
    return None, None, -1


def parse_currency(lines: Sequence[str]) -> Tuple[Optional[str], int]:
    for i, line in enumerate(lines):
        m = re.search(r"\b(AED|DHS|DIRHAMS?|USD|EUR)(?![A-Za-z])|(درهم|د\.?\s?إ)", line, re.IGNORECASE)
        if m:
            if m.group(2):
                return "AED", i
            c = m.group(1).upper()
            return ("AED" if c in ("DHS", "DIRHAM", "DIRHAMS") else c), i
    for i, line in enumerate(lines):
        if re.search(r"\b(?:TRN\s*[:#]?\s*100\d{12}|Abu\s*Dhabi|Dubai|Sharjah|Ajman|Fujairah|Ras\s*Al\s*Khaimah|\bUAE\b)", line, re.IGNORECASE):
            return "AED", i
    return None, -1


def parse_labelled_subtotal(lines: Sequence[str], vat_net: Optional[int] = None) -> Optional[int]:
    for i, line in enumerate(lines):
        if SUBTOTAL_EXCLUDE_RE.search(line):
            continue
        m = SUBTOTAL_RE.search(line)
        if m:
            own = money_in(line[m.end():])
            if own:
                return own[0][1]
            if i + 1 < len(lines) and is_bare(lines[i + 1]):
                next_amounts = money_in(lines[i + 1])
                if next_amounts:
                    return next_amounts[0][1]
    return vat_net


def parse_receipt(lines: Sequence[str], line_confidences: Optional[Sequence[Optional[float]]] = None) -> dict:
    """Receipt fields from reading-order lines. Only a printed, labelled subtotal is
    reported (never derived); field confidence is the provider confidence of the
    line a value was read from, and is omitted when the provider gives none."""
    kept = [(l.strip(), (line_confidences[i] if line_confidences and i < len(line_confidences) else None))
            for i, l in enumerate(lines) if l and l.strip()]
    text = [k[0] for k in kept]

    vendor, vendor_raw, vendor_line = parse_vendor(text)
    invoice, invoice_line = parse_id(text, INVOICE_PRIMARY_RE, INVOICE_ORDER_RE)
    receipt, receipt_line = parse_id(text, RECEIPT_RE)
    dt = parse_date(text, invoice)
    vat = parse_vat(text)
    total = parse_total(text, total_evidence(text, vat))
    currency, currency_line = parse_currency(text)

    uncertain = []
    if total["uncertain"]:
        uncertain.append("total_minor")
    if vat["uncertain"]:
        uncertain.append("tax_minor")

    line_of = {
        "vendor": vendor_line, "invoice_number": invoice_line, "receipt_number": receipt_line,
        "date": dt["line"], "transaction_time": dt["line"] if dt["time"] else -1,
        "total_minor": total["line"], "tax_minor": vat["line"],
        "tax_rate_percent": vat["line"] if vat["rate"] is not None else -1, "currency": currency_line,
    }
    field_confidence: Dict[str, float] = {}
    for key, line in line_of.items():
        if line >= 0 and kept[line][1] is not None:
            field_confidence[key] = round(float(kept[line][1]), 4)

    tax, total_minor = vat["tax"], total["minor"]
    if tax is not None and total_minor is not None and tax >= total_minor:
        tax = None
    return {
        "vendor": vendor,
        "vendor_raw": vendor_raw,
        "invoice_number": invoice[:100] if invoice else None,
        "receipt_number": receipt[:60] if receipt else None,
        "date": dt["iso"],
        "transaction_time": dt["time"],
        "subtotal_minor": parse_labelled_subtotal(text, vat["net"]),
        "tax_minor": tax,
        "tax_rate_percent": vat["rate"],
        "total_minor": total_minor,
        "currency": currency,
        "uncertain_fields": uncertain,
        "field_confidence": field_confidence,
    }
