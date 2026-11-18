"""Make browser navigation bounded, honest about failures, and releasable.

Upstream ``plugins/_browser`` treats navigation as best effort.  ``_goto``
logs a warning and returns, then ``_state`` evaluates on the page that is
still loading, so a slow server blocks the tool call long past the 30 s goto
timeout.  The same warning path hides DNS failures and HTTP error statuses
from the tool response, and ``close_runtime`` never reaches the only function
that stops Chrome, so a closed browser keeps 200+ MB resident.

Four replacements, all additive:

* ``_BrowserRuntimeCore._goto`` keeps one budget, aborts a stuck navigation
  over CDP, and records ``_a0_navigation`` on the page.
* ``_state`` bounds its evaluate and appends ``navigation`` to the state.
* ``open`` and ``navigate`` lift ``error``, ``status`` and ``url`` to the top
  level so the tool response distinguishes failure from success.
* ``close_runtime`` closes the shared Chrome when its last session is gone
  and verifies that ``delete_profile`` actually removed the profile.

`plugin_guard` re-applies every replacement after a plugin namespace purge.
"""

from __future__ import annotations

import asyncio
import contextlib
import importlib
import os
import shutil
from pathlib import Path
from typing import Any

from a0flatpak import plugin_guard

NAV_TIMEOUT = float(os.environ.get("A0_BROWSER_NAV_TIMEOUT", "15"))
CALL_TIMEOUT = float(os.environ.get("A0_BROWSER_CALL_TIMEOUT", "45"))
STATE_TIMEOUT = float(os.environ.get("A0_BROWSER_STATE_TIMEOUT", "2"))
NAV_ATTR = "_a0_navigation"


def _runtime():
    """Return the current plugin runtime module, never a cached one."""
    return importlib.import_module("plugins._browser.helpers.runtime")


def _log(message: str, exc: BaseException | None = None) -> None:
    plugin_guard.log("browser", message, exc)


async def _abort_navigation(page: Any) -> None:
    """Stop a pending navigation without touching the document.

    ``Page.stopLoading`` is the only abort that does not wait for the page:
    ``page.stop()`` does not exist, and ``window.stop()`` needs an execution
    context, which is exactly what a hanging navigation withholds.
    """
    try:
        session = await page.context.new_cdp_session(page)
        try:
            await session.send("Page.stopLoading")
        finally:
            await session.detach()
    except Exception:
        pass


def _quiet_target_closed() -> None:
    """Drop the TargetClosedError left behind by an aborted navigation.

    Playwright resolves the abandoned navigation future after the context is
    gone and prints "Future exception was never retrieved".  It is noise from
    our own abort, not a failure, but every other exception still goes to the
    previous handler.
    """
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    if getattr(loop, "_a0flatpak_browser_filter", False):
        return
    previous = loop.get_exception_handler()

    def handler(active_loop, context):
        error = context.get("exception")
        if (
            type(error).__name__ == "TargetClosedError"
            and context.get("message") == "Future exception was never retrieved"
        ):
            return
        (previous or active_loop.default_exception_handler)(context)

    loop.set_exception_handler(handler)
    loop._a0flatpak_browser_filter = True


def _host_chrome_healthy() -> bool:
    """True while the plugin hooks still point at the host Chrome."""
    try:
        from plugins._browser import hooks
    except Exception:
        return False
    return bool(getattr(hooks, "_a0flatpak_patched", False))


def _patch_host_chrome() -> None:
    # ``a0flatpak.browser`` patches the hooks module object that exists now.
    # A purge replaces that module, so the patch must be re-applied here too.
    from a0flatpak import browser as host_browser

    host_browser.apply()


def _navigation_healthy() -> bool:
    try:
        core = _runtime()._BrowserRuntimeCore
    except Exception:
        return False
    return all(
        getattr(getattr(core, name, None), "_a0flatpak_patched", False)
        for name in ("_goto", "_state", "open", "navigate")
    )


def _patch_navigation() -> None:
    core = _runtime()._BrowserRuntimeCore
    if _navigation_healthy():
        return

    original_state = core._state
    original_open = core.open
    original_navigate = core.navigate

    async def _goto(self, page, url, *, wait_until="domcontentloaded"):
        from patchright.async_api import Error as PlaywrightError
        from patchright.async_api import TimeoutError as PlaywrightTimeoutError

        _quiet_target_closed()
        try:
            response = await asyncio.wait_for(
                page.goto(
                    url,
                    wait_until=wait_until,
                    timeout=int(NAV_TIMEOUT * 1000),
                ),
                timeout=NAV_TIMEOUT + 1,
            )
        except (asyncio.TimeoutError, PlaywrightTimeoutError) as exc:
            await _abort_navigation(page)
            setattr(
                page,
                NAV_ATTR,
                {"url": url, "error": "TIMEOUT", "detail": str(exc)[:300]},
            )
            return
        except PlaywrightError as exc:
            # DNS failures and refused connections land here.  The page shows
            # a native error page; report the reason instead of a warning.
            setattr(
                page,
                NAV_ATTR,
                {"url": url, "error": "NAVIGATION_FAILED", "detail": str(exc)[:300]},
            )
            return

        navigation: dict[str, Any] = {"url": url}
        status = getattr(response, "status", None)
        if status is not None:
            navigation["status"] = int(status)
        setattr(page, NAV_ATTR, navigation)

    async def _state(self, browser_id):
        _quiet_target_closed()
        try:
            state = await asyncio.wait_for(original_state(self, browser_id), STATE_TIMEOUT)
        except asyncio.TimeoutError:
            browser_page = self.pages.get(int(browser_id))
            if browser_page is None:
                raise KeyError(f"Browser {browser_id} is not open.")
            state = {
                "id": browser_page.id,
                "context_id": self._page_context_id(browser_page),
                "currentUrl": browser_page.page.url,
                "title": "",
                "canGoBack": False,
                "canGoForward": False,
                "loading": True,
                "zoom": 100,
                "zoom_available": False,
            }
        browser_page = self.pages.get(int(browser_id))
        navigation = getattr(browser_page.page, NAV_ATTR, None) if browser_page else None
        if navigation:
            state["navigation"] = dict(navigation)
        return state

    def _lift(result: Any) -> Any:
        if not isinstance(result, dict):
            return result
        navigation = result.get("navigation") or (result.get("state") or {}).get(
            "navigation"
        ) or {}
        if navigation.get("error"):
            result["error"] = navigation["error"]
            result["url"] = navigation.get("url", "")
            result.setdefault("detail", navigation.get("detail", ""))
        if "status" in navigation:
            result["status"] = navigation["status"]
        return result

    async def open_(self, url="", *, wait_until="domcontentloaded"):
        return _lift(await original_open(self, url, wait_until=wait_until))

    async def navigate(self, browser_id, url, *, wait_until="domcontentloaded"):
        return _lift(
            await original_navigate(self, browser_id, url, wait_until=wait_until)
        )

    for function in (_goto, _state, open_, navigate):
        function._a0flatpak_patched = True
    core._goto = _goto
    core._state = _state
    core.open = open_
    core.navigate = navigate
    core._a0flatpak_patched = True


def _ceiling_healthy() -> bool:
    try:
        return getattr(_runtime().BrowserRuntime, "_a0flatpak_patched", False)
    except Exception:
        return False


def _patch_call_ceiling() -> None:
    runtime_module = _runtime()
    if _ceiling_healthy():
        return

    original = runtime_module.BrowserRuntime.call_for

    async def call_for(self, context_id, method, *args, **kwargs):
        if method not in {"open", "navigate"}:
            return await original(self, context_id, method, *args, **kwargs)
        _quiet_target_closed()
        try:
            return await asyncio.wait_for(
                original(self, context_id, method, *args, **kwargs), CALL_TIMEOUT
            )
        except asyncio.TimeoutError:
            url = kwargs.get("url")
            if url is None and args:
                url = args[-1] if len(args) > 1 else args[0]
            for browser_page in list(self._core.pages.values()):
                if browser_page.context_id == context_id:
                    await _abort_navigation(browser_page.page)
            return {
                "error": "TIMEOUT",
                "url": str(url or ""),
                "detail": f"browser {method} exceeded {CALL_TIMEOUT:g}s",
            }

    call_for._a0flatpak_patched = True
    runtime_module.BrowserRuntime.call_for = call_for
    runtime_module.BrowserRuntime._a0flatpak_patched = True


def _lifecycle_healthy() -> bool:
    try:
        return bool(getattr(_runtime(), "_a0flatpak_browser_patched", False))
    except Exception:
        return False


def _remove_profile(path: Path) -> bool:
    """Delete the profile, then confirm the directory is really gone."""
    if not path.exists():
        return True
    shutil.rmtree(path, ignore_errors=True)
    if path.exists():
        _log(f"browser profile still present after delete: {path}")
        return False
    return True


def _patch_lifecycle() -> None:
    runtime_module = _runtime()
    if _lifecycle_healthy():
        return

    async def close_runtime(context_id: str, *, delete_profile: bool = True) -> None:
        context_id = str(context_id or "").strip()
        if not context_id:
            return
        runtime_module._forget_browser_context(context_id)
        with runtime_module._runtime_lock:
            runtime = runtime_module._runtimes.pop(context_id, None)
            shared = runtime_module._shared_runtime
        if runtime is not None:
            await runtime.call("close_context")
        elif shared is not None:
            await shared.call_for(context_id, "close_context")

        with runtime_module._runtime_lock:
            remaining = bool(runtime_module._runtimes)
            shared = runtime_module._shared_runtime
        if shared is None:
            return
        if remaining:
            if delete_profile:
                _log(
                    "browser profile kept: "
                    f"{len(runtime_module._runtimes)} session(s) still attached"
                )
            return

        profile = Path(shared._core.profile_dir)
        # close_all_runtimes runs context.close(), playwright.stop() and the
        # plugin's own rmtree; the check below covers a profile that survived.
        await runtime_module.close_all_runtimes(delete_profiles=delete_profile)
        if delete_profile:
            _remove_profile(profile)

    close_runtime._a0flatpak_patched = True
    runtime_module.close_runtime = close_runtime
    runtime_module._a0flatpak_browser_patched = True


def ensure() -> bool:
    """Re-apply every replacement.  Cheap when all are already in place."""
    chrome = plugin_guard.ensure(
        "browser/host-chrome", _host_chrome_healthy, _patch_host_chrome
    )
    navigation = plugin_guard.ensure(
        "browser/navigation", _navigation_healthy, _patch_navigation
    )
    ceiling = plugin_guard.ensure(
        "browser/ceiling", _ceiling_healthy, _patch_call_ceiling
    )
    lifecycle = plugin_guard.ensure(
        "browser/lifecycle", _lifecycle_healthy, _patch_lifecycle
    )
    return chrome and navigation and ceiling and lifecycle


def apply() -> None:
    """Install the browser replacements."""
    try:
        _runtime()
    except Exception as exc:
        _log("plugin runtime not importable yet; patch deferred", exc)
        return
    ensure()
    plugin_guard.watch_purge("browser", ensure)


try:
    plugin_guard.watch_purge("browser", ensure)
except Exception as exc:  # helpers is unavailable outside the app process
    plugin_guard.log("browser", "purge hook could not be installed", exc)
