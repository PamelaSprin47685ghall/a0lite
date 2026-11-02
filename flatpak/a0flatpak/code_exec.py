"""Run terminal commands locally instead of over SSH.

The code execution plugin picks its shell with ``ssh_enabled: auto``, which
means "SSH unless this process is inside Docker". A Flatpak is not Docker, so
the plugin dials an SSH server that only exists in the container image, and
every terminal call fails with a connection error.

Inside this sandbox the local TTY is already the user's machine, reached with
the user's own permissions, so ``auto`` resolves to local here. An explicit
``ssh_enabled: true`` in the plugin configuration still wins.

The seam is the configuration reader rather than the tool module: plugin tools
are loaded per execution, so a patch on the module they were first imported as
does not survive.
"""

from __future__ import annotations

PLUGIN = "_code_execution"


def apply() -> None:
    """Treat an unset shell choice as local."""
    from helpers import plugins

    if getattr(plugins, "_a0flatpak_code_exec_patched", False):
        return

    original = plugins.get_plugin_config

    def get_plugin_config(name, *args, **kwargs):
        config = original(name, *args, **kwargs)
        if name != PLUGIN or not isinstance(config, dict):
            return config
        if str(config.get("ssh_enabled", "auto")).strip().lower() != "auto":
            return config
        resolved = dict(config)
        resolved["ssh_enabled"] = False

        # The local shell inside the sandbox prints a bare ``bash-5.2$`` prompt,
        # which none of the shipped patterns match, so every command waited for
        # its timeout before returning. This pattern matches that prompt and
        # anything else ending in a shell sigil.
        patterns = str(resolved.get("prompt_patterns") or "")
        extra = "[a-zA-Z0-9_.-]+[$#] ?$"
        if extra not in patterns:
            resolved["prompt_patterns"] = (patterns + "\n" + extra).strip()
        return resolved

    plugins.get_plugin_config = get_plugin_config
    plugins._a0flatpak_code_exec_patched = True
