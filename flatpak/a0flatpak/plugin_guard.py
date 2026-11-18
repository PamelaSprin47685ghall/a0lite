"""Re-apply runtime patches after the plugin namespace is purged.

Agent Zero loads plugin API handlers with ``helpers.modules.import_module``:
the file is read from the writable tree (``$BASE_DIR/plugins``), executed under
a bare module name, and is *not* inserted into ``sys.modules``.  A patch that
does ``setattr`` on a module imported by path therefore can miss the live
object entirely.  This guard patches every matching module object it can find:
``sys.modules`` entries whose name or file ends with the target suffix, plus
every module returned by the framework's loader.

The plugin watchdog calls ``modules.purge_namespace("plugins")`` when it sees
plugin files change.  Each patch registers an idempotent callable here; the
callables run again after a purge and before plugin configuration or tools are
used.
"""

from __future__ import annotations

import os
import sys
import time
import traceback
import weakref
from types import ModuleType
from typing import Callable

PLUGIN = "plugins"
_patchers: dict[str, Callable[[], None]] = {}
_module_patchers: dict[str, list[Callable[[ModuleType], None]]] = {}
_loaded: "weakref.WeakValueDictionary[int, ModuleType]" = weakref.WeakValueDictionary()
_ENSURING = False


def log_path() -> str:
    root = os.environ.get("A0_BASE_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
        "agent-zero",
    )
    return os.path.join(root, "usr", "logs", "a0flatpak.log")


def log(component: str, message: str, exc: BaseException | None = None) -> None:
    """Record a patch failure where the next restart can find it."""
    detail = f"{component}: {message}"
    if exc is not None:
        detail += f": {type(exc).__name__}: {exc}"
    print(f"a0flatpak {detail}", file=sys.stderr)
    try:
        path = log_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {detail}\n")
            if exc is not None:
                traceback.print_exception(exc, file=handle)
    except Exception as log_error:
        print(f"a0flatpak cannot write {path}: {log_error}", file=sys.stderr)


def _matches(module: ModuleType, suffix: str) -> bool:
    name = getattr(module, "__name__", "") or ""
    path = (getattr(module, "__file__", "") or "").replace("\\", "/")
    return name.endswith(suffix) or path.endswith(suffix.replace(".", "/") + ".py")


def live_modules(suffix: str) -> list[ModuleType]:
    """Every loaded module whose name or file ends with ``suffix``."""
    seen: set[int] = set()
    found: list[ModuleType] = []
    for module in [*sys.modules.values(), *_loaded.values()]:
        if not isinstance(module, ModuleType):
            continue
        if id(module) in seen or not _matches(module, suffix):
            continue
        seen.add(id(module))
        found.append(module)
    return found


def register(name: str, apply_fn: Callable[[], None]) -> None:
    """Register an idempotent patcher that scans live modules itself."""
    _patchers[name] = apply_fn


def register_module(suffix: str, apply_fn: Callable[[ModuleType], None]) -> None:
    """Patch a module as soon as the framework loader returns it."""
    _module_patchers.setdefault(suffix, []).append(apply_fn)


def ensure(name: str | None = None, healthy=None, patcher=None):
    """Run the idempotent patchers.  With no argument, run all.

    ``healthy``/``patcher`` keep the browser guard's existing call shape
    working while that module migrates to ``register``.
    """
    if healthy is not None and patcher is not None:
        return _ensure_one(name or "plugin", healthy, patcher)

    global _ENSURING
    if _ENSURING:
        return
    _ENSURING = True
    try:
        names = [name] if name is not None else list(_patchers)
        for key in names:
            apply_fn = _patchers.get(key)
            if apply_fn is None:
                continue
            try:
                apply_fn()
            except Exception as exc:
                log(key, "patcher failed", exc)
    finally:
        _ENSURING = False


def _ensure_one(component: str, healthy, patcher) -> bool:
    try:
        if healthy():
            return True
        patcher()
        if healthy():
            return True
        log(component, "patcher returned but the plugin is still unpatched")
        return False
    except Exception as exc:
        log(component, "patcher failed", exc)
        return False


def watch_purge(component: str, ensure_fn: Callable[[], object]) -> None:
    """Register an idempotent ensure function for the purge hook."""
    register(f"watch:{component}", ensure_fn)


def install_hooks() -> None:
    """Install the triggers that make the patchers self-healing."""
    for install in (_install_purge_hook, _install_config_hook, _install_tool_hook, _install_loader_hook):
        try:
            install()
        except Exception as exc:
            log("hooks", f"{install.__name__} failed", exc)


def _install_purge_hook() -> None:
    from helpers import modules

    if getattr(modules, "_a0flatpak_purge_patched", False):
        return

    original = modules.purge_namespace

    def purge_namespace(namespace: str):
        result = original(namespace)
        if namespace == PLUGIN or namespace.startswith(PLUGIN + "."):
            ensure()
        return result

    modules.purge_namespace = purge_namespace
    modules._a0flatpak_purge_patched = True


def _install_config_hook() -> None:
    from functools import wraps

    from helpers import plugins

    if getattr(plugins, "_a0flatpak_config_patched", False):
        return

    original = plugins.get_plugin_config

    @wraps(original)
    def get_plugin_config(*args, **kwargs):
        ensure()
        return original(*args, **kwargs)

    plugins.get_plugin_config = get_plugin_config
    plugins._a0flatpak_config_patched = True


def _install_tool_hook() -> None:
    from helpers import tool

    cls = tool.Tool
    if getattr(cls, "_a0flatpak_tool_patched", False):
        return

    original = cls.__init__

    def __init__(self, *args, **kwargs):
        ensure()
        original(self, *args, **kwargs)
        ensure()

    cls.__init__ = __init__
    cls._a0flatpak_tool_patched = True


def _install_loader_hook() -> None:
    from helpers import modules

    if getattr(modules, "_a0flatpak_loader_patched", False):
        return

    original = modules.import_module

    def import_module(file_path: str):
        module = original(file_path)
        _loaded[id(module)] = module
        for suffix, apply_fns in list(_module_patchers.items()):
            if not _matches(module, suffix):
                continue
            for apply_fn in apply_fns:
                try:
                    apply_fn(module)
                except Exception as exc:
                    log(suffix, "module patch failed", exc)
        return module

    modules.import_module = import_module
    modules._a0flatpak_loader_patched = True
