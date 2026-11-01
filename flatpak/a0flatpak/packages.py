"""Stop plugin hooks from installing system packages.

Several plugins prepare their runtime by calling ``apt-get`` as root and
querying ``dpkg-query``: ``_desktop`` and ``_office`` install Xpra, XFCE and
LibreOffice; ``_kokoro_tts``, ``_whisper_stt``, ``_context_doctor``,
``_document_query`` and ``_browser`` call ``uv pip install`` for their Python
dependencies.

The Flatpak sandbox is read-only and unprivileged, so every one of those calls
fails at best and blocks startup at worst. This module replaces the entry
points with no-ops that report success in the shape each caller expects.

The replacements keep the original behaviour for document-level cleanup, which
only touches writable state directories.
"""

from __future__ import annotations

from typing import Any

# (module path, function name) pairs whose bodies only prepare dependencies.
_NOOP_PLUGIN_HOOKS = (
    ("plugins._kokoro_tts.hooks", "ensure_dependencies"),
    ("plugins._kokoro_tts.hooks", "install"),
    ("plugins._context_doctor.hooks", "ensure_dependencies"),
    ("plugins._context_doctor.hooks", "install"),
    ("plugins._document_query.hooks", "ensure_dependencies"),
    ("plugins._document_query.hooks", "install"),
)


def _cleanup_result(**overrides: Any) -> dict[str, Any]:
    result: dict[str, Any] = {
        "ok": True,
        "skipped": True,
        "removed": [],
        "installed": [],
        "migrated": [],
        "warnings": [],
        "errors": [],
    }
    result.update(overrides)
    return result


def _patch_noop_hooks() -> None:
    import importlib

    for module_path, attribute in _NOOP_PLUGIN_HOOKS:
        try:
            module = importlib.import_module(module_path)
        except Exception:
            continue
        if getattr(module, "_a0flatpak_patched", False):
            continue
        if not hasattr(module, attribute):
            continue

        def noop(*_args: Any, **_kwargs: Any) -> bool:
            return True

        setattr(module, attribute, noop)


def _patch_system_package_hooks() -> None:
    from plugins._desktop import hooks as desktop_hooks
    from plugins._office import hooks as office_hooks

    if not getattr(desktop_hooks, "_a0flatpak_patched", False):
        def desktop_cleanup(force: bool = False) -> dict[str, Any]:
            return _cleanup_result(runtime="host-desktop")

        desktop_hooks.cleanup_stale_runtime_state = desktop_cleanup
        desktop_hooks._a0flatpak_patched = True

    if not getattr(office_hooks, "_a0flatpak_patched", False):
        original = office_hooks.cleanup_stale_runtime_state

        def office_cleanup(force: bool = False) -> dict[str, Any]:
            try:
                result = original(force=force)
            except Exception as exc:
                return _cleanup_result(ok=False, errors=[str(exc)])
            if isinstance(result, dict):
                result.setdefault("skipped", True)
            return result

        office_hooks.cleanup_stale_runtime_state = office_cleanup
        office_hooks._a0flatpak_patched = True


def apply() -> None:
    """Neutralise every package-manager and pip call made by plugin hooks."""
    _patch_noop_hooks()
    _patch_system_package_hooks()
