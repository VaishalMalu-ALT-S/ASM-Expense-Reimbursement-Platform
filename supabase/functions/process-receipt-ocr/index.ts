// ============================================================================
// Supabase Edge Function: process-receipt-ocr
// 1. Authenticates the caller's JWT
// 2. Accepts only receipts stored under the caller's own folder
// 3. Generates a short-lived signed URL for the private receipt image
// 4. OCR: NVIDIA Nemotron OCR v2 primaries (one per configured API key) in
//    round-robin order from a database sequence; on failure the next primary
//    is tried, and Tesseract (ASM OCR service) runs only if every primary failed
// 5. Normalizes untrusted output; never fabricates missing values
// 6. Stages the result in expense_ocr_results (linked to the expense and
//    receipt by create_expense_with_receipt once the employee verifies it)
// ============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { finalizeOcr, fromMicroservice, fromTextLines, linesFromDetections, type OcrFields } from "./ocr_normalize.ts";
import { type ProviderSpec, runOcrWithFallback } from "./ocr_orchestrator.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const NVIDIA_OCR_URL = "https://ai.api.nvidia.com/v1/cv/nvidia/nemotron-ocr-v2";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function envMs(name: string, fallback: number): number {
  const v = Number(Deno.env.get(name));
  return Number.isFinite(v) && v > 0 ? v : fallback;
}

/** OCR service endpoints must be HTTPS; anything else is treated as not configured. */
function httpsEndpoint(name: string): string | null {
  const v = (Deno.env.get(name) ?? "").trim();
  if (!v) return null;
  if (!v.startsWith("https://")) {
    console.warn(JSON.stringify({ event: "OCR_CONFIG_REJECTED", setting: name, reason: "endpoint must use https" }));
    return null;
  }
  return v;
}

async function postOcrService(url: string, apiKey: string, imageUrl: string, signal: AbortSignal): Promise<OcrFields | null> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-API-KEY": apiKey },
    body: JSON.stringify({ image_url: imageUrl }),
    signal,
  });
  if (!res.ok) throw new Error(`OCR service HTTP ${res.status}`);
  return fromMicroservice(await res.json());
}

type ImageLoader = (signal: AbortSignal) => Promise<string>;

/** Downloads the receipt once per request as a data URL; a failed download is retried by the next attempt. */
function receiptImageLoader(imageUrl: string): ImageLoader {
  let pending: Promise<string> | null = null;
  return (signal) => {
    if (!pending) {
      pending = (async () => {
        const img = await fetch(imageUrl, { signal });
        if (!img.ok) throw new Error(`Receipt fetch HTTP ${img.status}`);
        const bytes = new Uint8Array(await img.arrayBuffer());
        let binary = "";
        for (let i = 0; i < bytes.byteLength; i++) binary += String.fromCharCode(bytes[i]);
        return `data:${img.headers.get("content-type") || "image/jpeg"};base64,${btoa(binary)}`;
      })();
      pending.catch(() => { pending = null; });
    }
    return pending;
  };
}

/** Configured NVIDIA keys (server-side secrets only), in rotation order. */
function nvidiaKeys(): string[] {
  return ["NVIDIA_API_KEY", "NVIDIA_API_KEY_2", "NVIDIA_API_KEY_3"]
    .map((name) => (Deno.env.get(name) ?? "").trim())
    .filter(Boolean);
}

// Used only when the shared database rotation counter is unavailable.
let localRotation = 0;

/** Next round-robin slot from the database sequence, so rotation is shared by all function instances. */
async function nextRotationSlot(supabase: any, count: number, emit: (e: string, d: Record<string, unknown>) => void): Promise<number> {
  if (count <= 1) return 0;
  const { data, error } = await supabase.rpc("next_ocr_provider_slot", { p_provider_count: count });
  if (!error && Number.isInteger(data)) return data;
  emit("OCR_ROTATION_FALLBACK", { reason: "rotation counter unavailable; using per-instance counter" });
  return localRotation++ % count;
}

async function nvidiaDirect(apiKey: string, loadImage: ImageLoader, signal: AbortSignal): Promise<OcrFields | null> {
  const dataUrl = await loadImage(signal);
  const res = await fetch(NVIDIA_OCR_URL, {
    method: "POST",
    headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify({ input: [{ type: "image_url", url: dataUrl }] }),
    signal,
  });
  if (!res.ok) throw new Error(`NVIDIA HTTP ${res.status}`);
  const body = await res.json();
  const detections = body?.data?.[0]?.text_detections;
  if (!Array.isArray(detections)) throw new Error("NVIDIA response missing text_detections");
  const { lines, confidences, lineConfidences } = linesFromDetections(detections.map((d: any) => ({
    text: d?.text_prediction?.text || "",
    confidence: d?.text_prediction?.confidence,
    points: Array.isArray(d?.bounding_box?.points) ? d.bounding_box.points : undefined,
  })));
  return fromTextLines(lines, confidences, lineConfidences);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!jwt) {
      return json({ success: false, status: "FAILED", code: "NOT_AUTHENTICATED", message: "Missing authorization." }, 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey, { auth: { persistSession: false } });

    const { data: { user }, error: userError } = await supabase.auth.getUser(jwt);
    if (userError || !user) {
      return json({ success: false, status: "FAILED", code: "NOT_AUTHENTICATED", message: "Your session has expired. Please sign in again." }, 401);
    }

    const body = await req.json().catch(() => ({}));
    const receiptStoragePath = body?.receiptStoragePath;
    if (
      typeof receiptStoragePath !== "string" ||
      !receiptStoragePath.startsWith(`${user.id}/`) ||
      receiptStoragePath.includes("..")
    ) {
      return json({ success: false, status: "FAILED", code: "RECEIPT_NOT_OWNED", message: "Receipt not found for your account." }, 403);
    }

    const { data: signedData, error: signError } = await supabase.storage
      .from("receipts")
      .createSignedUrl(receiptStoragePath, 60);
    if (signError || !signedData?.signedUrl) {
      return json({ success: false, status: "FAILED", code: "RECEIPT_FILE_NOT_FOUND", message: "Receipt upload was not found. Please upload it again." }, 404);
    }
    const imageUrl = signedData.signedUrl;

    const serviceKey = Deno.env.get("UNLIMITED_OCR_SERVICE_KEY") || "";
    const nvidiaServiceUrl = httpsEndpoint("UNLIMITED_OCR_ENDPOINT");
    const tesseractUrl = httpsEndpoint("TESSERACT_OCR_ENDPOINT");
    const nvidiaTimeout = envMs("NVIDIA_TIMEOUT_MS", 15000);

    // Primaries: NVIDIA directly with each configured key (round-robin), otherwise through the OCR service.
    const loadImage = receiptImageLoader(imageUrl);
    const keys = nvidiaKeys();
    const primaries: ProviderSpec[] = keys.length
      ? keys.map((key, i) => ({ name: `NVIDIA_${i + 1}`, timeoutMs: nvidiaTimeout, run: (s: AbortSignal) => nvidiaDirect(key, loadImage, s) }))
      : nvidiaServiceUrl && serviceKey
        ? [{ name: "NVIDIA", timeoutMs: nvidiaTimeout, run: (s: AbortSignal) => postOcrService(nvidiaServiceUrl, serviceKey, imageUrl, s) }]
        : [];
    const fallback: ProviderSpec | null = tesseractUrl && serviceKey
      ? { name: "TESSERACT", timeoutMs: envMs("TESSERACT_TIMEOUT_MS", 20000), run: (s) => postOcrService(tesseractUrl, serviceKey, imageUrl, s) }
      : null;

    // Correlates log events with the staged OCR row; logs never contain images, text or keys.
    const requestId = crypto.randomUUID();
    const emit = (event: string, data: Record<string, unknown>) =>
      console.log(JSON.stringify({ event, request_id: requestId, ...data }));

    const rotationSlot = await nextRotationSlot(supabase, primaries.length, emit);
    const run = await runOcrWithFallback({
      primaries,
      rotationSlot,
      fallback,
      totalBudgetMs: envMs("OCR_TOTAL_BUDGET_MS", 38000),
      emit,
    });
    const outcome = finalizeOcr(run.fields);

    const { data: staged, error: stageError } = await supabase
      .from("expense_ocr_results")
      .insert({
        employee_id: user.id,
        storage_path: receiptStoragePath,
        expense_id: null,
        raw_ocr_response: {
          request_id: requestId,
          provider: run.provider,
          selected_provider: run.selectedProvider,
          rotation_slot: rotationSlot,
          fallback_used: run.fallbackUsed,
          provider_failover: run.providerFailover,
          attempts: run.attempts,
          ...outcome,
        },
        extracted_vendor: outcome.vendor,
        extracted_invoice_number: outcome.invoice_number,
        extracted_date: outcome.date,
        extracted_total_minor: outcome.total_minor,
        extracted_tax_minor: outcome.tax_minor,
        extracted_currency: outcome.currency,
        confidence_score: outcome.confidence_score,
        ocr_status: outcome.status,
        missing_fields: outcome.missing_fields,
        is_verified_by_user: false,
      })
      .select("id")
      .single();
    if (stageError) console.error(JSON.stringify({ event: "OCR_STAGE_FAILED", request_id: requestId }));
    emit("OCR_COMPLETED", {
      ocr_result_id: staged?.id ?? null,
      provider: run.provider,
      selected_provider: run.selectedProvider,
      fallback_used: run.fallbackUsed,
      provider_failover: run.providerFailover,
      attempt_count: run.attempts.length,
      status: outcome.status,
    });

    const { status, missing_fields, ...data } = outcome;
    return json({
      success: status !== "FAILED",
      status,
      ocr_result_id: staged?.id ?? null,
      provider: run.provider,
      fallback_used: run.fallbackUsed,
      missing_fields,
      data: status === "FAILED" ? null : data,
      message: status === "FAILED"
        ? "The receipt could not be read automatically. Please enter the details manually."
        : status === "PARTIAL"
          ? "Some receipt details could not be read. Please complete the missing fields."
          : "Receipt details extracted. Please verify every field before saving.",
    });
  } catch (error) {
    console.error(JSON.stringify({ event: "OCR_FUNCTION_ERROR", error: error instanceof Error ? error.name : "unknown" }));
    return json({ success: false, status: "FAILED", code: "OCR_UNAVAILABLE", message: "Receipt reading is temporarily unavailable. Please enter the details manually." }, 500);
  }
});
