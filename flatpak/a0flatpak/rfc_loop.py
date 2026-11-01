"""Run the scheduler in the single bundled process.

``helpers/job_loop.py`` treats every non-dockerized instance as a development
client that must pause the job loop of a paired container. The Flatpak build is
a complete instance with no container to pair with, so the pause call fails on
every tick with ``No RFC password``.

Disabling ``runtime.is_development`` makes the framework take its complete
installation path: the job loop keeps running and no RFC call is attempted.
"""

from __future__ import annotations


def apply() -> None:
    """Report this instance as complete rather than as a development client."""
    from helpers import runtime

    if getattr(runtime, "_a0flatpak_patched", False):
        return

    runtime.is_development = lambda: False
    runtime._a0flatpak_patched = True
