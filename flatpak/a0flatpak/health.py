"""Answer the readiness probe the framework polls at startup.

``helpers.server_startup.wait_for_health`` requests ``/api/health`` and waits
for a 200 before it declares the server ready. This snapshot of the framework
ships no such route: the request falls through to the API catch-all, which
answers 404, so the probe never succeeds. The watchdog then retires the attempt
and eventually the process exits, which a long-running service cannot afford.

The route is registered on the Flask application while it is still being
assembled, so it is served like any other endpoint and costs one dictionary
lookup per request.
"""

from __future__ import annotations

PATH = "/api/health"


def register(app) -> None:
    if getattr(app, "_a0flatpak_health_route", False):
        return

    app.add_url_rule(
        PATH,
        endpoint="a0flatpak_health",
        view_func=lambda: {"status": "ok"},
        methods=["GET", "HEAD"],
    )
    app._a0flatpak_health_route = True
