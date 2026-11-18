"""Keep the writable part of the framework tree outside the read-only bundle.

The framework writes under ``usr/`` next to its code: plugin state, downloads,
the browser cache and the desktop sessions. In a Flatpak build the application
directory is read-only, so ``A0_BASE_DIR`` points at a writable tree that the
launcher seeds from the bundle on first start.

The launcher seeds the tree before Python starts. ``apply`` fills in whatever
is still missing, for a direct start that skips the launcher, then redirects
the framework's path resolver.
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
    redirected to it and prompt files that an upgrade added are filled in.
    """
    import helpers.files as files

    if getattr(files, "_a0flatpak_base_patched", False):
        return

    root = data_root()
    # The framework reads configuration and prompt files relative to this root,
    # so the writable tree carries a seeded copy of the bundle's layout.
    source_root = "/app/share/agent-zero"
    # ``tools`` belongs here for the same reason as the others: the resolver
    # searches it under this root, and a missing copy turns every top-level
    # tool into "tool not found" while its prompt still advertises it.
    for name in ("conf", "agents", "knowledge", "instruments", "tools", "usr"):
        source = os.path.join(source_root, name)
        target = os.path.join(root, name)
        if os.path.isdir(source) and not os.path.isdir(target):
            _copy_tree(source, target)
    # prompts is merged, not seeded once. The framework reads prompt files
    # without a fallback, so a prompt that an upgrade added is a hard failure
    # until it reaches the writable tree. Existing files stay untouched because
    # the user may have edited them.
    _merge_missing(
        os.path.join(source_root, "prompts"), os.path.join(root, "prompts")
    )
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


def _merge_missing(source: str, target: str) -> None:
    """Copy files that the target does not have yet, never overwriting."""
    import shutil

    if not os.path.isdir(source):
        return
    for current, _directories, files in os.walk(source):
        relative = os.path.relpath(current, source)
        destination_dir = target if relative == "." else os.path.join(target, relative)
        try:
            os.makedirs(destination_dir, exist_ok=True)
        except OSError:
            continue
        for name in files:
            source_file = os.path.join(current, name)
            destination_file = os.path.join(destination_dir, name)
            if os.path.lexists(destination_file):
                continue
            try:
                if os.path.islink(source_file):
                    os.symlink(os.readlink(source_file), destination_file)
                else:
                    shutil.copy2(source_file, destination_file)
            except OSError:
                pass
