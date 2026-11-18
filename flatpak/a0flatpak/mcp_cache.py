"""Keep the WPS cache and the poll port in sync with one agent call.

Two defects make the WPS MCP server unreliable inside Agent Zero.

1. The framework opens a new MCP session for every tool call
   (``helpers/mcp_handler.py:_execute_with_session``).  The server keeps its
   data cache in process memory, so every ``wps_cache_data`` write dies with
   the process that served it.  This module answers the four cache tools in
   the agent process instead, which is where the data is consumed anyway.

2. Every session tries to bind 127.0.0.1:58891 for the WPS add-in poll loop.
   A second session cannot bind the port, and the server treats ``EADDRINUSE``
   as success.  The session then waits 30 s for a reply that can never come.
   This module lets one session at a time run, so that race cannot start.

The cache answers copy the server's own text verbatim.  A caller cannot tell
a local answer from a server answer, except by the timing.
"""

from __future__ import annotations

import asyncio
import io
import json
import os
import sys
import threading
import time
from datetime import datetime, timezone
from typing import Any

CACHE_TOOL_NAMES = frozenset(
    {"wps_cache_data", "wps_get_cached_data", "wps_list_cache", "wps_clear_cache"}
)

MAX_ENTRIES = 100
MAX_ITEM_BYTES = 1024 * 1024

# One WPS call takes 30 s when the add-in answers and up to 70 s when it has to
# switch application first.  A queue of five therefore needs more than 120 s
# before the last caller gets its turn.  The default leaves room for ten
# callers on the slow path; the environment variable raises it further.
DEFAULT_LOCK_TIMEOUT_SECONDS = 600.0
LOCK_TIMEOUT_ENV = "A0_MCP_LOCK_TIMEOUT"


def lock_timeout_seconds() -> float:
    """Return the queue wait limit in seconds.

    The value is read on every call so an operator can raise it without a
    rebuild.  A bad value falls back to the default and writes one line to
    stderr instead of failing the tool call.
    """
    raw = os.environ.get(LOCK_TIMEOUT_ENV, "").strip()
    if raw:
        try:
            value = float(raw)
        except ValueError:
            print(f"a0flatpak mcp_cache: ignoring {LOCK_TIMEOUT_ENV}={raw!r}", file=sys.stderr)
        else:
            if value > 0:
                return value
    return DEFAULT_LOCK_TIMEOUT_SECONDS


def busy_text(timeout: float) -> str:
    return json.dumps(
        {
            "error": "MCP_BUSY",
            "message": (
                f"另一个 WPS MCP 调用仍在运行，已排队等待 {timeout:g} 秒仍未轮到本次调用；"
                f"请稍后重试，或增大环境变量 {LOCK_TIMEOUT_ENV}（当前 "
                f"{os.environ.get(LOCK_TIMEOUT_ENV) or '默认'}）。"
            ),
            "retryable": True,
            "timeoutSeconds": timeout,
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )

PORT_TEXT = (
    "port 58891 already in use: another MCP session still owns the WPS poll port, "
    "so this call cannot receive a reply"
)

_cache: dict[str, dict[str, Any]] = {}
_cache_lock = threading.Lock()
_LOCK_ATTR = "_a0flatpak_mcp_locks"


# --------------------------------------------------------------------------
# cache


def _iso(timestamp: float) -> str:
    """Return the same shape as JavaScript ``Date#toISOString``."""
    moment = datetime.fromtimestamp(timestamp, timezone.utc)
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _payload_size(value: Any) -> int:
    try:
        return len(json.dumps(value, ensure_ascii=False).encode("utf-8"))
    except (TypeError, ValueError):
        return MAX_ITEM_BYTES + 1


def _cached_at(value: dict[str, Any]) -> str:
    return _iso(float(value.get("timestamp", 0.0)))


def _cache_data(args: dict[str, Any]) -> tuple[str, bool]:
    if "key" not in args:
        return _missing("key")
    if "data" not in args:
        return _missing("data")
    key = args["key"]
    data = args["data"]
    if _payload_size(data) > MAX_ITEM_BYTES:
        return (
            json.dumps(
                {
                    "success": False,
                    "error": f"缓存条目过大：data 超过 {MAX_ITEM_BYTES} 字节上限",
                },
                ensure_ascii=False,
            ),
            True,
        )
    with _cache_lock:
        new_key = key not in _cache
        if new_key and len(_cache) >= MAX_ENTRIES:
            return (
                json.dumps(
                    {
                        "success": False,
                        "error": f"缓存条目过多：已达 {MAX_ENTRIES} 条上限，请先清除不再使用的键",
                        "availableKeys": list(_cache),
                    },
                    ensure_ascii=False,
                ),
                True,
            )
        _cache[key] = {
            "data": data,
            "timestamp": time.time(),
            "appType": args.get("appType") or "unknown",
        }
        size = len(_cache)
    return (
        json.dumps(
            {
                "success": True,
                "key": key,
                "message": "数据已缓存，可在其他应用中通过 wps_get_cached_data 获取",
                "cacheSize": size,
            },
            ensure_ascii=False,
        ),
        False,
    )


def _get_cached_data(args: dict[str, Any]) -> tuple[str, bool]:
    if "key" not in args:
        return _missing("key")
    key = args["key"]
    with _cache_lock:
        entry = _cache.get(key)
        if entry is None:
            return (
                json.dumps(
                    {
                        "success": False,
                        "error": f'缓存键 "{key}" 不存在',
                        "availableKeys": list(_cache),
                    },
                    ensure_ascii=False,
                ),
                True,
            )
        body = {
            "success": True,
            "key": key,
            "data": entry["data"],
            "appType": entry["appType"],
            "cachedAt": _cached_at(entry),
        }
    return json.dumps(body, ensure_ascii=False), False


def _list_cache(args: dict[str, Any]) -> tuple[str, bool]:
    now = time.time()
    with _cache_lock:
        rows = [
            {
                "key": key,
                "appType": entry["appType"],
                "cachedAt": _cached_at(entry),
                "ageMs": int((now - float(entry.get("timestamp", now))) * 1000),
            }
            for key, entry in _cache.items()
        ]
    body = {"success": True, "count": len(rows), "caches": rows}
    return json.dumps(body, ensure_ascii=False), False


def _clear_cache(args: dict[str, Any]) -> tuple[str, bool]:
    key = args.get("key")
    if key:
        with _cache_lock:
            deleted = _cache.pop(key, None) is not None
        message = f'缓存 "{key}" 已清除' if deleted else f'缓存 "{key}" 不存在'
    else:
        with _cache_lock:
            count = len(_cache)
            _cache.clear()
        message = f"已清除所有缓存，共 {count} 条"
    return json.dumps({"success": True, "message": message}, ensure_ascii=False), False


def _missing(name: str) -> tuple[str, bool]:
    return json.dumps({"success": False, "error": f"Missing required parameter: {name}"}, ensure_ascii=False), True


_HANDLERS = {
    "wps_cache_data": _cache_data,
    "wps_get_cached_data": _get_cached_data,
    "wps_list_cache": _list_cache,
    "wps_clear_cache": _clear_cache,
}


# --------------------------------------------------------------------------
# one session per server


def _lock_for(server: str) -> asyncio.Lock:
    """Return a lock bound to this server and this running event loop.

    ``asyncio.Lock`` binds to the loop that first waits on it.  Agent Zero may
    run tool calls on more than one loop, so the registry lives on the loop
    object itself.  A module-level dict keyed by ``id(loop)`` would hand a new
    loop a lock that still points at a dead one, because CPython reuses ids.
    """
    loop = asyncio.get_running_loop()
    registry = getattr(loop, _LOCK_ATTR, None)
    if registry is None:
        registry = {}
        setattr(loop, _LOCK_ATTR, registry)
    lock = registry.get(server)
    if lock is None:
        lock = asyncio.Lock()
        registry[server] = lock
    return lock


def _split(tool_name: str) -> tuple[str, str]:
    if "." not in tool_name:
        return "", tool_name
    server, tool = tool_name.split(".", 1)
    return server, tool


def _result(text: str, is_error: bool):
    from mcp.types import CallToolResult, TextContent

    return CallToolResult(content=[TextContent(type="text", text=text)], isError=is_error)


# --------------------------------------------------------------------------
# patch


def apply() -> None:
    """Patch ``MCPConfig.call_tool`` and keep the stdio stderr on disk."""
    from helpers.mcp_handler import MCPConfig

    if _installed():
        return

    original = MCPConfig.call_tool

    async def call_tool(self, tool_name: str, input_data: dict[str, Any] | None = None):
        server, tool = _split(tool_name)
        if tool in CACHE_TOOL_NAMES:
            handler = _HANDLERS[tool]
            try:
                text, is_error = handler(dict(input_data or {}))
            except Exception as exc:  # pragma: no cover - defensive
                text = json.dumps(
                    {"success": False, "error": f"{type(exc).__name__}: {exc}"},
                    ensure_ascii=False,
                )
                is_error = True
            return _result(text, is_error)

        lock = _lock_for(server)
        timeout = lock_timeout_seconds()
        try:
            await asyncio.wait_for(lock.acquire(), timeout=timeout)
        except asyncio.TimeoutError:
            return _result(busy_text(timeout), True)

        try:
            return await original(self, tool_name, input_data)
        except Exception as exc:
            message = str(exc)
            if "EADDRINUSE" in message or "already in use" in message or "58891" in message:
                detail = json.dumps(
                    {"error": "MCP_PORT_IN_USE", "message": PORT_TEXT, "detail": message[:400]},
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
                return _result(detail, True)
            raise
        finally:
            lock.release()

    MCPConfig.call_tool = call_tool
    call_tool.__a0flatpak_mcp__ = True  # type: ignore[attr-defined]
    MCPConfig._a0flatpak_mcp_patched = True

    _install_stderr_tee()


def _installed() -> bool:
    """True when the wrapper is the current ``call_tool``.

    The marker lives on the function, not on the class.  A later patch that
    replaces ``call_tool`` would otherwise leave a class flag that claims the
    wrapper is present when it is gone.
    """
    try:
        from helpers.mcp_handler import MCPConfig

        return bool(getattr(getattr(MCPConfig, "call_tool", None), "__a0flatpak_mcp__", False))
    except Exception:
        return False


# --------------------------------------------------------------------------
# MT9: keep the stdio stderr where an operator can read it


class _TeeLog:
    """Write to the temporary file and to ``usr/logs/mcp-<server>.log``.

    ``MCPClientBase.get_log`` reads through ``seek``/``read``, so those calls
    must still reach the temporary file.  Disk writes are best effort: a full
    disk must not break a tool call.
    """

    def __init__(self, temporary, path: str):
        self._temporary = temporary
        self._path = path
        self._handle = None

    def fileno(self) -> int:
        """Return the wrapped file's descriptor, as subprocess needs it."""
        temporary = self._open_temporary()
        try:
            return int(temporary.fileno())
        except (AttributeError, OSError, io.UnsupportedOperation) as exc:
            raise io.UnsupportedOperation("fileno") from exc

    def isatty(self) -> bool:
        try:
            return bool(self._open_temporary().isatty())
        except (AttributeError, OSError, io.UnsupportedOperation):
            return False

    def writable(self) -> bool:
        temporary = self._open_temporary()
        try:
            return bool(temporary.writable())
        except (AttributeError, OSError):
            return True

    def readable(self) -> bool:
        temporary = self._open_temporary()
        try:
            return bool(temporary.readable())
        except (AttributeError, OSError):
            return True

    def seekable(self) -> bool:
        temporary = self._open_temporary()
        try:
            return bool(temporary.seekable())
        except (AttributeError, OSError):
            return True

    @property
    def encoding(self):
        return getattr(self._open_temporary(), "encoding", "utf-8")

    @property
    def errors(self):
        return getattr(self._open_temporary(), "errors", "strict")

    @property
    def closed(self) -> bool:
        return self.__dict__.get("_temporary") is None

    def __getattr__(self, name):
        temporary = self.__dict__.get("_temporary")
        if temporary is None:
            raise AttributeError(name)
        return getattr(temporary, name)

    def _open_temporary(self):
        temporary = self._temporary
        if temporary is None:
            raise ValueError("I/O operation on closed file.")
        return temporary

    def _disk(self):
        if self._handle is None:
            try:
                os.makedirs(os.path.dirname(self._path), exist_ok=True)
                self._handle = open(self._path, "a", encoding="utf-8")
            except OSError:
                self._handle = False
        return self._handle or None

    def write(self, text):
        written = self._open_temporary().write(text)
        handle = self._disk()
        if handle is not None:
            try:
                handle.write(text)
                handle.flush()
            except OSError:
                pass
        return written

    def note(self, text: str) -> None:
        """Write a line to disk only.

        The temporary file stays clean, so ``get_log()`` shows what the server
        wrote and nothing else.  The disk copy gets one line per MCP session.
        Those lines are the only record that each tool call starts a new
        process.
        """
        handle = self._disk()
        if handle is None:
            return
        try:
            handle.write(f"{text}\n")
            handle.flush()
        except OSError:
            pass

    def flush(self):
        self._open_temporary().flush()
        handle = self._disk()
        if handle is not None:
            try:
                handle.flush()
            except OSError:
                pass

    def seek(self, *args, **kwargs):
        return self._open_temporary().seek(*args, **kwargs)

    def read(self, *args, **kwargs):
        return self._open_temporary().read(*args, **kwargs)

    def close(self):
        interior = getattr(self, "_temporary", None)
        if interior is not None:
            self._temporary = None
            try:
                interior.close()
            except Exception:
                pass
        handle = getattr(self, "_handle", None)
        if handle:
            self._handle = None
            try:
                handle.close()
            except Exception:
                pass


def _log_root() -> str:
    root = os.environ.get("A0_BASE_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
        "agent-zero",
    )
    return os.path.join(root, "usr", "logs")


def _install_stderr_tee() -> None:
    from helpers.mcp_handler import MCPClientLocal

    if getattr(getattr(MCPClientLocal, "_create_stdio_transport", None), "__a0flatpak_tee__", False):
        return

    original = MCPClientLocal._create_stdio_transport

    async def _create_stdio_transport(self, current_exit_stack):
        if getattr(self, "log_file", None) is None:
            import tempfile

            name = getattr(getattr(self, "server", None), "name", "server")
            safe = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in str(name))
            temporary = tempfile.TemporaryFile(mode="w+", encoding="utf-8")
            tee = _TeeLog(temporary, os.path.join(_log_root(), f"mcp-{safe}.log"))
            server = getattr(self, "server", None)
            command = getattr(server, "command", "") or ""
            args = " ".join(str(arg) for arg in (getattr(server, "args", None) or []))
            tee.note(f"[{_iso(time.time())}] session start: {command} {args}".strip())
            self.log_file = tee
        return await original(self, current_exit_stack)

    MCPClientLocal._create_stdio_transport = _create_stdio_transport
    _create_stdio_transport.__a0flatpak_tee__ = True  # type: ignore[attr-defined]
    MCPClientLocal._a0flatpak_stderr_patched = True


def health() -> bool:
    """True when the patch is installed."""
    return _installed()
