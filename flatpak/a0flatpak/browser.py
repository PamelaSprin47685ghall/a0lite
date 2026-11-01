"""Drive the host Chrome through stealth-browser.

``plugins/_browser`` prepares a Patchright Chromium download and launches it
with ``executable_path``. A Flatpak build cannot download and unpack that
browser at runtime, and the host already ships Chrome.

This module wires the plugin's runtime to ``stealth_browser``, which drives the
system Chrome over CDP through ``nodriver``. Two seams are patched:

* ``plugins._browser.hooks.prepare_playwright_cache`` returns the system Chrome
  binary, so the plugin's readiness checks pass without downloading anything.
* ``plugins._browser.hooks.install`` skips the dependency bootstrap that would
  call ``uv``.

``stealth_browser.browser.BrowserPool.start`` is extended to forward the Chrome
binary and the display environment to ``nodriver``, because ``nodriver``
otherwise probes for a browser by name and starts headless.

Chrome is located through ``A0_BROWSER_CHROME`` first, then through the usual
command names. When no Chrome is found the original behaviour returns, so the
plugin reports its normal missing-binary error instead of crashing.
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


def find_system_chrome() -> Path | None:
    """Return the host Chrome binary, or None when none is installed."""
    override = os.environ.get(CHROME_ENV, "").strip()
    if override:
        candidate = Path(override).expanduser()
        return candidate if candidate.is_file() else None

    for name in _CHROME_NAMES:
        found = shutil.which(name)
        if found:
            return Path(found)
    return None


def _patch_plugin_hooks() -> None:
    from plugins._browser import hooks

    if getattr(hooks, "_a0flatpak_patched", False):
        return

    original_prepare = hooks.prepare_playwright_cache

    def prepare_playwright_cache() -> dict[str, Any]:
        chrome = find_system_chrome()
        if chrome is None:
            return original_prepare()
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


def _patch_stealth_browser() -> None:
    """Forward the Chrome binary and display to nodriver."""
    try:
        from stealth_browser import browser as stealth_browser
    except ImportError:
        return

    pool = stealth_browser.BrowserPool
    if getattr(pool, "_a0flatpak_patched", False):
        return

    original_start = pool.start

    async def start(self, proxy: Any = None) -> None:
        if self._browser is not None:
            return

        chrome = find_system_chrome()
        if chrome is None:
            await original_start(self, proxy)
            return

        import nodriver

        args = list(stealth_browser.ULTRA_STEALTH_CHROMIUM_ARGS)
        if proxy:
            host, port, _user, _password = proxy
            args.append(f"--proxy-server=http://{host}:{port}")
            args.append("--proxy-bypass-list=<-loopback>;127.0.0.1;localhost")
            self._current_proxy = proxy
        else:
            self._current_proxy = None

        headless = not os.environ.get("DISPLAY")
        self._browser = await nodriver.start(
            browser_executable_path=str(chrome),
            browser_args=args,
            headless=headless,
        )

        if proxy:
            await self._setup_proxy_auth(proxy[2], proxy[3])

    pool.start = start
    pool._a0flatpak_patched = True


def apply() -> None:
    """Point the browser plugin at the host Chrome through stealth-browser."""
    _patch_plugin_hooks()
    _patch_stealth_browser()
