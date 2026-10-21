"""Tesseract OCR (secondary provider): preprocessing and engine invocation.

The original receipt bytes are never modified; a derived grayscale PNG is
streamed to the official `tesseract` binary over stdin/stdout, so no image or
text is written to disk. Raw receipt text is never logged.
"""
import io
import logging
import os
import shutil
import subprocess
from typing import List, Optional, Tuple

from PIL import Image, ImageFilter, ImageOps

logger = logging.getLogger("asm_ocr.tesseract")

TESSERACT_CMD = os.getenv("TESSERACT_CMD", "tesseract")
TESSERACT_LANG = os.getenv("TESSERACT_LANG", "eng")
# 4 = single column of text of variable sizes (typical receipts)
TESSERACT_PSM = os.getenv("TESSERACT_PSM", "4")
TESSERACT_TIMEOUT_SECONDS = float(os.getenv("TESSERACT_TIMEOUT_SECONDS", "15"))
TESSERACT_MAX_PIXELS = int(os.getenv("TESSERACT_MAX_PIXELS", str(40_000_000)))
TESSERACT_MEMORY_LIMIT_MB = int(os.getenv("TESSERACT_MEMORY_LIMIT_MB", "1024"))

# Long-edge bounds for the derived image: downscale very large photos, gently
# upscale small ones so receipt text is roughly 300 DPI equivalent.
MAX_LONG_EDGE = 2400
MIN_LONG_EDGE = 1200


class TesseractError(Exception):
    """Engine missing, failed, or the image could not be processed."""


class TesseractTimeout(TesseractError):
    """Engine exceeded TESSERACT_TIMEOUT_SECONDS."""


def available() -> bool:
    return shutil.which(TESSERACT_CMD) is not None


def preprocess(image_bytes: bytes) -> bytes:
    """Derived image for OCR: orientation, grayscale, size, contrast, light denoise."""
    try:
        with Image.open(io.BytesIO(image_bytes)) as source:
            width, height = source.size
            if width * height > TESSERACT_MAX_PIXELS:
                raise TesseractError("image exceeds pixel limit")
            img = ImageOps.exif_transpose(source).convert("L")
    except TesseractError:
        raise
    except Exception as exc:
        raise TesseractError("image could not be decoded") from exc

    long_edge = max(img.size)
    if long_edge > MAX_LONG_EDGE:
        scale = MAX_LONG_EDGE / long_edge
        img = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)
    elif long_edge < MIN_LONG_EDGE:
        scale = min(2.0, MIN_LONG_EDGE / long_edge)
        img = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)

    # Tesseract binarizes internally (Otsu); only normalize contrast and remove speckle.
    img = ImageOps.autocontrast(img, cutoff=1)
    img = img.filter(ImageFilter.MedianFilter(3))

    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()


def _limit_resources() -> None:  # pragma: no cover - POSIX only
    import resource

    limit = TESSERACT_MEMORY_LIMIT_MB * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_AS, (limit, limit))


def parse_tsv(tsv: str) -> Tuple[List[str], Optional[float]]:
    """Reading-order text lines and mean word confidence (0..1) from Tesseract TSV."""
    lines: List[str] = []
    current_key = None
    current_words: List[str] = []
    confidences: List[float] = []
    for row in tsv.splitlines()[1:]:
        cols = row.split("\t")
        if len(cols) < 12 or cols[0] != "5":
            continue
        text = cols[11].strip()
        try:
            conf = float(cols[10])
        except ValueError:
            continue
        if not text or conf < 0:
            continue
        key = (cols[1], cols[2], cols[3], cols[4])
        if key != current_key and current_words:
            lines.append(" ".join(current_words))
            current_words = []
        current_key = key
        current_words.append(text)
        confidences.append(conf / 100.0)
    if current_words:
        lines.append(" ".join(current_words))
    avg = round(sum(confidences) / len(confidences), 4) if confidences else None
    return lines, avg


def run(png_bytes: bytes) -> Tuple[List[str], Optional[float]]:
    if not available():
        raise TesseractError("tesseract binary not found")
    cmd = [TESSERACT_CMD, "stdin", "stdout", "-l", TESSERACT_LANG, "--psm", TESSERACT_PSM, "tsv"]
    env = dict(os.environ, OMP_THREAD_LIMIT="1")
    try:
        proc = subprocess.run(
            cmd,
            input=png_bytes,
            capture_output=True,
            timeout=TESSERACT_TIMEOUT_SECONDS,
            env=env,
            check=False,
            preexec_fn=_limit_resources if os.name == "posix" else None,
        )
    except subprocess.TimeoutExpired as exc:
        logger.warning("Tesseract timed out after %ss", TESSERACT_TIMEOUT_SECONDS)
        raise TesseractTimeout("tesseract timed out") from exc
    except OSError as exc:
        logger.error("Tesseract could not be started: %s", type(exc).__name__)
        raise TesseractError("tesseract could not be started") from exc
    if proc.returncode != 0:
        logger.error("Tesseract exited with code %s", proc.returncode)
        raise TesseractError("tesseract failed")
    return parse_tsv(proc.stdout.decode("utf-8", errors="replace"))


def extract_lines(image_bytes: bytes) -> Tuple[List[str], Optional[float]]:
    return run(preprocess(image_bytes))
