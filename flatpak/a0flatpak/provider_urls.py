"""Point local provider defaults at the bundled Ollama server.

``conf/model_providers.yaml`` ships Docker-era defaults such as
``http://host.docker.internal:11434``. Inside the Flatpak sandbox the bundled
server listens on ``127.0.0.1``, so those defaults must change before the
provider registry is first read.

``ProviderManager._load_providers`` builds ``_raw`` as
``{type: [entry, ...]}`` and ``_options`` as ``{type: [{value, label}]}``.
The wrapper rewrites ``kwargs.api_base`` and ``models_list.endpoint_url`` of
the local providers in ``_raw`` after the original loader runs.
"""

from __future__ import annotations

import os
from typing import Any

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")

# provider id -> (api_base, models_list endpoint or None)
_LOCAL_REWRITES: dict[str, tuple[str, str | None]] = {
    "ollama": (OLLAMA_URL, f"{OLLAMA_URL}/api/tags"),
    "lm_studio": (f"{OLLAMA_URL}/v1", None),
}


def _rewrite_entry(entry: dict[str, Any]) -> None:
    provider_id = str(entry.get("id") or "").lower()
    target = _LOCAL_REWRITES.get(provider_id)
    if target is None:
        return

    api_base, endpoint_url = target

    kwargs = dict(entry.get("kwargs") or {})
    kwargs["api_base"] = api_base
    entry["kwargs"] = kwargs

    models_list = entry.get("models_list")
    if isinstance(models_list, dict) and endpoint_url:
        models_list = dict(models_list)
        models_list["endpoint_url"] = endpoint_url
        entry["models_list"] = models_list


def _rewrite_raw(raw: dict[str, Any]) -> None:
    for entries in raw.values():
        if isinstance(entries, list):
            for entry in entries:
                if isinstance(entry, dict):
                    _rewrite_entry(entry)


def apply() -> None:
    """Wrap ``ProviderManager._load_providers`` to rewrite local defaults."""
    from helpers import providers

    manager = providers.ProviderManager
    if getattr(manager, "_a0flatpak_patched", False):
        return

    original_load = manager._load_providers

    def load_providers(self):
        original_load(self)
        _rewrite_raw(getattr(self, "_raw", None) or {})

    manager._load_providers = load_providers
    manager._a0flatpak_patched = True
