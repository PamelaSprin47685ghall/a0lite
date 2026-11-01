"""Replace the langchain-unstructured catch-all parser.

``UnstructuredParser`` is the only parser with ``mimetypes = ["*"]`` and it
imports ``langchain_unstructured``, which pins ``onnxruntime<=1.19.2`` and has
no wheel for Python 3.14.

This module installs an equivalent catch-all that keeps the same registry
contract and tries three strategies in order:

1. ``unstructured.partition.auto.partition`` on the document bytes. This is
   the same engine the langchain loader wrapped, reached without the wrapper.
2. Office formats through the bundled LibreOffice conversion, when the host
   provides ``soffice``.
3. An Ollama vision pass over rendered pages, for documents whose text layer
   is missing.

A strategy that raises or returns nothing falls through to the next one, so a
document with no text layer still ends up parsed instead of rejected.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
OCR_MODEL = os.environ.get("A0_OCR_MODEL", "xiaomi-ocr")
OCR_TIMEOUT = float(os.environ.get("A0_OCR_TIMEOUT", "300"))

WHOLE_PAGE_PROMPT = (
    "Extract all information from the main body of the document image and "
    "represent it in markdown format, ignoring headers and footers. "
    "Tables should be expressed in OTSL format, formulas in LaTeX."
)

_OFFICE_SUFFIXES = {
    ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
    ".odt", ".ods", ".odp", ".rtf", ".csv",
}


def _partition_bytes(content: bytes, suffix: str) -> str:
    """Extract text with the unstructured library, if it can handle the type."""
    from unstructured.partition.auto import partition

    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as handle:
        handle.write(content)
        path = handle.name
    try:
        elements = partition(filename=path)
        return "\n".join(str(element) for element in elements).strip()
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def _convert_with_soffice(path: str, suffix: str) -> str:
    """Convert an Office document to text through LibreOffice."""
    soffice = os.environ.get("A0_SOFFICE", "soffice")
    from shutil import which

    binary = which(soffice)
    if not binary:
        return ""

    with tempfile.TemporaryDirectory() as out_dir:
        target = "txt:Text (encoded):UTF8"
        result = subprocess.run(
            [
                binary,
                "--headless",
                "--norestore",
                "--convert-to",
                target,
                "--outdir",
                out_dir,
                path,
            ],
            capture_output=True,
            text=True,
            timeout=180,
            check=False,
        )
        if result.returncode != 0:
            return ""
        for produced in Path(out_dir).glob("*.txt"):
            return produced.read_text(encoding="utf-8", errors="replace").strip()
    return ""


def _ocr_with_ollama(content: bytes, suffix: str) -> str:
    """Render pages and read them with the vision model."""
    import httpx

    pages: list[bytes] = []
    if suffix == ".pdf" or content[:4] == b"%PDF":
        import pymupdf

        document = pymupdf.open(stream=content, filetype="pdf")
        try:
            for page in document:
                rect = page.rect
                zoom = 1600 / max(rect.width, 1)
                pixmap = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom))
                pages.append(pixmap.tobytes("png"))
        finally:
            document.close()
    else:
        pages.append(content)

    import base64

    texts: list[str] = []
    for page in pages:
        response = httpx.post(
            f"{OLLAMA_URL}/api/chat",
            json={
                "model": OCR_MODEL,
                "stream": False,
                "options": {"temperature": 0},
                "messages": [
                    {
                        "role": "user",
                        "content": WHOLE_PAGE_PROMPT,
                        "images": [base64.b64encode(page).decode("ascii")],
                    }
                ],
            },
            timeout=OCR_TIMEOUT,
        )
        response.raise_for_status()
        message = response.json().get("message") or {}
        text = str(message.get("content") or "").strip()
        if text:
            texts.append(text)
    return "\n\n".join(texts)


def _office_with_soffice(content: bytes, suffix: str) -> str:
    """Convert an Office document by staging it on disk for LibreOffice."""
    path = _materialise(content, suffix)
    try:
        return _convert_with_soffice(path, suffix)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def _materialise(content: bytes, suffix: str) -> str:
    """Write bytes to a temporary path the caller must remove."""
    handle = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
    try:
        handle.write(content)
    finally:
        handle.close()
    return handle.name


def _catch_all_parse(document: Any, config: dict) -> str:
    content = getattr(document, "content", b"") or b""
    if not content:
        return ""
    suffix = (getattr(document, "suffix", lambda: "")() or "").lower()

    strategies = [("unstructured", _partition_bytes)]

    if suffix in _OFFICE_SUFFIXES:
        strategies.append(("soffice", _office_with_soffice))

    strategies.append(("ollama-ocr", _ocr_with_ollama))

    errors: list[str] = []
    for name, strategy in strategies:
        try:
            text = strategy(content, suffix)
        except Exception as exc:  # noqa: BLE001 - each strategy is best effort
            errors.append(f"{name}: {exc}")
            continue
        if text and text.strip():
            return text

    if errors:
        raise ValueError("; ".join(errors))
    return ""


def apply() -> None:
    """Swap the catch-all parser for the langchain-free implementation."""
    from plugins._document_query.helpers.parsers import unstructured as parser_module

    if getattr(parser_module.UnstructuredParser, "_a0flatpak_patched", False):
        return

    parser_module.UnstructuredParser._parse_sync = (
        lambda self, document, config: _catch_all_parse(document, config)
    )
    parser_module.UnstructuredParser._a0flatpak_patched = True
