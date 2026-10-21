import base64
import hmac
import io
import json
import logging
import os
import threading
from urllib.parse import urlparse
from typing import Dict, List, Optional, Tuple
from fastapi import FastAPI, HTTPException, Security, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.security.api_key import APIKeyHeader
from pydantic import BaseModel
import requests
from PIL import Image

import receipt_parser
import tesseract_ocr

# -----------------------------------------------------------------------------
# ASM Expense Platform — OCR Microservice
# /api/v1/extract            NVIDIA Nemotron OCR v2 (primary provider)
# /api/v1/extract/tesseract  Tesseract OCR (secondary / fallback provider)
# -----------------------------------------------------------------------------

app = FastAPI(
    title="ASM Expense — NVIDIA Nemotron OCR v2 Service",
    description="Enterprise receipt extraction microservice powered by NVIDIA Nemotron OCR v2",
    version="2.0.0"
)

logger = logging.getLogger("asm_ocr")

# Called server-to-server by the process-receipt-ocr Edge Function; browser
# origins are only allowed when explicitly configured.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in os.getenv("OCR_ALLOWED_ORIGINS", "").split(",") if o.strip()],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type", "X-API-KEY"],
)

API_KEY_NAME = "X-API-KEY"
api_key_header = APIKeyHeader(name=API_KEY_NAME, auto_error=False)

NVIDIA_API_KEY = os.getenv("NVIDIA_API_KEY", "").strip()
NVIDIA_OCR_URL = os.getenv(
    "NVIDIA_OCR_URL",
    "https://ai.api.nvidia.com/v1/cv/nvidia/nemotron-ocr-v2"
)
SERVICE_API_KEY = os.getenv("UNLIMITED_OCR_SERVICE_KEY", "").strip()
# Hosts image_url may point to (e.g. "<project-ref>.supabase.co"); empty = image_url disabled
ALLOWED_IMAGE_HOSTS = {h.strip().lower() for h in os.getenv("OCR_ALLOWED_IMAGE_HOSTS", "").split(",") if h.strip()}
MAX_IMAGE_BYTES = int(os.getenv("OCR_MAX_IMAGE_BYTES", str(10 * 1024 * 1024)))
NVIDIA_TIMEOUT_SECONDS = float(os.getenv("NVIDIA_TIMEOUT_SECONDS", "12"))
# Base64 image plus JSON envelope; enforced before the body is read.
MAX_REQUEST_BYTES = (MAX_IMAGE_BYTES * 4) // 3 + 64 * 1024
_tesseract_slots = threading.BoundedSemaphore(int(os.getenv("TESSERACT_MAX_CONCURRENCY", "2")))


@app.middleware("http")
async def limit_request_size(request: Request, call_next):
    if request.method == "POST":
        length = request.headers.get("content-length")
        if length is None:
            return JSONResponse({"detail": "Content-Length is required."}, status_code=411)
        if not length.isdigit() or int(length) > MAX_REQUEST_BYTES:
            return JSONResponse({"detail": "Request is too large."}, status_code=413)
    return await call_next(request)


def _detect_mime(data: bytes) -> Optional[str]:
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[:4] == b"%PDF":
        return "application/pdf"
    return None


def _fetch_image(url: str) -> bytes:
    parsed = urlparse(url)
    if parsed.scheme != "https" or (parsed.hostname or "").lower() not in ALLOWED_IMAGE_HOSTS:
        raise HTTPException(status_code=400, detail="Image URL is not permitted.")
    try:
        with requests.get(url, timeout=20, stream=True, allow_redirects=False) as res:
            if res.status_code != 200:
                raise HTTPException(status_code=400, detail="Receipt image could not be retrieved.")
            chunks, size = [], 0
            for chunk in res.iter_content(64 * 1024):
                size += len(chunk)
                if size > MAX_IMAGE_BYTES:
                    raise HTTPException(status_code=413, detail="Receipt image is too large.")
                chunks.append(chunk)
            return b"".join(chunks)
    except HTTPException:
        raise
    except Exception:
        logger.exception("Receipt image fetch failed")
        raise HTTPException(status_code=400, detail="Receipt image could not be retrieved.")


class OcrRequest(BaseModel):
    image_url: Optional[str] = None
    image_base64: Optional[str] = None


class DetectedTextItem(BaseModel):
    text: str
    confidence: float
    box: Optional[List[dict]] = None


class OcrResponse(BaseModel):
    success: bool
    status: str
    model: str = "nvidia/nemotron-ocr-v2"
    vendor: Optional[str] = None
    vendor_raw: Optional[str] = None
    invoice_number: Optional[str] = None
    receipt_number: Optional[str] = None
    date: Optional[str] = None
    transaction_time: Optional[str] = None
    subtotal_minor: Optional[int] = None
    tax_minor: Optional[int] = None
    tax_rate_percent: Optional[float] = None
    total_minor: Optional[int] = None
    currency: Optional[str] = None
    confidence_score: Optional[float] = None
    missing_fields: List[str] = []
    uncertain_fields: List[str] = []
    field_confidence: Dict[str, float] = {}
    raw_text: Optional[str] = None
    lines: List[str] = []


SUPPORTED_CURRENCIES = ("AED", "USD", "EUR")
REQUIRED_FIELDS = ("vendor", "date", "total_minor", "currency")



def _group_rows(items: List[dict]) -> List[str]:
    """Reading-order text lines from NVIDIA detections.

    NVIDIA returns label and amount of one printed row as separate detections
    ("Total AED" | "199.50"); detections whose vertical centres lie within half
    a box height belong to the same row and are joined left to right.
    Without geometry the provider's order is kept, one detection per line.
    """
    return [" ".join(i["text"] for i in row) for row in _row_items(items)]


def _line_confidences(items: List[dict]) -> List[Optional[float]]:
    """Lowest provider confidence among the detections of each grouped line."""
    out: List[Optional[float]] = []
    for row in _row_items(items):
        confs = [i["confidence"] for i in row if i.get("confidence") is not None]
        out.append(min(confs) if confs else None)
    return out


def _row_items(items: List[dict]) -> List[List[dict]]:
    if not items or any(i["y0"] is None for i in items):
        return [[i] for i in items]
    rows: List[dict] = []
    for it in sorted(items, key=lambda i: (i["y0"] + i["y1"]) / 2):
        centre = (it["y0"] + it["y1"]) / 2
        height = max(it["y1"] - it["y0"], 1e-6)
        if rows:
            row = rows[-1]
            row_height = max(row["y1"] - row["y0"], 1e-6)
            if abs(centre - (row["y0"] + row["y1"]) / 2) < 0.5 * min(height, row_height):
                row["items"].append(it)
                row["y0"], row["y1"] = min(row["y0"], it["y0"]), max(row["y1"], it["y1"])
                continue
        rows.append({"y0": it["y0"], "y1": it["y1"], "items": [it]})
    return [sorted(r["items"], key=lambda i: i["x"]) for r in rows]


@app.get("/")
@app.get("/health")
def health():
    return {
        "status": "healthy",
        "service": "ASM Expense NVIDIA Nemotron OCR v2 Microservice",
        "model": "nvidia/nemotron-ocr-v2",
        "nvidia_configured": bool(NVIDIA_API_KEY),
        "tesseract_available": tesseract_ocr.available(),
    }


def _authorize(request: Request) -> None:
    if not SERVICE_API_KEY:
        raise HTTPException(status_code=503, detail="OCR service is not configured.")
    client_key = request.headers.get("X-API-KEY") or ""
    if not hmac.compare_digest(client_key.encode(), SERVICE_API_KEY.encode()):
        raise HTTPException(status_code=403, detail="Unauthorized.")


def _load_image(payload: OcrRequest) -> Tuple[bytes, str]:
    """Validated receipt bytes and MIME type (from content, not the caller)."""
    if payload.image_base64:
        clean_b64 = payload.image_base64.split("base64,")[-1]
        if len(clean_b64) > (MAX_IMAGE_BYTES * 4) // 3 + 4:
            raise HTTPException(status_code=413, detail="Receipt image is too large.")
        try:
            image_bytes = base64.b64decode(clean_b64, validate=True)
        except Exception:
            raise HTTPException(status_code=400, detail="Receipt image is not valid base64 data.")
    elif payload.image_url:
        image_bytes = _fetch_image(payload.image_url)
    else:
        raise HTTPException(status_code=400, detail="Either image_url or image_base64 must be provided")

    mime_type = _detect_mime(image_bytes)
    if not image_bytes or mime_type is None:
        raise HTTPException(status_code=415, detail="Receipt must be a JPEG, PNG, WEBP image or a PDF.")
    return image_bytes, mime_type


@app.post("/api/v1/extract/tesseract", response_model=OcrResponse)
def extract_receipt_tesseract(payload: OcrRequest, request: Request):
    """Secondary OCR (Tesseract). Runs in the worker thread pool, bounded by
    TESSERACT_MAX_CONCURRENCY and TESSERACT_TIMEOUT_SECONDS."""
    _authorize(request)
    image_bytes, mime_type = _load_image(payload)
    if mime_type == "application/pdf":
        raise HTTPException(status_code=415, detail="PDF receipts cannot be read by the secondary OCR service.")
    if not tesseract_ocr.available():
        raise HTTPException(status_code=503, detail="Secondary OCR engine is not available.")
    if not _tesseract_slots.acquire(timeout=2):
        raise HTTPException(status_code=503, detail="Secondary OCR service is busy.")
    try:
        lines, confidence = tesseract_ocr.extract_lines(image_bytes)
    except tesseract_ocr.TesseractTimeout:
        raise HTTPException(status_code=504, detail="Secondary OCR timed out.")
    except tesseract_ocr.TesseractError:
        raise HTTPException(status_code=422, detail="Receipt image could not be processed.")
    finally:
        _tesseract_slots.release()

    parsed = _parse_nemotron_receipt(lines, "\n".join(lines), confidence)
    parsed["model"] = "tesseract"
    # Raw receipt text stays inside this service.
    parsed["raw_text"] = None
    parsed["lines"] = []
    return OcrResponse(**parsed)


@app.post("/api/v1/extract", response_model=OcrResponse)
async def extract_receipt(payload: OcrRequest, request: Request):
    _authorize(request)
    if not NVIDIA_API_KEY:
        raise HTTPException(status_code=503, detail="OCR service is not configured.")
    image_bytes, mime_type = _load_image(payload)
    image_b64 = base64.b64encode(image_bytes).decode("utf-8")

    # 2. Invoke NVIDIA Nemotron OCR v2
    headers = {
        "Authorization": f"Bearer {NVIDIA_API_KEY}",
        "Content-Type": "application/json",
        "Accept": "application/json"
    }

    request_body = {
        "input": [
            {
                "type": "image_url",
                "url": f"data:{mime_type};base64,{image_b64}"
            }
        ]
    }

    try:
        response = requests.post(NVIDIA_OCR_URL, headers=headers, json=request_body, timeout=NVIDIA_TIMEOUT_SECONDS)
        if response.status_code != 200:
            logger.error("NVIDIA OCR returned HTTP %s", response.status_code)
            raise HTTPException(status_code=502, detail="OCR provider is unavailable.")
        ocr_json = response.json()
    except HTTPException:
        raise
    except Exception:
        logger.exception("NVIDIA OCR request failed")
        raise HTTPException(status_code=502, detail="OCR provider is unavailable.")

    # 3. Extract and sort text detections from Nemotron response
    detected_items = []
    data_list = ocr_json.get("data", [])
    if data_list:
        detections = data_list[0].get("text_detections", [])
        for det in detections:
            pred = det.get("text_prediction", {})
            text = pred.get("text", "").strip()
            raw_conf = pred.get("confidence")
            conf = float(raw_conf) if isinstance(raw_conf, (int, float)) else None
            pts = det.get("bounding_box", {}).get("points", [])
            if text:
                detected_items.append({
                    "text": text,
                    "confidence": conf,
                    "y0": min((p.get("y", 0) for p in pts), default=None),
                    "y1": max((p.get("y", 0) for p in pts), default=None),
                    "x": min((p.get("x", 0) for p in pts), default=0.0),
                })

    lines = _group_rows(detected_items)
    raw_text = "\n".join(lines)
    confidences = [item["confidence"] for item in detected_items if item["confidence"] is not None]
    avg_confidence = sum(confidences) / len(confidences) if confidences else None

    # 4. Parse receipt fields; unreadable fields stay None
    parsed = _parse_nemotron_receipt(lines, raw_text, avg_confidence, _line_confidences(detected_items))
    parsed["raw_text"] = raw_text
    parsed["lines"] = lines

    return OcrResponse(**parsed)


def _classify(result: dict) -> dict:
    extracted = [k for k in ("vendor", "invoice_number", "date", "subtotal_minor", "tax_minor", "total_minor", "currency")
                 if result.get(k) is not None]
    result["missing_fields"] = [k for k in REQUIRED_FIELDS if result.get(k) is None]
    if not extracted:
        result["status"] = "FAILED"
    elif result["missing_fields"]:
        result["status"] = "PARTIAL"
    else:
        result["status"] = "SUCCESS"
    result["success"] = result["status"] != "FAILED"
    return result


def _parse_nemotron_receipt(lines: List[str], raw_text: str, avg_confidence: Optional[float],
                            line_confidences: Optional[List[Optional[float]]] = None) -> dict:
    """Receipt fields from OCR lines via the contextual parser; unreadable fields stay None."""
    result = receipt_parser.parse_receipt(lines, line_confidences)
    result["confidence_score"] = round(avg_confidence, 4) if avg_confidence is not None else None
    return _classify(result)


if __name__ == "__main__":
    import uvicorn
    print(f"Starting ASM NVIDIA Nemotron OCR v2 service on port 8000...")
    uvicorn.run("app:app", host="0.0.0.0", port=8000, reload=False)
