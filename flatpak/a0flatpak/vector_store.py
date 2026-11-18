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
            # d == 0 means "dimension not known yet": an index recovered from an
            # unreadable file has no width to check against, so the first batch
            # defines it. Without this, every recovered index would reject the
            # first write.
            if self.d == 0:
                self.d = int(batch.shape[1])
                self._vectors = np.zeros((0, self.d), dtype="float32")
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

        def reconstruct(self, index: int) -> Any:
            return self._vectors[int(index)]

        def remove_ids(self, ids: Any) -> int:
            """Drop rows by index. ``FAISS.delete`` calls this after a delete."""
            keep = np.ones(self.ntotal, dtype=bool)
            keep[np.asarray(ids, dtype="int64")] = False
            removed = self.ntotal - int(keep.sum())
            self._vectors = self._vectors[keep]
            self.ntotal = len(self._vectors)
            return removed

        def __len__(self) -> int:
            return self.ntotal

    def write_index(index: Any, path: str) -> None:
        with open(path, "wb") as handle:
            pickle.dump(
                {"format": "a0flatpak-numpy", "dimension": index.d, "vectors": index._vectors},
                handle,
            )

    def read_index(path: str) -> Any:
        try:
            with open(path, "rb") as handle:
                payload = pickle.load(handle)
            if not isinstance(payload, dict) or payload.get("format") != "a0flatpak-numpy":
                raise ValueError(f"{path} is not an a0flatpak numpy index")
            index = IndexFlatIP(payload["dimension"])
            index._vectors = np.asarray(payload["vectors"], dtype="float32")
            index.ntotal = len(index._vectors)
            return index
        except Exception as exc:
            # An index written by real faiss (or a truncated file) cannot be
            # read here. Refusing to load it used to abort memory init, so the
            # caller gets an empty index instead: adding starts from scratch,
            # and the first save replaces the file with one this build can read.
            # The file is left on disk - deleting it would destroy the docstore
            # beside it, which is still readable and still holds the documents.
            print(
                f"a0flatpak: could not read the vector index at {path} "
                f"({type(exc).__name__}: {exc}); starting from an empty index",
                file=sys.stderr,
            )
            return IndexFlatIP(0)

    module = types.ModuleType("faiss")
    module.IndexFlatIP = IndexFlatIP
    module.write_index = write_index
    module.read_index = read_index
    module.__a0flatpak_shim__ = True
    return module


def apply() -> None:
    """Register the shim as ``faiss`` unless a real faiss is already loaded."""
    existing = sys.modules.get("faiss")
    if existing is not None:
        return
    sys.modules["faiss"] = _build_module()
    _patch_load_local()


def _patch_load_local() -> None:
    """Make an unreadable index rebuild instead of half-loading.

    ``read_index`` returns an empty index so that a slow repair cannot crash
    memory init. That empty index is not enough on its own: ``FAISS.load_local``
    also restores ``index_to_docstore_id``, whose keys are the positions the
    *old* index used. Adding to an empty index reuses positions 0..n, so the new
    vectors silently resolve to the old documents' ids - no exception, wrong
    recall. Measured: two old docs plus two new ones produced ``ntotal == 2``
    and ``similarity_search`` returned the old pair.

    So the recovered database is treated as absent: its files are renamed out of
    the way (never deleted, the docstore in them may still be worth reading by
    hand) and the caller gets ``None``, which ``plugins/_memory`` already treats
    as "no database yet, build one".
    """
    try:
        from langchain_community.vectorstores.faiss import FAISS
    except Exception:
        return
    if getattr(FAISS, "_a0flatpak_load_patched", False):
        return

    original = FAISS.load_local.__func__  # classmethod

    def load_local(cls: Any, folder_path: Any, *args: Any, **kwargs: Any) -> Any:
        db = original(cls, folder_path, *args, **kwargs)
        index = getattr(db, "index", None)
        if getattr(index, "d", None) != 0:
            return db
        import os
        import time

        stamp = time.strftime("%Y%m%d-%H%M%S")
        for name in ("index.faiss", "index.pkl", "index.faiss.sha256"):
            path = os.path.join(str(folder_path), name)
            if os.path.exists(path):
                os.replace(path, f"{path}.incompatible-{stamp}")
        print(
            "a0flatpak: the index in "
            f"{folder_path} was not readable, so the database was set aside "
            f"(suffix .incompatible-{stamp}) and will be rebuilt",
            file=sys.stderr,
        )
        return None

    FAISS.load_local = classmethod(load_local)
    FAISS._a0flatpak_load_patched = True
