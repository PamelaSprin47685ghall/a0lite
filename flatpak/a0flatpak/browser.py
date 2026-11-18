"""Drive the host Chrome with the plugin's own Patchright runtime.

``plugins/_browser`` prepares a Patchright Chromium download and launches it
with ``executable_path``. A Flatpak build cannot download and unpack that
browser at runtime, and the host already ships Chrome.

Two seams are patched:

* ``plugins._browser.hooks.prepare_playwright_cache`` returns the system Chrome
  binary, so the plugin's readiness checks pass without downloading anything.
* ``plugins._browser.hooks.install`` skips the dependency bootstrap that would
  call ``uv``.

``plugins/_browser/helpers/runtime.py`` passes that binary to
``chromium.launch_persistent_context(executable_path=...)``, so Patchright runs
the host Chrome in place.

Chrome is located through ``A0_BROWSER_CHROME`` first, then through the usual
command names, then through absolute paths the sandbox exposes. ``shutil.which``
alone can never find a host browser: the sandbox keeps the runtime's ``/usr``,
and the host's own root appears at ``/run/host/root`` (from
``--filesystem=host-os``), with ``/opt`` also mounted at its real path by
``--filesystem=host``. When no Chrome is found the original behaviour returns,
so the plugin reports its normal missing-binary error instead of crashing.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Any

CHROME_ENV = "A0_BROWSER_CHROME"

# Order matters: prefer the branded stable build, then the generic names.
_CHROME_NAMES = (
    "google-chrome-stable",
    "google-chrome",
    "chromium",
    "chromium-browser",
    "microsoft-edge-stable",
    "brave-browser",
)

# Names on PATH are not enough inside the sandbox: /usr belongs to the runtime,
# so a host browser is reachable only through the mounts below. Order matters:
# the host root mirror comes first because it is verified executable on the
# target (`/run/host/root/opt/google/chrome/google-chrome`, rc=0, no missing
# libraries), then the plain names, then the distro layouts.
_CHROME_PATHS = (
    "/run/host/root/opt/google/chrome/google-chrome",
    "/run/host/root/usr/bin/google-chrome",
    "/run/host/root/usr/bin/google-chrome-stable",
    "/opt/google/chrome/google-chrome",
    "/usr/lib/chromium/chromium",
    "/usr/bin/chromium",
    "/run/host/root/usr/lib/chromium/chromium",
    "/usr/lib/chromium-browser/chromium-browser",
    "/snap/bin/chromium",
)


def find_system_chrome() -> Path | None:
    """Return the host Chrome binary, or None when none is installed."""
    override = os.environ.get(CHROME_ENV, "").strip()
    if override:
        candidate = Path(override).expanduser()
        # An override that exists but cannot be executed would only fail later,
        # inside Patchright's spawn, as an EACCES with no hint about why. Report
        # it as "not found" so the caller takes its normal no-host-browser path
        # (its own discovery, then the downloaded build) instead of receiving a
        # path that is guaranteed to fail.
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
        return None

    for name in _CHROME_NAMES:
        found = shutil.which(name)
        if found:
            return Path(found)

    for candidate in _CHROME_PATHS:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return Path(candidate)
    return None


def _patch_plugin_hooks() -> None:
    from plugins._browser import hooks

    if getattr(hooks, "_a0flatpak_patched", False):
        return

    original_prepare = hooks.prepare_playwright_cache

    def prepare_playwright_cache() -> dict[str, Any]:
        chrome = find_system_chrome()
        if chrome is None:
            # Falling back to the bundled Chromium is a working degradation, so
            # the call still succeeds. It must not be silent, though: without a
            # line saying why the host browser was skipped, an operator whose
            # A0_BROWSER_CHROME points at the wrong path sees a healthy tool and
            # concludes their setup was honoured.
            result = original_prepare()
            warnings = list(result.get("warnings") or [])
            warnings.append(
                "No host Chrome was found (A0_BROWSER_CHROME, PATH and the known "
                "locations are all empty or not executable); the bundled Chromium "
                "download is used instead."
            )
            result["warnings"] = warnings
            result["source"] = result.get("source") or "bundled"
            return result
        return {
            "binary": str(chrome),
            "errors": [],
            "warnings": [],
            "removed": [],
            "backup": "",
            "source": "system",
        }

    def install() -> dict[str, Any]:
        return prepare_playwright_cache()

    hooks.prepare_playwright_cache = prepare_playwright_cache
    hooks.install = install
    hooks._a0flatpak_patched = True


def apply() -> None:
    """Point the browser plugin at the host Chrome."""
    _patch_plugin_hooks()
