"""Serve embeddings from Ollama instead of sentence-transformers.

``models.get_embedding_model`` returns a sentence-transformers wrapper for the
``huggingface`` provider. The Flatpak build ships no torch, so that import
fails during preload and inside the memory plugin.

The wrapper below returns an ``Embeddings`` object backed by
``POST /api/embed``. It accepts the same arguments as the original factory, so
every existing call site keeps working unchanged.

The factory is patched through the ``extensible`` decorator on
``Agent.get_embedding_model``, which resolves the model config and calls
``models.get_embedding_model``. Patching the module-level factory covers both
the agent path and the direct calls in ``plugins/_memory``.

Blank text never reaches Ollama. ``embed_query`` and ``embed_documents``
return a zero vector for it and write a warning to ``usr/logs/a0flatpak.log``.
They never raise. A tool call that passes an empty query or an empty memory
would otherwise abort the whole message loop: ``Agent.handle_exception``
re-raises, and tool execution has no ``except`` clause.
"""

from __future__ import annotations

import os
import time
from typing import Any

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
DEFAULT_EMBEDDING_MODEL = os.environ.get("A0_EMBEDDING_MODEL", "qwen3-embedding:4b-q4_K_M")
DEFAULT_EMBEDDING_DIM = int(os.environ.get("A0_EMBEDDING_DIM", "2560"))
EMPTY_TEXT_ERROR = "empty text cannot be embedded"


def _base_dir() -> str:
    """Return the writable framework root, the same way ``base_dir`` does."""
    return os.environ.get("A0_BASE_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
        "agent-zero",
    )


def _log_warning(message: str) -> None:
    """Append one warning line to the Flatpak log. Logging never breaks a call."""
    try:
        log_dir = os.path.join(_base_dir(), "usr", "logs")
        os.makedirs(log_dir, exist_ok=True)
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        with open(
            os.path.join(log_dir, "a0flatpak.log"), "a", encoding="utf-8"
        ) as log_file:
            log_file.write(f"{stamp} warning: {message}\n")
    except Exception:
        pass


def _is_blank(text: Any) -> bool:
    """Return True when a text is missing or holds only whitespace."""
    return not isinstance(text, str) or not text.strip()


def _post_embed(model: str, inputs: list[str]) -> list[list[float]]:
    import httpx

    if not inputs:
        return []
    response = httpx.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": model, "input": inputs},
        timeout=120.0,
    )
    response.raise_for_status()
    payload = response.json()
    embeddings = payload.get("embeddings")
    if not embeddings:
        raise RuntimeError(f"Ollama returned no embeddings for model {model!r}")
    if len(embeddings) != len(inputs):
        raise RuntimeError(
            f"Ollama returned {len(embeddings)} embeddings for {len(inputs)} inputs"
        )
    return embeddings


def _build_wrapper_class():
    from langchain_core.embeddings import Embeddings

    class OllamaEmbeddings(Embeddings):
        """LangChain embeddings backed by the Ollama ``/api/embed`` endpoint."""

        model_name: str
        _dimension: int

        def __init__(self, model: str, **_: Any) -> None:
            self.model_name = model
            self._dimension = DEFAULT_EMBEDDING_DIM

        def zero_vector(self) -> list[float]:
            """Return the empty-input marker. A real embedding is never all zero."""
            return [0.0] * self._dimension

        def embed_documents(self, texts: list[str]) -> list[list[float]]:
            if not texts:
                return []
            blank_positions = [index for index, text in enumerate(texts) if _is_blank(text)]
            if blank_positions:
                _log_warning(
                    f"{EMPTY_TEXT_ERROR}: {len(blank_positions)} text(s) at "
                    f"positions {blank_positions} in a batch of {len(texts)}. "
                    "Zero vectors returned there."
                )
            live_texts = [text for text in texts if not _is_blank(text)]
            if not live_texts:
                return [self.zero_vector() for _ in texts]
            vectors = _post_embed(self.model_name, live_texts)
            self._dimension = len(vectors[0])
            if not blank_positions:
                return vectors
            result: list[list[float]] = []
            vector_index = 0
            for text in texts:
                if _is_blank(text):
                    result.append(self.zero_vector())
                else:
                    result.append(vectors[vector_index])
                    vector_index += 1
            return result

        def embed_query(self, text: str) -> list[float]:
            if _is_blank(text):
                _log_warning(
                    f"{EMPTY_TEXT_ERROR}: embed_query got blank text. "
                    "Zero vector returned, so no memory matches."
                )
                return self.zero_vector()
            vector = _post_embed(self.model_name, [text])[0]
            self._dimension = len(vector)
            return vector

        async def aembed_documents(self, texts: list[str]) -> list[list[float]]:
            import asyncio

            return await asyncio.to_thread(self.embed_documents, texts)

        async def aembed_query(self, text: str) -> list[float]:
            import asyncio

            return await asyncio.to_thread(self.embed_query, text)

    return OllamaEmbeddings


def apply() -> None:
    """Replace the embedding factory with the Ollama-backed one."""
    import models

    if getattr(models, "_a0flatpak_embedding_patched", False):
        return

    original_factory = models.get_embedding_model
    wrapper_cls = _build_wrapper_class()

    def get_embedding_model(provider: str, name: str, model_config: Any = None, **kwargs: Any):
        provider_name = (provider or "").lower()
        if provider_name in {"huggingface", "ollama", ""}:
            resolved = name or DEFAULT_EMBEDDING_MODEL
            if resolved.startswith("sentence-transformers/"):
                resolved = DEFAULT_EMBEDDING_MODEL
            return wrapper_cls(resolved)
        return original_factory(provider, name, model_config, **kwargs)

    models.get_embedding_model = get_embedding_model
    models._a0flatpak_embedding_patched = True
