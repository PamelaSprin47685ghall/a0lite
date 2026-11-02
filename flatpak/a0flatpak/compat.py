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

    ``asyncio.timeout`` asks it for a cancellation count and, when the deadline
    passes, tries to cancel it. There is no task to cancel here, so the call is
    accepted and the awaited work is left to finish on its own; without the
    method the timeout handler raises AttributeError and the caller hangs.
    """

    def cancelling(self) -> int:
        return 0

    def uncancel(self) -> int:
        return 0

    def cancel(self, msg=None) -> bool:
        return False

    def cancelled(self) -> bool:
        return False

    def done(self) -> bool:
        return False

    def get_name(self) -> str:
        return "a0flatpak-stub"


def _patch_current_task() -> None:
    """Report a task while the loop runs, even when nest_asyncio runs none.

    Two callers depend on it: ``asyncio.timeout`` asks the current task for its
    cancellation count, and ``sniffio`` uses the same check to name the async
    library for httpx. Both raise when the answer is "no task".
    """
    import asyncio.tasks as tasks_module

    if getattr(tasks_module, "_a0flatpak_current_task", False):
        return

    global _STUB
    original = tasks_module.current_task
    _STUB = _TaskStub()

    def current_task(loop=None):
        task = original(loop)
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
