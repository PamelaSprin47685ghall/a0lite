"""Bundled-Ollama adaptations for the Flatpak build.

Import this package once, before the framework starts serving requests.
:func:`apply` installs every adaptation in a fixed order and is safe to call
more than once.

Each module in this package replaces one local-inference dependency with an
HTTP call to the Ollama server that the launcher starts. Nothing here changes
framework files, so upstream updates stay mergeable.
"""

from __future__ import annotations

_APPLIED = False


def apply() -> None:
    """Install every adaptation. Repeat calls do nothing."""
    global _APPLIED
    if _APPLIED:
        return

    from a0flatpak import base_dir

    base_dir.apply()

    from a0flatpak import provider_urls

    provider_urls.apply()

    from a0flatpak import embeddings

    embeddings.apply()

    from a0flatpak import vector_store

    vector_store.apply()

    from a0flatpak import speech

    speech.apply()

    from a0flatpak import rfc_loop

    rfc_loop.apply()

    from a0flatpak import ocr

    ocr.apply()

    from a0flatpak import parsers

    parsers.apply()

    from a0flatpak import browser

    browser.apply()

    from a0flatpak import desktop

    desktop.apply()

    from a0flatpak import packages

    packages.apply()

    from a0flatpak import health

    health.apply()

    from a0flatpak import auth

    auth.apply()

    _APPLIED = True
