"""Share the host desktop instead of starting a private X server.

``plugins/_desktop`` starts Xvfb on a private display, launches an XFCE
session there, then publishes the display with ``xpra shadow``. The Flatpak
build cannot install Xvfb, XFCE or LibreOffice, and the user already has a
working desktop.

This module keeps the ``xpra shadow`` step and points it at the host display
that Flatpak mounts into the sandbox:

* ``_spawn_desktop_locked`` skips Xvfb and XFCE and shadows ``DISPLAY``.
* ``_session_env`` keeps the caller's ``HOME`` and ``XAUTHORITY`` so Xpra can
  authenticate against the host X server.
* ``_allocate_endpoint_locked`` returns the host display number with a free
  port for Xpra.

Only the system desktop is redirected. Document windows open inside that same
session, so they inherit the host display.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from typing import Any

XPRA_START_TIMEOUT = 30.0

# The bundle installs the Xpra HTML5 client here instead of the Debian path.
BUNDLED_XPRA_HTML_ROOT = "/app/share/xpra/www"

# Headless fallback: Xpra starts this X server instead of the default Xorg.
BUNDLED_XVFB = "/app/bin/Xvfb"
BUNDLED_XVFB_LIBS = "/app/lib/xvfb"
BUNDLED_GI_LIBS = "/app/lib/gi"
BUNDLED_PY_DEPS = "/app/share/python-deps"


def _host_display() -> str:
    """Return the display to shadow.

    A headless host has no X server, so ``DISPLAY`` is empty. In that case the
    session falls back to Xpra's own virtual display, which Xpra creates when
    it is started without an existing ``DISPLAY``.
    """
    value = os.environ.get("DISPLAY", "").strip()
    if value and _display_is_reachable(value):
        return value
    if shutil.which("Xvfb") or os.path.isfile(BUNDLED_XVFB):
        return ""
    raise RuntimeError(
        "No desktop to share: DISPLAY is unset and Xvfb is not installed. "
        "Start Agent Zero with an X11 display, or install the headless X server."
    )


def _display_is_reachable(display: str) -> bool:
    """Return True when the display has a live X socket.

    Flatpak exports ``DISPLAY`` for ``--socket=x11`` even on a headless host,
    where no X server is listening. Shadowing such a display fails, so the
    socket is checked before it is used.
    """
    number = _display_number(display)
    socket_path = f"/tmp/.X11-unix/X{number}"
    return os.path.exists(socket_path)


def _display_number(display: str) -> int:
    host_part, _, screen = display.partition(".")
    _, _, number = host_part.partition(":")
    try:
        return int(number)
    except ValueError:
        return 0


def _patch_launcher_setup(desktop_session) -> None:
    """Skip the LibreOffice launcher preparation when LibreOffice is absent.

    ``_prepare_desktop_launchers`` writes LibreOffice desktop entries into the
    session profile and aborts the whole session when ``soffice`` is missing.
    On the host-display path the user's own desktop already provides those
    entries, so a missing LibreOffice is not fatal.
    """
    manager = desktop_session.DesktopSessionManager
    if getattr(manager, "_a0flatpak_launchers_patched", False):
        return

    original = manager._prepare_desktop_launchers

    def _prepare_desktop_launchers(self, session) -> None:
        from plugins._office.helpers import libreoffice

        if not libreoffice.find_soffice():
            session.profile_dir.mkdir(parents=True, exist_ok=True)
            return
        return original(self, session)

    manager._prepare_desktop_launchers = _prepare_desktop_launchers
    manager._a0flatpak_launchers_patched = True


def _patch_desktop_status(desktop_session) -> None:
    """Report the host-display requirements instead of the private-display ones.

    ``plugins._desktop.helpers.desktop_session.collect_desktop_status`` requires
    LibreOffice, the XFCE pieces and the X11 utilities that a private desktop
    session starts. The host-display path needs Xpra and its HTML5 client only.
    """
    if getattr(desktop_session, "_a0flatpak_patched", False):
        return

    original_collect = desktop_session.collect_desktop_status

    def collect_desktop_status() -> dict[str, Any]:
        status = original_collect()
        binaries = status.get("binaries", {})
        missing = []
        if not binaries.get("xpra"):
            missing.append("xpra")
        if not status.get("xpra_html_root"):
            missing.append("xpra-html5")
        healthy = not missing
        status.update(
            {
                "healthy": healthy,
                "installing": False,
                "missing": missing,
                "state": "healthy" if healthy else "missing",
                "message": (
                    "Agent Zero Desktop sessions are available."
                    if healthy
                    else f"Agent Zero Desktop sessions need: {', '.join(missing)}."
                ),
            }
        )
        return status

    desktop_session.collect_desktop_status = collect_desktop_status
    desktop_session._a0flatpak_patched = True


def _patch_status_checks() -> None:
    """Report the host-display requirements instead of the private-display ones.

    ``helpers.virtual_desktop.collect_status`` requires Xvfb, XFCE, dbus-launch
    and the xpra-x11 package, all of which belong to the private-display path.
    The host-display path needs Xpra and the HTML5 client only.
    """
    from pathlib import Path

    from helpers import virtual_desktop

    bundled_root = Path(BUNDLED_XPRA_HTML_ROOT)
    if bundled_root.is_dir() and bundled_root not in virtual_desktop.XPRA_HTML_ROOT_CANDIDATES:
        virtual_desktop.XPRA_HTML_ROOT_CANDIDATES = (
            bundled_root,
            *virtual_desktop.XPRA_HTML_ROOT_CANDIDATES,
        )

    if getattr(virtual_desktop, "_a0flatpak_patched", False):
        return

    original_collect = virtual_desktop.collect_status

    def collect_status() -> dict[str, Any]:
        status = original_collect()
        xpra = status["binaries"].get("xpra", "")
        html_root = status.get("xpra_html_root", "")
        missing = []
        if not xpra:
            missing.append("xpra")
        if not html_root:
            missing.append("xpra-html5")
        healthy = not missing
        status["healthy"] = healthy
        status["missing"] = missing
        status["state"] = "healthy" if healthy else "missing"
        status["message"] = (
            "Host desktop sharing is available."
            if healthy
            else f"Host desktop sharing needs: {', '.join(missing)}."
        )
        return status

    virtual_desktop.collect_status = collect_status
    virtual_desktop._a0flatpak_patched = True


def _patch_resize_display() -> None:
    """Accept a resize request when the bundle has no xrandr.

    ``virtual_desktop.resize_display`` returns ``ok: false`` when ``xrandr`` is
    missing, and ``VirtualDesktopGateway`` turns that into HTTP 400.  The
    host-display path must not change the real monitor mode anyway, so report
    the requested size as accepted but not applied.  The iframe scales its own
    view; the dropped ``window_class``/``keys`` arguments only matter for the
    private-display path, which this drop-in already bypasses.
    """
    from helpers import virtual_desktop

    if getattr(virtual_desktop, "_a0flatpak_resize_patched", False):
        return

    original = virtual_desktop.resize_display

    def resize_display(**kwargs: Any) -> dict[str, Any]:
        if shutil.which("xrandr"):
            return original(**kwargs)
        width, height = virtual_desktop.normalize_size(
            kwargs.get("width", 0),
            kwargs.get("height", 0),
            max_width=kwargs.get("max_width", virtual_desktop.MAX_WIDTH),
            max_height=kwargs.get("max_height", virtual_desktop.MAX_HEIGHT),
        )
        return {
            "ok": True,
            "width": width,
            "height": height,
            "resized": False,
            "note": "xrandr is not installed; the display keeps its mode.",
        }

    virtual_desktop.resize_display = resize_display
    virtual_desktop._a0flatpak_resize_patched = True


def _apply_desktop_session(desktop_session) -> None:
    """Patch one live copy of the desktop plugin module."""
    # Deliberately local: plugin_guard retries this function after a plugin
    # purge, and helpers may not be importable yet when the guard first runs.
    try:
        from helpers import virtual_desktop
    except ImportError as exc:
        print(f"a0flatpak: desktop session patch skipped: {exc}", file=sys.stderr)
        return

    _patch_desktop_status(desktop_session)
    _patch_launcher_setup(desktop_session)

    manager = desktop_session.DesktopSessionManager
    if getattr(manager, "_a0flatpak_patched", False):
        return

    original_allocate = manager._allocate_endpoint_locked
    original_session_env = manager._session_env
    original_spawn = manager._spawn_desktop_locked

    def _allocate_endpoint_locked(self, *args: Any, **kwargs: Any) -> tuple[int, int]:
        host = _host_display()
        display = _display_number(host)
        used_ports = {session.xpra_port for session in self._sessions.values()}
        for offset in range(desktop_session.MAX_SESSIONS):
            port = desktop_session.XPRA_PORT_BASE + offset
            if port in used_ports:
                continue
            if desktop_session._port_is_free(port):
                return display, port
        return original_allocate(self, *args, **kwargs)

    def _session_env(self, session: Any) -> dict[str, str]:
        env = original_session_env(self, session)
        if session.session_id != desktop_session.SYSTEM_SESSION_ID:
            return env
        env["HOME"] = os.environ.get("HOME", env.get("HOME", ""))
        host_xauthority = os.environ.get("XAUTHORITY", "")
        if host_xauthority:
            env["XAUTHORITY"] = host_xauthority
        else:
            env.pop("XAUTHORITY", None)
        return env

    def _spawn_desktop_locked(self, session: Any) -> None:
        if session.session_id != desktop_session.SYSTEM_SESSION_ID:
            return original_spawn(self, session)

        desktop_session.STATE_DIR.mkdir(parents=True, exist_ok=True)
        desktop_session.SESSION_DIR.mkdir(parents=True, exist_ok=True)
        session.profile_dir.mkdir(parents=True, exist_ok=True)

        host = _host_display()
        session.display = (
            _display_number(host) if host else desktop_session.DISPLAY_BASE
        )
        (session.profile_dir / "spawn-diag.txt").write_text(
            f"host={host!r} display={session.display} port={session.xpra_port}\n"
        )

        xpra = desktop_session._require_binary("xpra")
        interpreter = [sys.executable]
        env = {**virtual_desktop.XPRA_START_ENV, **self._display_env(session)}
        # The Xpra client needs the bundled gi and cairo modules, which the
        # runtime's interpreter cannot import.
        existing = env.get("PYTHONPATH", "")
        parts = [p for p in existing.split(":") if p]
        for extra in (BUNDLED_PY_DEPS,):
            if extra not in parts:
                parts.insert(0, extra)
        env["PYTHONPATH"] = ":".join(parts)
        # An empty PYTHONHOME happens to mean "unset" on CPython 3.14, but that
        # is an implementation detail; removing the key is what "unset" means.
        env.pop("PYTHONHOME", None)

        # Xpra authenticates its own sockets with the same key as the Web UI:
        # the `env` module reads XPRA_PASSWORD from this process environment,
        # and --tcp-auth=env installs it for every TCP socket of the server
        # (scripts/parsing.py:1920). The host-display shadow branch publishes
        # the same 127.0.0.1 port as the headless one, so both paths get it.
        auth_key = os.environ.get("A0_AUTH_KEY", "").strip()
        if auth_key:
            env["XPRA_PASSWORD"] = auth_key
        xpra_auth = ["--tcp-auth=env"] if auth_key else []

        if host:
            env["DISPLAY"] = host
        else:
            # Headless: let Xpra start its own Xvfb and serve that display.
            env.pop("DISPLAY", None)
            existing = env.get("LD_LIBRARY_PATH", "")
            parts = [p for p in existing.split(":") if p]
            for extra in (BUNDLED_XVFB_LIBS, BUNDLED_GI_LIBS):
                if extra not in parts:
                    parts.insert(0, extra)
            env["LD_LIBRARY_PATH"] = ":".join(parts)
            # --daemon=no keeps the server as a child we can wait for, but Xpra
            # only opens --log-file when daemonizing (scripts/server.py:
            # log_to_file = opts.daemon or XPRA_LOG_TO_FILE == "1"). Without
            # this flag the command line promises a log file that never appears.
            env["XPRA_LOG_TO_FILE"] = "1"
            # start-desktop auto-starts `xpra desktop-greeter` when no start
            # command exists (scripts/server.py). The bundle ships the HTML5
            # client, not the GTK client (xpra.client.gui), so that child dies
            # with `xpra main error` before it can draw anything. Do not start
            # a component the bundle cannot run; the HTML5 client is the UI.
            env["XPRA_DESKTOP_GREETER"] = "0"
            xvfb = shutil.which("Xvfb") or BUNDLED_XVFB
            command = [
                *interpreter, xpra,
                "start-desktop",
                f":{session.display or 120}",
                f"--xvfb={xvfb} -screen 0 {desktop_session.MAX_SCREEN_WIDTH}x{desktop_session.MAX_SCREEN_HEIGHT}x24 -nolisten tcp -noreset",
                "--daemon=no",
                "--mdns=no",
                "--html=on",
                "--tray=no",
                "--notifications=no",
                f"--bind-tcp=127.0.0.1:{session.xpra_port}",
                *xpra_auth,
                f"--log-dir={session.profile_dir}",
                "--log-file=xpra.log",
            ]
            log_path = session.profile_dir / "xpra-stderr.log"
            session.processes["xpra"] = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=open(log_path, "wb"),
                env=env,
            )
            try:
                desktop_session._wait_for_port(
                    "127.0.0.1",
                    session.xpra_port,
                    timeout=XPRA_START_TIMEOUT,
                    process=session.processes.get("xpra"),
                )
            except Exception:
                (session.profile_dir / "xpra-cmd.txt").write_text(
                    " ".join(command) + "\n\n" + str(env) + "\n"
                )
                raise
            return

        # The bundle ships Pillow but not the Xpra JPEG module, so the default
        # `--encoding=jpeg` leaves no usable packet encoder. Pillow covers png
        # and webp, which is what the HTML5 client renders.
        command = desktop_session._xpra_shadow_command(xpra, session)
        command = [arg for arg in command if not arg.startswith("--encoding=")]
        anchor = command.index("--speed=80") + 1 if "--speed=80" in command else len(command)
        command.insert(anchor, "--encoding=png")
        # Xpra disables its mmap transport module when --mmap=no is given, and
        # its own hello path then imports xpra.net.mmap.common to build the
        # packet reader. That import sees the disabled module and dies with
        # "No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a
        # package", which aborts the handshake before any pixel is sent.
        # Leaving mmap at its default lets the handshake complete.
        #
        # This is an upstream contradiction - disabling mmap is what triggers
        # the mmap import - so the flag is dropped rather than replaced by
        # anything of ours.
        command = [arg for arg in command if arg != "--mmap=no"]
        if xpra_auth:
            # Xpra appends repeated --tcp-auth values (action="append"), and two
            # `env` modules would challenge the client twice, so exactly one is
            # kept: ours replaces any the upstream command may grow later.
            command = [arg for arg in command if not arg.startswith("--tcp-auth=")]
            command.extend(xpra_auth)
        # The xpra script uses whichever interpreter runs it. Only the
        # framework environment has the gi, cairo and Pillow modules Xpra needs
        # for an HTML5 session, so the interpreter is pinned explicitly.
        command = [*interpreter, *command]
        probe = subprocess.run(
            [xpra, "--version"], capture_output=True, text=True, env=env, timeout=30
        )
        check = subprocess.run(
            [
                *interpreter,
                "-c",
                "import xpra.net.mmap as m; assert getattr(m, '__path__', None), "
                "'xpra.net.mmap is not a package'",
            ],
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )
        if check.returncode != 0:
            # A pointer for the next layout change: this fails before the
            # handshake, where the message is easy to attribute.
            print(
                "a0flatpak: xpra.net.mmap is not a package in this interpreter "
                f"(rc={check.returncode}): {(check.stderr or check.stdout).strip()[-300:]}",
                file=sys.stderr,
            )
        (session.profile_dir / "xpra-cmd.txt").write_text(
            " ".join(command)
            + "\n\nVERSION rc=" + str(probe.returncode) + " out=" + probe.stdout.strip()[:80]
            + " err=" + probe.stderr.strip()[:200]
            + "\n"
        )
        shadow_stderr = open(session.profile_dir / "xpra-stderr.log", "wb")
        session.processes["xpra"] = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=shadow_stderr,
            env=env,
        )
        desktop_session._wait_for_port(
            "127.0.0.1",
            session.xpra_port,
            timeout=XPRA_START_TIMEOUT,
            process=session.processes.get("xpra"),
        )

    manager._allocate_endpoint_locked = _allocate_endpoint_locked
    manager._session_env = _session_env
    manager._spawn_desktop_locked = _spawn_desktop_locked
    manager._a0flatpak_patched = True


def apply() -> None:
    """Redirect the system desktop session to the host display."""
    from a0flatpak import plugin_guard

    _patch_status_checks()
    _patch_resize_display()
    plugin_guard.register("_desktop", apply)
    plugin_guard.register_module("_desktop.helpers.desktop_session", _apply_desktop_session)
    sessions = plugin_guard.live_modules("_desktop.helpers.desktop_session")
    if not sessions:
        from plugins._desktop.helpers import desktop_session as fallback
        sessions = [fallback]
    for desktop_session in sessions:
        _apply_desktop_session(desktop_session)
