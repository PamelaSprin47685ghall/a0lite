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
"""

from __future__ import annotations

import os
from typing import Any

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
DEFAULT_EMBEDDING_MODEL = os.environ.get("A0_EMBEDDING_MODEL", "qwen3-embedding:4b-q4_K_M")


def _post_embed(model: str, inputs: list[str]) -> list[list[float]]:
    import httpx

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
    return embeddings


def _build_wrapper_class():
    from langchain_core.embeddings import Embeddings

    class OllamaEmbeddings(Embeddings):
        """LangChain embeddings backed by the Ollama ``/api/embed`` endpoint."""

        model_name: str

        def __init__(self, model: str, **_: Any) -> None:
            self.model_name = model

        def embed_documents(self, texts: list[str]) -> list[list[float]]:
            if not texts:
                return []
            return _post_embed(self.model_name, list(texts))

        def embed_query(self, text: str) -> list[float]:
            return _post_embed(self.model_name, [text])[0]

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
