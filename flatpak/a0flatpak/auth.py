"""Require a key on every request the Web UI serves.

The framework has no authentication of its own. When the UI is reachable from
outside the machine, ``A0_AUTH_KEY`` puts a check in front of the whole ASGI
stack: the Flask routes, the MCP and A2A mounts, and the socket.io channel.

The seam is ``UiServerRuntime.build_asgi_app``, the single place where the
serving stack is assembled, so the check cannot be bypassed by a route that is
added later. Nothing outside this process is involved.

The key is accepted as ``Authorization: Bearer``, ``X-API-Key``, the ``a0key``
cookie, or a one-time ``?key=`` that sets that cookie for browsers.

Unset ``A0_AUTH_KEY`` and the module does nothing.
"""

from __future__ import annotations

import os
from urllib.parse import parse_qsl

COOKIE = "a0key"
UNAUTHORIZED_BODY = b"unauthorized\n"

# The framework polls this path to decide that its own server came up, and it
# cannot carry a key. It answers with a status only, so leaving it open costs
# nothing; every other path is checked.
EXEMPT_PATHS = frozenset({"/api/health"})


def _key() -> str:
    return os.environ.get("A0_AUTH_KEY", "").strip()


def _header(scope: dict, name: bytes) -> str:
    for header_name, value in scope.get("headers", []):
        if header_name.lower() == name:
            return value.decode("latin-1")
    return ""


def _authorised(scope: dict, key: str) -> tuple[bool, bool]:
    """Return (allowed, came_from_query)."""
    authorization = _header(scope, b"authorization")
    if authorization.lower().startswith("bearer ") and authorization[7:].strip() == key:
        return True, False

    if _header(scope, b"x-api-key") == key:
        return True, False

    for part in _header(scope, b"cookie").split(";"):
        name, _, value = part.strip().partition("=")
        if name == COOKIE and value == key:
            return True, False

    query = parse_qsl(scope.get("query_string", b"").decode("latin-1"),
                      keep_blank_values=True)
    if any(name == "key" and value == key for name, value in query):
        return True, True

    return False, False


def _strip_query_key(scope: dict) -> None:
    """Drop the key from the query so it does not reach the application."""
    query = [(name, value) for name, value in
             parse_qsl(scope.get("query_string", b"").decode("latin-1"),
                       keep_blank_values=True)
             if name != "key"]
    from urllib.parse import urlencode

    scope["query_string"] = urlencode(query).encode("latin-1")


class AuthMiddleware:
    """ASGI gate that rejects requests without the key."""

    def __init__(self, app, key: str) -> None:
        self.app = app
        self.key = key

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] not in {"http", "websocket"}:
            await self.app(scope, receive, send)
            return

        if scope.get("path") in EXEMPT_PATHS:
            await self.app(scope, receive, send)
            return

        allowed, from_query = _authorised(scope, self.key)

        if not allowed:
            if scope["type"] == "websocket":
                await send({"type": "websocket.close", "code": 1008})
                return
            await send({
                "type": "http.response.start",
                "status": 401,
                "headers": [
                    (b"content-type", b"text/plain"),
                    (b"www-authenticate", b"Bearer"),
                    (b"content-length", str(len(UNAUTHORIZED_BODY)).encode()),
                    (b"connection", b"close"),
                ],
            })
            await send({"type": "http.response.body", "body": UNAUTHORIZED_BODY})
            return

        if from_query:
            _strip_query_key(scope)
            cookie = f"{COOKIE}={self.key}; Path=/; HttpOnly; SameSite=Lax".encode()

            async def send_with_cookie(message):
                if message["type"] == "http.response.start":
                    headers = list(message.get("headers", []))
                    headers.append((b"set-cookie", cookie))
                    message = {**message, "headers": headers}
                await send(message)

            await self.app(scope, receive, send_with_cookie)
            return

        await self.app(scope, receive, send)


def apply() -> None:
    """Wrap the assembled ASGI application when a key is configured."""
    key = _key()
    if not key:
        return

    from helpers import ui_server

    runtime = ui_server.UiServerRuntime
    if getattr(runtime, "_a0flatpak_auth_patched", False):
        return

    original = runtime.build_asgi_app

    def build_asgi_app(self, startup_monitor):
        return AuthMiddleware(original(self, startup_monitor), key)

    runtime.build_asgi_app = build_asgi_app
    runtime._a0flatpak_auth_patched = True
