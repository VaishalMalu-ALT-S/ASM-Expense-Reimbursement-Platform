// Deterministic OCR provider orchestration. Primary providers are tried one at
// a time in round-robin order (starting at the server-assigned rotation slot,
// then the remaining primaries), stopping at the first usable result; Tesseract
// runs only after every primary failed. A provider result is "usable" when
// normalization extracts at least one field (SUCCESS or PARTIAL); a PARTIAL
// result is accepted without trying further providers, and confidence alone
// never triggers fallback.

import { finalizeOcr, type OcrFields } from "./ocr_normalize.ts";

export type AttemptOutcome = "SUCCESS" | "PARTIAL" | "UNUSABLE" | "ERROR" | "TIMEOUT" | "SKIPPED";

export interface OcrAttempt {
  provider: string;
  role: "PRIMARY" | "FALLBACK";
  /** 1-based position in this request's attempt sequence. */
  order: number;
  outcome: AttemptOutcome;
  /** Safe failure category (never provider text, URLs or keys); null on success. */
  failure_reason: string | null;
  duration_ms: number;
}

/** Returns normalized fields, or null when the provider produced no meaningful text. */
export type ProviderRun = (signal: AbortSignal) => Promise<OcrFields | null>;

export interface ProviderSpec {
  name: string;
  run: ProviderRun;
  timeoutMs: number;
}

export interface OrchestratorResult {
  fields: OcrFields | null;
  provider: string | null;
  /** Primary chosen by the rotation for this request. */
  selectedProvider: string | null;
  /** True when Tesseract produced the result. */
  fallbackUsed: boolean;
  /** True when a later primary produced the result after the selected one failed. */
  providerFailover: boolean;
  attempts: OcrAttempt[];
}

export type OcrEventSink = (event: string, data: Record<string, unknown>) => void;

class ProviderTimeout extends Error {}

/** Primaries in attempt order: the rotation slot first, then the rest in sequence. */
export function rotationOrder<T>(providers: T[], slot: number): T[] {
  const n = providers.length;
  if (n === 0) return [];
  const start = ((Math.trunc(slot) % n) + n) % n;
  return [...providers.slice(start), ...providers.slice(0, start)];
}

function failureReason(err: unknown): string {
  const msg = err instanceof Error ? err.message : "";
  const http = msg.match(/HTTP (\d{3})/);
  if (http) return `HTTP_${http[1]}`;
  if (/missing text_detections|invalid/i.test(msg)) return "INVALID_RESPONSE";
  return "NETWORK_ERROR";
}

async function attempt(
  spec: ProviderSpec,
  role: "PRIMARY" | "FALLBACK",
  order: number,
  timeoutMs: number,
  emit: OcrEventSink,
): Promise<{ fields: OcrFields | null; attempt: OcrAttempt }> {
  const phase = role === "PRIMARY" ? "OCR_PRIMARY" : "OCR_FALLBACK";
  const started = Date.now();
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  emit(`${phase}_STARTED`, { provider: spec.name, order, timeout_ms: timeoutMs });

  let fields: OcrFields | null = null;
  let outcome: AttemptOutcome;
  let reason: string | null = null;
  let timedOut = false;
  try {
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        // Flag first: aborting makes the provider's fetch reject before this promise does.
        timedOut = true;
        controller.abort();
        reject(new ProviderTimeout());
      }, timeoutMs);
    });
    const result = await Promise.race([spec.run(controller.signal), timeout]);
    const status = finalizeOcr(result).status;
    if (result === null || status === "FAILED") {
      outcome = "UNUSABLE";
      reason = "UNUSABLE_RESPONSE";
    } else {
      outcome = status;
      fields = result;
    }
  } catch (err) {
    outcome = timedOut || err instanceof ProviderTimeout ? "TIMEOUT" : "ERROR";
    reason = outcome === "TIMEOUT" ? "TIMEOUT" : failureReason(err);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }

  const record: OcrAttempt = {
    provider: spec.name, role, order, outcome, failure_reason: reason, duration_ms: Date.now() - started,
  };
  emit(fields ? `${phase}_SUCCESS` : `${phase}_FAILED`, {
    provider: spec.name,
    order,
    outcome,
    failure_reason: reason,
    duration_ms: record.duration_ms,
  });
  return { fields, attempt: record };
}

function skipped(spec: ProviderSpec, role: "PRIMARY" | "FALLBACK", order: number, emit: OcrEventSink): OcrAttempt {
  emit(role === "PRIMARY" ? "OCR_PRIMARY_FAILED" : "OCR_FALLBACK_FAILED",
    { provider: spec.name, order, outcome: "SKIPPED", failure_reason: "BUDGET_EXHAUSTED", duration_ms: 0 });
  return { provider: spec.name, role, order, outcome: "SKIPPED", failure_reason: "BUDGET_EXHAUSTED", duration_ms: 0 };
}

export async function runOcrWithFallback(options: {
  /** Primary providers in configured order; tried from `rotationSlot`, one at a time. */
  primaries?: ProviderSpec[];
  /** Single primary (legacy form, equivalent to `primaries: [primary]`). */
  primary?: ProviderSpec | null;
  rotationSlot?: number;
  fallback: ProviderSpec | null;
  totalBudgetMs: number;
  emit?: OcrEventSink;
}): Promise<OrchestratorResult> {
  const { fallback, totalBudgetMs } = options;
  const emit = options.emit ?? (() => {});
  const started = Date.now();
  const attempts: OcrAttempt[] = [];
  const configured = options.primaries ?? (options.primary ? [options.primary] : []);
  const ordered = rotationOrder(configured, options.rotationSlot ?? 0);
  const selectedProvider = ordered[0]?.name ?? null;

  // Reserve the fallback's time so slow primaries cannot consume the whole budget;
  // if the budget cannot cover both, the primaries share half of it.
  const cap = totalBudgetMs - (fallback ? fallback.timeoutMs : 0);
  const primaryBudget = cap > 0 ? cap : Math.floor(totalBudgetMs / 2);

  for (const [i, spec] of ordered.entries()) {
    const remaining = primaryBudget - (Date.now() - started);
    const timeoutMs = Math.min(spec.timeoutMs, remaining);
    if (timeoutMs <= 0) {
      attempts.push(skipped(spec, "PRIMARY", attempts.length + 1, emit));
      continue;
    }
    const r = await attempt(spec, "PRIMARY", attempts.length + 1, timeoutMs, emit);
    attempts.push(r.attempt);
    if (r.fields) {
      return { fields: r.fields, provider: spec.name, selectedProvider, fallbackUsed: false, providerFailover: i > 0, attempts };
    }
  }

  if (fallback) {
    const remaining = totalBudgetMs - (Date.now() - started);
    const timeoutMs = Math.min(fallback.timeoutMs, remaining);
    if (timeoutMs <= 0) {
      attempts.push(skipped(fallback, "FALLBACK", attempts.length + 1, emit));
    } else {
      const r = await attempt(fallback, "FALLBACK", attempts.length + 1, timeoutMs, emit);
      attempts.push(r.attempt);
      if (r.fields) {
        return { fields: r.fields, provider: fallback.name, selectedProvider, fallbackUsed: true, providerFailover: false, attempts };
      }
    }
  }

  return { fields: null, provider: null, selectedProvider, fallbackUsed: false, providerFailover: false, attempts };
}
