// Round-robin OCR provider routing and fallback.
// Run: node --test supabase/tests/ocr_orchestrator.test.mts
import { test } from "node:test";
import assert from "node:assert/strict";
import { EMPTY_FIELDS, type OcrFields } from "../functions/process-receipt-ocr/ocr_normalize.ts";
import { rotationOrder, runOcrWithFallback, type ProviderSpec } from "../functions/process-receipt-ocr/ocr_orchestrator.ts";

const usable = (vendor: string): OcrFields => ({ ...EMPTY_FIELDS, uncertain_fields: [], field_confidence: {}, vendor, total_minor: 1000 });

type Behaviour = "ok" | "http" | "network" | "invalid" | "unusable" | "timeout";

function provider(name: string, behaviour: Behaviour, calls: string[], timeoutMs = 200): ProviderSpec {
  return {
    name,
    timeoutMs,
    run: (signal) => {
      calls.push(name);
      switch (behaviour) {
        case "ok": return Promise.resolve(usable(name));
        case "http": return Promise.reject(new Error("NVIDIA HTTP 429"));
        case "network": return Promise.reject(new TypeError("fetch failed"));
        case "invalid": return Promise.reject(new Error("NVIDIA response missing text_detections"));
        case "unusable": return Promise.resolve(null);
        case "timeout":
          return new Promise((_, reject) => signal.addEventListener("abort", () => reject(new Error("aborted"))));
      }
    },
  };
}

const three = (b: [Behaviour, Behaviour, Behaviour], calls: string[]) =>
  [provider("P1", b[0], calls), provider("P2", b[1], calls), provider("P3", b[2], calls)];

test("rotation order starts at the slot and wraps", () => {
  assert.deepEqual(rotationOrder(["P1", "P2", "P3"], 0), ["P1", "P2", "P3"]);
  assert.deepEqual(rotationOrder(["P1", "P2", "P3"], 1), ["P2", "P3", "P1"]);
  assert.deepEqual(rotationOrder(["P1", "P2", "P3"], 2), ["P3", "P1", "P2"]);
  assert.deepEqual(rotationOrder(["P1", "P2", "P3"], 3), ["P1", "P2", "P3"]);
  assert.deepEqual(rotationOrder([], 5), []);
});

test("consecutive requests use providers 1, 2, 3, 1 and call exactly one each", async () => {
  const used: string[] = [];
  for (const slot of [0, 1, 2, 3]) {
    const calls: string[] = [];
    const r = await runOcrWithFallback({
      primaries: three(["ok", "ok", "ok"], calls), rotationSlot: slot, fallback: provider("TESSERACT", "ok", calls), totalBudgetMs: 5000,
    });
    assert.equal(calls.length, 1, "only the selected provider is called");
    assert.equal(r.provider, r.selectedProvider);
    assert.equal(r.fallbackUsed, false);
    assert.equal(r.providerFailover, false);
    used.push(r.provider!);
  }
  assert.deepEqual(used, ["P1", "P2", "P3", "P1"]);
});

test("selected provider failure moves to the next provider and stops on its success", async () => {
  const calls: string[] = [];
  const r = await runOcrWithFallback({
    primaries: three(["ok", "http", "ok"], calls), rotationSlot: 1, fallback: provider("TESSERACT", "ok", calls), totalBudgetMs: 5000,
  });
  assert.deepEqual(calls, ["P2", "P3"], "P1 and Tesseract are never called");
  assert.equal(r.selectedProvider, "P2");
  assert.equal(r.provider, "P3");
  assert.equal(r.providerFailover, true);
  assert.equal(r.fallbackUsed, false);
  assert.deepEqual(r.attempts.map((a) => [a.order, a.provider, a.outcome, a.failure_reason]),
    [[1, "P2", "ERROR", "HTTP_429"], [2, "P3", "PARTIAL", null]], "a PARTIAL (usable) result stops the chain");
});

test("every failure kind triggers the next provider, wrapping round", async () => {
  const calls: string[] = [];
  const r = await runOcrWithFallback({
    primaries: [provider("P1", "ok", calls), provider("P2", "unusable", calls), provider("P3", "timeout", calls, 50)],
    rotationSlot: 1, fallback: provider("TESSERACT", "ok", calls), totalBudgetMs: 5000,
  });
  assert.deepEqual(calls, ["P2", "P3", "P1"]);
  assert.equal(r.provider, "P1");
  assert.deepEqual(r.attempts.map((a) => a.failure_reason), ["UNUSABLE_RESPONSE", "TIMEOUT", null]);
});

test("network and invalid-response failures are categorised safely", async () => {
  const calls: string[] = [];
  const r = await runOcrWithFallback({
    primaries: three(["network", "invalid", "ok"], calls), rotationSlot: 0, fallback: null, totalBudgetMs: 5000,
  });
  assert.equal(r.provider, "P3");
  assert.deepEqual(r.attempts.map((a) => a.failure_reason), ["NETWORK_ERROR", "INVALID_RESPONSE", null]);
  for (const a of r.attempts) assert.ok(a.duration_ms >= 0);
});

test("Tesseract runs only after all three primaries fail", async () => {
  const calls: string[] = [];
  const r = await runOcrWithFallback({
    primaries: three(["http", "network", "unusable"], calls), rotationSlot: 2, fallback: provider("TESSERACT", "ok", calls), totalBudgetMs: 5000,
  });
  assert.deepEqual(calls, ["P3", "P1", "P2", "TESSERACT"]);
  assert.equal(r.provider, "TESSERACT");
  assert.equal(r.fallbackUsed, true);
  assert.equal(r.attempts[3].role, "FALLBACK");
  assert.equal(r.attempts[3].order, 4);
});

test("when everything fails no fields are returned (nothing invented)", async () => {
  const calls: string[] = [];
  const r = await runOcrWithFallback({
    primaries: three(["http", "http", "http"], calls), rotationSlot: 0, fallback: provider("TESSERACT", "unusable", calls), totalBudgetMs: 5000,
  });
  assert.equal(r.fields, null);
  assert.equal(r.provider, null);
  assert.equal(r.fallbackUsed, false);
  assert.equal(r.attempts.length, 4);
});

test("Tesseract time is reserved; primaries beyond the budget are skipped, not raced", async () => {
  const calls: string[] = [];
  const r = await runOcrWithFallback({
    primaries: [provider("P1", "timeout", calls, 300), provider("P2", "timeout", calls, 300), provider("P3", "ok", calls, 300)],
    rotationSlot: 0, fallback: provider("TESSERACT", "ok", calls, 200), totalBudgetMs: 600,
  });
  assert.deepEqual(calls, ["P1", "P2", "TESSERACT"]);
  assert.equal(r.attempts[2].outcome, "SKIPPED");
  assert.equal(r.attempts[2].failure_reason, "BUDGET_EXHAUSTED");
  assert.equal(r.provider, "TESSERACT");
});

test("legacy single-primary form still works", async () => {
  const calls: string[] = [];
  const r = await runOcrWithFallback({ primary: provider("NVIDIA", "ok", calls), fallback: null, totalBudgetMs: 1000 });
  assert.equal(r.provider, "NVIDIA");
  assert.deepEqual(calls, ["NVIDIA"]);
});
