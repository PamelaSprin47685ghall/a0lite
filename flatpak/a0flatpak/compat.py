"""Keep ``asyncio.wait_for`` usable under the framework's nested event loop.

The framework applies ``nest_asyncio`` so that a second event loop can be driven
from inside a running one. Its re-entrant ``_run_once`` calls a coroutine's
``send`` directly, so no task is current while that coroutine runs. Since Python
3.11 ``asyncio.wait_for`` is implemented with ``asyncio.timeout``, which raises
``RuntimeError: Timeout should be used inside a task`` when no task is current.

python-engineio starts a background service task that calls ``wait_for`` in a
loop. Under ``nest_asyncio`` that task raises on every iteration, and the
resulting traceback storm starves the event loop: the server accepts
connections but never answers them.

The replacement below behaves the same when a task is current, which is the
normal case, and falls back to an explicit timer when one is not.
"""

from __future__ import annotations

import asyncio

_STUB = None


def apply() -> None:
    """Install the fallback once."""
    if getattr(asyncio, "_a0flatpak_wait_for", False):
        return

    original = asyncio.wait_for

    async def wait_for(fut, timeout=None):
        current = asyncio.current_task()
        if timeout is None or (current is not None and current is not _STUB):
            return await original(fut, timeout)

        task = asyncio.ensure_future(fut)
        loop = asyncio.get_running_loop()
        timer = loop.call_later(timeout, task.cancel)
        try:
            return await task
        except asyncio.CancelledError:
            if task.cancelled():
                raise asyncio.TimeoutError() from None
            raise
        finally:
            timer.cancel()

    asyncio.wait_for = wait_for
    asyncio._a0flatpak_wait_for = True

    _patch_current_task()
    _patch_sniffio()
    _preload_pty_modules()

class _TaskStub:
    """Stand-in for the task that a re-entrant loop never sets.

    ``nest_asyncio`` removes the running task from asyncio's bookkeeping before
    it dispatches a callback. Code that is not a coroutine therefore asks for a
    current task and gets none, while asyncio and anyio still require an object
    with the task protocol. Each member below exists for a concrete reader:

    * ``done``, ``_must_cancel`` and ``_fut_waiter`` are read by anyio's
      ``CancelScope._deliver_cancellation`` before it decides whether to cancel
      a task (anyio 4.15.1, ``_backends/_asyncio.py`` lines 596-607).
    * ``cancelling``, ``uncancel`` and ``cancel`` are the timeout protocol used
      by ``asyncio.timeout`` (Python 3.14, ``asyncio/timeouts.py`` lines 92,
      111 and 128) and by ``CancelScope.__exit__`` (anyio line 500).
    * ``get_coro`` and ``get_name`` are read by anyio's task introspection
      (lines 355 and 2297-2299); a stub has no coroutine, so it reports no
      coroutine and a fixed name.
    * ``add_done_callback`` and ``remove_done_callback`` are used when anyio
      treats the root task as a lifetime token (lines 2678, 2693 and 2838).

    There is deliberately no generic ``__getattr__``: a missing attribute must
    stay visible instead of turning into a made-up value.
    """

    # anyio reads these two attributes directly. A stub has no coroutine that
    # could hold a pending cancellation and awaits no future.
    _must_cancel = False
    _fut_waiter = None

    # asyncio.Task exposes a parent in 3.14's task metadata. A stub has none.
    parent = None

    def cancelling(self) -> int:
        """Return the number of pending cancellations: none."""
        return 0

    def uncancel(self) -> int:
        """Accept a cancellation-count decrement without changing state."""
        return 0

    def cancel(self, msg=None) -> bool:
        """Refuse cancellation; there is no coroutine to interrupt."""
        return False

    def cancelled(self) -> bool:
        return False

    def done(self) -> bool:
        # A stdlib TaskGroup treats a done parent as finished
        # (asyncio/taskgroups.py:248). "No task" is not "finished".
        return False

    def get_name(self) -> str:
        return "a0flatpak-stub"

    def set_name(self, value) -> None:
        """Keep the fixed name; the singleton must not accumulate state."""

    @property
    def _loop(self):
        """Return the running loop, which is the only loop a stub can reach.

        anyio's ``WorkerThread`` reads ``root_task._loop`` and schedules its
        callbacks there. A stub has no loop of its own, so the running loop is
        the honest answer.
        """
        return asyncio.get_running_loop()

    def get_loop(self):
        return self._loop

    def get_coro(self):
        """Return no coroutine: the stub never ran one."""
        return None

    def get_parent(self):
        return None

    def get_stack(self, limit=None) -> list:
        return []

    def add_done_callback(self, callback, *, context=None) -> None:
        """Silently ignore completion callbacks.

        The stub never completes. Firing a callback now would announce an
        event that did not happen; anyio uses this hook to stop its shared
        thread pool. Storing it would retain the callback forever.
        """

    def remove_done_callback(self, callback) -> int:
        return 0

    def __repr__(self) -> str:
        return "a0flatpak-stub"


def _patch_current_task() -> None:
    """Report the real task when the loop has one, a stub when it has none.

    ``nest_asyncio`` swaps in the pure-Python ``Task``. That task publishes
    itself in ``asyncio.tasks._current_tasks``, but ``asyncio.current_task``
    was bound to the C implementation, which reads the C module's registry.
    The result is ``None`` even while a real coroutine runs, and anyio then
    stores the stub as a cancel-scope host. The second lookup recovers the task
    that the pure-Python task published; only callbacks dispatched with no task
    at all reach the stub.
    """
    import asyncio.tasks as tasks_module

    if getattr(tasks_module, "_a0flatpak_current_task", False):
        return

    global _STUB
    original = tasks_module.current_task
    _STUB = _TaskStub()

    def current_task(loop=None):
        task = original(loop)
        if task is not None:
            return task
        if loop is None:
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                return _STUB
        current_tasks = getattr(tasks_module, "_current_tasks", None)
        task = current_tasks.get(loop) if current_tasks is not None else None
        return task if task is not None else _STUB

    tasks_module.current_task = current_task
    asyncio.current_task = current_task
    tasks_module._a0flatpak_current_task = True

def _patch_sniffio() -> None:
    """Name the async library even where nest_asyncio hides the context.

    httpx asks sniffio which library is driving the call before it opens a
    connection. sniffio answers by looking for a current task, and nest_asyncio
    runs callbacks without one, so the answer becomes "unknown async library, or
    not in async context" and every model request fails. Everything in this
    process is asyncio, so that is the answer when nothing else is detected.
    """
    try:
        import sniffio
    except ImportError:
        return

    if getattr(sniffio, "_a0flatpak_patched", False):
        return

    original = sniffio.current_async_library

    def current_async_library() -> str:
        try:
            return original()
        except sniffio.AsyncLibraryNotFoundError:
            return "asyncio"

    sniffio.current_async_library = current_async_library
    sniffio._a0flatpak_patched = True


def _preload_pty_modules() -> None:
    """Import the terminal modules before any worker thread can.

    The code execution plugin imports ``pty`` when it starts a shell. When two
    threads reach that import at the same time, one of them receives a
    partially initialised module and ``pty.openpty`` is missing. Importing them
    here, while the process is single-threaded, removes the race.
    """
    for name in ("pty", "tty", "termios", "fcntl"):
        try:
            __import__(name)
        except ImportError:
            pass
