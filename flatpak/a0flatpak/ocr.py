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
import time
from typing import Any

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
OCR_MODEL = os.environ.get("A0_OCR_MODEL", "xiaomi-ocr")
# One vision request. The parser layer gives a whole document 60 s by default
# (``per_document_timeout``), so a single request must stay well below it.
OCR_TIMEOUT = float(os.environ.get("A0_OCR_TIMEOUT", "45"))
# Pages sent from one document. The page loop runs inside a single parser
# call, so this cap and the deadline below keep it inside that call's budget.
OCR_MAX_PAGES = int(os.environ.get("A0_OCR_MAX_PAGES", "4"))
# Seconds kept back for rendering, transport and the response itself.
OCR_MARGIN = 5.0
# One page measured 15-28 s on the target (cold model included). The budget the
# parser layer gives a document has to cover the pages this module is willing to
# send, or the cap above is unreachable: with the shipped 60 s, three pages ended
# at 2 of 3 and five pages at 2 of 5.
OCR_PAGE_COST = float(os.environ.get("A0_OCR_PAGE_COST", "30"))
PDF_READ_ERROR = "PDF could not be read"
# Input quality gate. A vision model does not report that an image was below
# its resolving power: it answers something fluent instead, and a 100x50 image
# came back as an unrelated math problem. 40,000 pixels is the 200x200 icon
# floor and 64 px is the smallest short edge that still holds a legible glyph;
# a 100x50 image fails both tests.
OCR_MIN_PIXELS = int(os.environ.get("A0_OCR_MIN_PIXELS", "40000"))
OCR_MIN_SHORT_EDGE = int(os.environ.get("A0_OCR_MIN_SHORT_EDGE", "64"))
# A reply with fewer visible characters, or one that holds no readable words,
# cannot be told apart from model noise. A plain letter ratio would flag a
# legitimate Markdown table (its pipes and rules are not letters), so a word
# counts only when it has two or more letters in a row.
LOW_CONFIDENCE_CHARS = 8
LOW_CONFIDENCE_WORDS = 4


def _planned_budget() -> float:
    """The document budget that matches OCR_MAX_PAGES."""
    return max(60.0, OCR_MAX_PAGES * OCR_PAGE_COST + 15.0)


def _secs(value: float) -> str:
    """Format a duration so a sub-100 ms value never prints as ``0s``."""
    return "<0.1s" if value < 0.1 else f"{value:.1f}s"

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


def _image_size(content: bytes) -> tuple[int, int] | None:
    """(width, height) from the image header, or None when it cannot be read.

    Pillow reads only the header here, so a large image costs no decode. The
    gate must not reject a document because this measurement is unavailable:
    an unknown size goes to the model as before, and Pillow ships in the
    Flatpak runtime.
    """
    try:
        from PIL import Image

        with Image.open(io.BytesIO(content)) as image:
            return image.size
    except Exception:
        return None


def _reject_small_image(content: bytes) -> None:
    """Refuse an image too small for the vision model to read.

    The check runs before any request, so a caller gets one clear error instead
    of invented text that looks like a successful conversion.
    """
    size = _image_size(content)
    if size is None:
        return
    width, height = size
    if min(width, height) < OCR_MIN_SHORT_EDGE or width * height < OCR_MIN_PIXELS:
        raise ValueError(
            f"image too small for OCR: {width}x{height}, minimum "
            f"{OCR_MIN_SHORT_EDGE}px on the short edge and "
            f"{OCR_MIN_PIXELS} total pixels"
        )


def _word_letters(text: str) -> int:
    """Count letters that belong to a run of two or more letters.

    A single letter is often a formula variable or an isolated glyph, which
    says nothing about legibility. A run of two or more is a word in Latin
    script and a whole phrase in Chinese, Japanese or Korean, whose characters
    carry no spaces.
    """
    total = 0
    run = 0
    for char in text:
        if char.isalpha():
            run += 1
            continue
        if run >= 2:
            total += run
        run = 0
    return total + run if run >= 2 else total


def _low_confidence(text: str) -> str:
    """A Markdown note when the reply is too thin to trust, else ``""``."""
    visible = [char for char in text if not char.isspace()]
    if len(visible) < LOW_CONFIDENCE_CHARS:
        return (
            f"> OCR low confidence: the vision model returned "
            f"{len(visible)} characters."
        )
    words = _word_letters(text)
    if words < LOW_CONFIDENCE_WORDS:
        return (
            f"> OCR low confidence: only {words} letters form words, which "
            f"reads as symbol or digit noise."
        )
    return ""


def _is_timeout(exc: BaseException) -> bool:
    """True when the failure is a deadline, not a misconfiguration.

    A timeout means the model was too slow for the caller's budget: the document
    is fine and a retry may succeed, so it is reported as a partial result. A
    refused connection or a missing model means the deployment is wrong, and
    hiding that behind "OCR incomplete" would send the user looking in the wrong
    place, so those still raise.
    """
    seen = 0
    while exc is not None and seen < 5:
        if isinstance(exc, (TimeoutError,)) or type(exc).__name__ in (
            "TimeoutException",
            "ReadTimeout",
            "ConnectTimeout",
            "WriteTimeout",
            "PoolTimeout",
        ):
            return True
        exc = exc.__cause__ or exc.__context__
        seen += 1
    return False


def _document_limit(config: dict) -> float:
    """The caller's own limit for this document, in seconds."""
    try:
        return float(config.get("per_document_timeout", _planned_budget()))
    except (TypeError, ValueError):
        return _planned_budget()


def _margin_for(limit: float) -> float:
    """Room to keep back for rendering, transport and the response.

    It shrinks with the limit: a caller who sets 10 s still gets a page sent,
    instead of a fixed 5 s margin swallowing half the budget - and a caller who
    sets 10 s previously sent nothing at all, because the loop's first
    ``remaining <= margin`` test was already true.
    """
    return min(OCR_MARGIN, max(1.0, limit * 0.25))


def _document_budget(config: dict) -> float:
    """Seconds the page loop may spend, never below one second."""
    limit = _document_limit(config)
    return max(limit - _margin_for(limit), 1.0)


def _vision_markdown(
    image_bytes: bytes,
    prompt: str = WHOLE_PAGE_PROMPT,
    timeout: float = OCR_TIMEOUT,
) -> str:
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
        timeout=timeout,
    )
    response.raise_for_status()
    payload = response.json()
    message = payload.get("message") or {}
    return str(message.get("content") or "").strip()


def _mupdf_warnings(pymupdf) -> str:
    """Return and clear MuPDF's accumulated warnings, when the API exists."""
    tools = getattr(pymupdf, "TOOLS", None)
    read = getattr(tools, "mupdf_warnings", None)
    return read() if callable(read) else ""


def _damaged_pdf(warnings: str) -> bool:
    markers = ("object out of range", "Page tree load failed", "non-page object in page tree")
    return any(marker in warnings for marker in markers)


def _pdf_pages(content: bytes) -> tuple[list[bytes], int]:
    """Render the pages this module will send, and report the real page count."""
    import pymupdf

    pages: list[bytes] = []
    try:
        document = pymupdf.open(stream=content, filetype="pdf")
    except Exception as exc:
        # A file that is not a PDF reaches this fallback whenever the original
        # extractor already failed, and pymupdf raises its own type there. Wrap
        # it so the parser chain reports one vocabulary instead of leaking a
        # library error through the plugin's error aggregation.
        raise ValueError(
            f"{PDF_READ_ERROR}: {type(exc).__name__}: {exc}"
        ) from exc
    try:
        total = document.page_count
        damage = _mupdf_warnings(pymupdf)
        if _damaged_pdf(damage):
            raise ValueError(
                f"{PDF_READ_ERROR}: damaged page tree "
                f"({damage.splitlines()[-1][:160]})"
            )
        for index in range(min(total, OCR_MAX_PAGES)):
            try:
                page = document[index]
                rect = page.rect
                zoom = PAGE_RENDER_WIDTH / max(rect.width, 1)
                pixmap = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom))
                damage = _mupdf_warnings(pymupdf)
                if _damaged_pdf(damage):
                    if index == 0:
                        raise ValueError(
                            f"{PDF_READ_ERROR}: damaged page tree "
                            f"({damage.splitlines()[-1][:160]})"
                        )
                    continue
                pages.append(pixmap.tobytes("png"))
            except ValueError:
                raise
            except Exception as exc:
                if index == 0:
                    raise ValueError(
                        f"{PDF_READ_ERROR}: {type(exc).__name__}: {exc}"
                    ) from exc
                continue
    finally:
        document.close()
    return pages, total


def _ocr_pages(pages: list[bytes], total: int, config: dict) -> str:
    """Send pages to the vision model, never past the caller's deadline."""
    budget = _document_budget(config)
    margin = _margin_for(_document_limit(config))
    deadline = time.monotonic() + budget
    parts: list[str] = []
    processed = 0
    empty = 0
    stopped = ""
    for index, page in enumerate(pages):
        remaining = deadline - time.monotonic()
        if remaining <= margin:
            stopped = f"the {_secs(budget)} document budget ran out"
            break
        try:
            text = _vision_markdown(page, timeout=min(OCR_TIMEOUT, remaining))
        except Exception as exc:
            if _is_timeout(exc):
                stopped = f"timeout after {_secs(min(OCR_TIMEOUT, remaining))}"
            else:
                raise
            break
        processed += 1
        if text:
            parts.append(text)
        else:
            empty += 1
    if processed == 0:
        # A first page that produced nothing is a failed document, not a
        # partial success. Returning a note here used to make a truncated PDF
        # look like ok=true after the whole budget was spent.
        reason = stopped or "no page was sent"
        raise ValueError(
            f"{PDF_READ_ERROR}: the first page produced no text ({reason})"
        )
    if empty:
        parts.append(
            f"> OCR incomplete: the vision model returned no text for "
            f"{empty} of {processed} pages."
        )
    if processed < total:
        if stopped:
            reason = f"{stopped}; A0_OCR_MAX_PAGES={OCR_MAX_PAGES}"
        else:
            reason = f"A0_OCR_MAX_PAGES={OCR_MAX_PAGES}"
        parts.append(
            f"> OCR incomplete: {processed} of {total} pages processed ({reason})."
        )
    return "\n\n".join(parts)


def _parse_image(document: Any, config: dict) -> str:
    content = getattr(document, "content", b"") or b""
    if not content:
        return ""
    _reject_small_image(content)
    budget = _document_budget(config)
    try:
        text = _vision_markdown(content, timeout=min(OCR_TIMEOUT, budget))
    except Exception as exc:
        if _is_timeout(exc):
            return (
                f"> OCR incomplete: the vision request did not finish within "
                f"{_secs(min(OCR_TIMEOUT, budget))}. The image was not converted."
            )
        raise ValueError(
            f"OCR failed within {_secs(min(OCR_TIMEOUT, budget))}: "
            f"{type(exc).__name__}: {exc}"
        ) from exc
    if not text.strip():
        # An empty string looks like success upstream and lets the parser chain
        # move on with nothing to show. Say what happened instead.
        return "> OCR incomplete: the vision model returned no text for this image."
    note = _low_confidence(text)
    return f"{text}\n\n{note}" if note else text


def _parse_pdf_with_fallback(original: Any):
    def parse(self, document: Any, config: dict) -> str:
        # The original extractor is the optional strategy here: PyMuPDF and the
        # Tesseract fallback both fail when their native pieces are absent, and
        # that is exactly when the Ollama pass below must take over.
        try:
            text = original(self, document, config)
        except Exception:
            text = ""
        if isinstance(text, str) and text.strip():
            return text
        if not config.get("pdf_ocr_fallback", True):
            return text if isinstance(text, str) else ""
        content = getattr(document, "content", b"") or b""
        if not content:
            return ""
        pages, total = _pdf_pages(content)
        return _ocr_pages(pages, total, config)

    return parse


def _patch_document_timeout() -> None:
    """Raise the shipped per-document budget so the page cap is reachable.

    ``plugins/_document_query`` gives one document ``per_document_timeout``
    seconds, and wraps the whole ``_parse_sync`` call in
    ``asyncio.wait_for``. The page loop lives inside that call, so the outer
    limit - not ``A0_OCR_TIMEOUT`` and not ``A0_OCR_MAX_PAGES`` - is what stops
    it: measured on the target, the shipped 60 s finished 2 of 3 pages and 2 of
    5, while 300 s finished 3 of 3 in 63.6 s.

    Only the shipped default is replaced. A caller who configured any other
    value keeps it, because ``config.json`` wins in
    ``helpers.plugins.get_plugin_config`` and arrives here already parsed.
    """
    from plugins._document_query.helpers import document_query as dq

    if getattr(dq, "_a0flatpak_timeout_patched", False):
        return

    original = dq._load_config
    planned = _planned_budget()

    def load_config(agent: Any) -> dict:
        config = original(agent)
        if not isinstance(config, dict):
            return config
        try:
            current = float(config.get("per_document_timeout", planned))
        except (TypeError, ValueError):
            current = planned
        if current == 60.0:
            config = dict(config)
            config["per_document_timeout"] = planned
        return config

    dq._load_config = load_config
    dq._a0flatpak_timeout_patched = True


def apply() -> None:
    """Replace the image parser and add the scanned-PDF fallback."""
    from plugins._document_query.helpers.parsers import image as image_parser
    from plugins._document_query.helpers.parsers import pdf as pdf_parser

    _patch_document_timeout()

    if not getattr(image_parser.ImageParser, "_a0flatpak_patched", False):
        image_parser.ImageParser._parse_sync = lambda self, document, config: _parse_image(
            document, config
        )
        image_parser.ImageParser._a0flatpak_patched = True

    if not getattr(pdf_parser.PdfParser, "_a0flatpak_patched", False):
        original = pdf_parser.PdfParser._parse_sync
        pdf_parser.PdfParser._parse_sync = _parse_pdf_with_fallback(original)
        pdf_parser.PdfParser._a0flatpak_patched = True
