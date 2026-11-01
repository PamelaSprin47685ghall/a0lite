"""Keep the writable part of the framework tree outside the read-only bundle.

The framework writes under ``usr/`` next to its code: plugin state, downloads,
the browser cache and the desktop sessions. In a Flatpak build the application
directory is read-only, so ``A0_BASE_DIR`` points at a writable tree that the
launcher seeds from the bundle on first start.

This module only reports the directory; the launcher does the seeding, because
that has to happen before Python starts.
"""

from __future__ import annotations

import os


def data_root() -> str:
    """Return the writable base directory used for framework state.

    The framework resolves ``usr/...`` against this root, so the root is the
    parent of the seeded ``usr`` tree, not the tree itself.
    """
    return os.environ.get("A0_BASE_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
        "agent-zero",
    )


def apply() -> None:
    """Point the framework at a writable base directory.

    ``helpers.files`` resolves every ``usr/...`` path against its own module
    directory, which is inside the read-only application tree. The writable
    tree is seeded from the bundle by the launcher; here the resolver is
    redirected to it.
    """
    import helpers.files as files

    if getattr(files, "_a0flatpak_base_patched", False):
        return

    root = data_root()
    # The framework reads configuration and prompt files relative to this root,
    # so the writable tree carries a seeded copy of the bundle's layout.
    for name in ("conf", "prompts", "agents", "knowledge", "instruments", "usr"):
        source = os.path.join("/app/share/agent-zero", name)
        target = os.path.join(root, name)
        if os.path.isdir(source) and not os.path.isdir(target):
            _copy_tree(source, target)
    os.makedirs(os.path.join(root, "usr", "plugins"), exist_ok=True)
    files._base_dir = root
    files._a0flatpak_base_patched = True


def _copy_tree(source: str, target: str) -> None:
    """Copy a directory tree, tolerating entries that cannot be read."""
    import shutil

    try:
        shutil.copytree(source, target, dirs_exist_ok=True, symlinks=True)
    except Exception:
        pass
