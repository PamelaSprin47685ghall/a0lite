"""Hook the one place where the serving stack is handed to uvicorn.

The framework does not serve the application it assembles in ``build_asgi_app``.
A plugin hook, ``install_route_hooks``, replaces that method on the instance, so
patching the class method misses every request: the replacement is what uvicorn
receives.

``run_uvicorn_with_retries`` is the boundary that every path crosses, and it is
called with the final callable. Wrapping there covers the application, the MCP
and A2A mounts and the socket.io channel, whoever assembled them.

The resulting ASGI application is wrapped in the key check when
``A0_AUTH_KEY`` is set. The health route is left to the framework: ``api/health.py``
already serves ``/api/health`` with authentication disabled.
"""

from __future__ import annotations

import os


def apply() -> None:
    """Wrap ``run_uvicorn_with_retries`` once."""
    from helpers import server_startup

    if getattr(server_startup, "_a0flatpak_serve_patched", False):
        return

    original = server_startup.run_uvicorn_with_retries
    key = os.environ.get("A0_AUTH_KEY", "").strip()

    def run_uvicorn_with_retries(*args, **kwargs):
        build = kwargs.get("build_asgi_app")
        if build is not None and key:
            from a0flatpak import auth

            def build_wrapped(startup_monitor):
                return auth.AuthMiddleware(build(startup_monitor), key)

            kwargs["build_asgi_app"] = build_wrapped

        return original(*args, **kwargs)

    server_startup.run_uvicorn_with_retries = run_uvicorn_with_retries
    server_startup._a0flatpak_serve_patched = True
