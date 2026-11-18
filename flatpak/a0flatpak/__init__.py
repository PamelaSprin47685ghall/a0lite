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

    from a0flatpak import compat

    compat.apply()

    from a0flatpak import base_dir

    base_dir.apply()

    # Plugin patches are lost when Agent Zero purges the plugin namespace.
    # Install the reusable guard before the modules that register patchers.
    from a0flatpak import plugin_guard

    plugin_guard.install_hooks()

    # The bundle has no git metadata, so the version shown by the UI comes
    # from the build identity that the launcher exports.
    from a0flatpak import version

    version.apply()

    # The File Browser root is the whole machine.  Keep credential directories
    # out of its list, read, download and delete paths.
    from a0flatpak import sensitive_paths

    sensitive_paths.apply()

    from a0flatpak import chat_guard

    chat_guard.apply()

    # The adaptation modules below read their configuration when they are
    # imported. Load ``usr/.env`` first, from the writable root that
    # ``base_dir.apply()`` just installed, so those values are visible.
    from helpers import dotenv

    dotenv.load_dotenv()

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

    from a0flatpak import code_exec

    code_exec.apply()

    from a0flatpak import mcp_cache

    mcp_cache.apply()

    from a0flatpak import browser_guard

    browser_guard.apply()

    from a0flatpak import serve

    serve.apply()

    _APPLIED = True
