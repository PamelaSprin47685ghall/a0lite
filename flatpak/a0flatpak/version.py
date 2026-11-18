"""Report the packaging build instead of a repository the bundle omits.

Flatpak installs no ``git`` binary and no ``.git`` directory, so
``helpers.git.get_git_info()`` fails and the UI shows ``Version unknown
unknown``.  The build writes its identity to ``.a0-build-info``, the launcher
exports those values, and this module answers ``get_git_info()`` from them.
"""

from __future__ import annotations

import os


def _value(name: str, fallback: str = "") -> str:
    return os.environ.get(name, "").strip() or fallback


def apply() -> None:
    """Answer ``get_git_info`` from the build identity.  Safe to repeat."""
    from helpers import git

    if getattr(git, "_a0flatpak_version_patched", False):
        return

    def get_git_info() -> dict[str, str]:
        version = _value("A0_BUILD_VERSION", "dev")
        build_time = _value("A0_BUILD_TIME")
        return {
            "branch": "flatpak",
            "commit_hash": _value("A0_BUILD_COMMIT"),
            # Older build-info files carry only A0_BUILD_TIME; keep them
            # working but never present the build clock as a commit time.
            "commit_time": _value("A0_COMMIT_TIME", build_time),
            "build_time": build_time,
            "tag": version,
            "short_tag": version,
            "version": version,
        }

    git.get_git_info = get_git_info
    git._a0flatpak_version_patched = True
