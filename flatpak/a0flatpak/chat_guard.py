"""Reject an empty chat message before it reaches the agent.

``api/message.py`` reads the text with ``input_data.get("text", "")`` and
passes the result to ``AgentContext.communicate`` without a check.  A request
with no ``text`` field, or with ``""``, ``null`` or only whitespace, therefore
starts a normal turn in the most recently used context: the model greets the
caller and the API answers 200.  ``api/api_message.py`` already answers 400
for the same input, so the two chat entry points disagree.

This module wraps ``Message.process`` and answers 400 before the handler looks
up a context, so an empty request cannot open or touch a conversation.
"""

from __future__ import annotations

import importlib
import json

from helpers.api import Response

from a0flatpak import plugin_guard

MODULE = "api.message"
CLASS = "Message"

ERROR_BODY = {
    "ok": False,
    "error": "EMPTY_MESSAGE",
    "message": "message text is required",
}
# The acceptance contract compares the body text, so keep it byte for byte.
ERROR_JSON = json.dumps(ERROR_BODY, separators=(",", ":"))


def request_text(input_data, request):
    """Read ``text`` from the same source that the handler reads."""
    content_type = getattr(request, "content_type", "") or ""
    if content_type.startswith("multipart/form-data"):
        form = getattr(request, "form", None)
        if form is None:
            return None
        return form.get("text")
    data = input_data if isinstance(input_data, dict) else {}
    return data.get("text")


def is_empty(text) -> bool:
    """Return True when ``text`` carries no message."""
    if text is None:
        return True
    if isinstance(text, str):
        return not text.strip()
    return False


def _patch(module) -> None:
    handler = getattr(module, CLASS, None)
    if not isinstance(handler, type):
        plugin_guard.log("chat_guard", f"{MODULE}.{CLASS} is missing")
        return
    if getattr(handler, "_a0flatpak_chat_patched", False):
        return

    original = handler.process

    async def process(self, input, request):
        try:
            text = request_text(input, request)
        except Exception as exc:
            plugin_guard.log("chat_guard", "cannot read the text field", exc)
            return await original(self, input, request)
        if is_empty(text):
            return Response(ERROR_JSON, status=400, mimetype="application/json")
        return await original(self, input, request)

    process.__name__ = getattr(original, "__name__", "process")
    handler.process = process
    handler._a0flatpak_chat_patched = True


def apply() -> None:
    """Install the guard.  Safe to repeat."""
    # The framework may reload an API module after a plugin purge; patch the
    # new module object through the same hook that guards the other modules.
    plugin_guard.register_module(MODULE, _patch)
    try:
        module = importlib.import_module(MODULE)
    except Exception as exc:
        plugin_guard.log("chat_guard", f"cannot import {MODULE}", exc)
        return
    _patch(module)
