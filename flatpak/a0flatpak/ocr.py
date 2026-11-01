"""Parse images and scanned pages with an Ollama vision model.

``plugins/_document_query`` routes images and scans through
``UnstructuredParser``, which needs the ``unstructured`` inference stack. The
Flatpak build ships the light ``unstructured`` package only, so images and
scanned PDFs have no parser.

This module replaces two parser methods:

* ``ImageParser._parse_sync`` sends the image to Ollama and returns Markdown.
* ``PdfParser._parse_sync`` keeps the existing text extraction for digital
  PDFs and falls back to rendering each page and sending it to Ollama when the
  extracted text is empty.

Both replacements keep the ``(document, config)`` signature the registry uses.
"""

from __future__ import annotations

import base64
import io
import os
from typing import Any

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
OCR_MODEL = os.environ.get("A0_OCR_MODEL", "xiaomi-ocr")
OCR_TIMEOUT = float(os.environ.get("A0_OCR_TIMEOUT", "300"))

WHOLE_PAGE_PROMPT = (
    "Extract all information from the main body of the document image and "
    "represent it in markdown format, ignoring headers and footers. "
    "Tables should be expressed in OTSL format, formulas in LaTeX."
)

# Rendered page width in pixels. Higher values keep small text legible at the
# cost of more vision tokens.
PAGE_RENDER_WIDTH = int(os.environ.get("A0_OCR_PAGE_WIDTH", "1600"))


def _encode_image(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def _vision_markdown(image_bytes: bytes, prompt: str = WHOLE_PAGE_PROMPT) -> str:
    import httpx

    response = httpx.post(
        f"{OLLAMA_URL}/api/chat",
        json={
            "model": OCR_MODEL,
            "stream": False,
            "options": {"temperature": 0},
            "messages": [
                {
                    "role": "user",
                    "content": prompt,
                    "images": [_encode_image(image_bytes)],
                }
            ],
        },
        timeout=OCR_TIMEOUT,
    )
    response.raise_for_status()
    payload = response.json()
    message = payload.get("message") or {}
    return str(message.get("content") or "").strip()


def _pdf_pages(content: bytes) -> list[bytes]:
    import pymupdf

    pages: list[bytes] = []
    document = pymupdf.open(stream=content, filetype="pdf")
    try:
        for page in document:
            rect = page.rect
            zoom = PAGE_RENDER_WIDTH / max(rect.width, 1)
            pixmap = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom))
            pages.append(pixmap.tobytes("png"))
    finally:
        document.close()
    return pages


def _parse_image(document: Any, config: dict) -> str:
    content = getattr(document, "content", b"") or b""
    if not content:
        return ""
    return _vision_markdown(content)


def _parse_pdf_with_fallback(original: Any):
    def parse(document: Any, config: dict) -> str:
        text = original(document, config)
        if isinstance(text, str) and text.strip():
            return text
        content = getattr(document, "content", b"") or b""
        if not content:
            return ""
        parts = [_vision_markdown(page) for page in _pdf_pages(content)]
        return "\n\n".join(part for part in parts if part)

    return parse


def apply() -> None:
    """Replace the image parser and add the scanned-PDF fallback."""
    from plugins._document_query.helpers.parsers import image as image_parser
    from plugins._document_query.helpers.parsers import pdf as pdf_parser

    if not getattr(image_parser.ImageParser, "_a0flatpak_patched", False):
        image_parser.ImageParser._parse_sync = lambda self, document, config: _parse_image(
            document, config
        )
        image_parser.ImageParser._a0flatpak_patched = True

    if not getattr(pdf_parser.PdfParser, "_a0flatpak_patched", False):
        original = pdf_parser.PdfParser._parse_sync
        pdf_parser.PdfParser._parse_sync = _parse_pdf_with_fallback(original)
        pdf_parser.PdfParser._a0flatpak_patched = True
