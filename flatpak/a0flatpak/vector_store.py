"""Replace faiss with a numpy-backed index.

``helpers/vector_db.py`` and ``plugins/_memory`` build langchain ``FAISS``
objects from ``faiss.IndexFlatIP``. The Flatpak build ships no faiss, so those
imports fail.

The shim registers a module named ``faiss`` before langchain imports it. The
index keeps every vector in a float32 matrix and answers ``search`` with a
matrix product, which is exactly what ``IndexFlatIP`` computes. Serialization
uses pickle, so ``save_local`` and ``load_local`` keep their signatures.

Index files written by the real faiss library cannot be read by this shim and
the reverse also holds. Data written by the Flatpak build stays inside the
Flatpak build.
"""

from __future__ import annotations

import pickle
import sys
import types
from typing import Any


def _build_module() -> types.ModuleType:
    import numpy as np

    class IndexFlatIP:
        """Exact inner-product index with the faiss attribute surface."""

        def __init__(self, dimension: int, metric: Any = None) -> None:
            self.d = int(dimension)
            self.metric_type = 1  # faiss METRIC_INNER_PRODUCT
            self.ntotal = 0
            self._vectors = np.zeros((0, self.d), dtype="float32")

        def add(self, vectors: Any) -> None:
            batch = np.asarray(vectors, dtype="float32")
            if batch.ndim == 1:
                batch = batch.reshape(1, -1)
            if batch.shape[1] != self.d:
                raise ValueError(f"expected vectors of width {self.d}, got {batch.shape[1]}")
            self._vectors = np.vstack([self._vectors, batch])
            self.ntotal = len(self._vectors)

        def search(self, queries: Any, k: int) -> tuple[Any, Any]:
            batch = np.asarray(queries, dtype="float32")
            if batch.ndim == 1:
                batch = batch.reshape(1, -1)
            if self.ntotal == 0:
                empty = np.zeros((len(batch), 0), dtype="float32")
                return empty, np.zeros((len(batch), 0), dtype="int64")
            k = min(int(k), self.ntotal)
            scores = batch @ self._vectors.T
            order = np.argsort(-scores, axis=1)[:, :k]
            return np.take_along_axis(scores, order, axis=1), order

        def reconstruct_n(self, start: int, count: int) -> Any:
            return self._vectors[int(start) : int(start) + int(count)]

        def __len__(self) -> int:
            return self.ntotal

    def write_index(index: Any, path: str) -> None:
        with open(path, "wb") as handle:
            pickle.dump(
                {"format": "a0flatpak-numpy", "dimension": index.d, "vectors": index._vectors},
                handle,
            )

    def read_index(path: str) -> Any:
        with open(path, "rb") as handle:
            payload = pickle.load(handle)
        if not isinstance(payload, dict) or payload.get("format") != "a0flatpak-numpy":
            raise ValueError(f"{path} is not an a0flatpak numpy index")
        index = IndexFlatIP(payload["dimension"])
        index._vectors = payload["vectors"]
        index.ntotal = len(index._vectors)
        return index

    module = types.ModuleType("faiss")
    module.IndexFlatIP = IndexFlatIP
    module.write_index = write_index
    module.read_index = read_index
    module.__a0flatpak_shim__ = True
    return module


def apply() -> None:
    """Register the shim as ``faiss`` unless a real faiss is already loaded."""
    existing = sys.modules.get("faiss")
    if existing is not None and not getattr(existing, "__a0flatpak_shim__", False):
        return
    if existing is not None:
        return
    sys.modules["faiss"] = _build_module()
