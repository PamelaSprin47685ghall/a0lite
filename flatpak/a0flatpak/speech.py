"""Serve speech synthesis and recognition from Ollama.

Two plugin runtimes import local inference stacks:

* ``plugins/_kokoro_tts/helpers/runtime`` imports ``soundfile`` and either the
  kokoro pipeline (torch) or the paradee ONNX model (onnxruntime).
* ``plugins/_whisper_stt/helpers/runtime`` imports ``whisper`` (torch).

The Flatpak build ships neither stack. This module replaces the two functions
the plugins expose to the rest of the framework:

* ``synthesize_sentences`` returns base64 audio built from
  ``POST /v1/audio/speech``.
* ``transcribe`` returns the dict shape ``/v1/audio/transcriptions`` produces.

Both replacements keep the original signatures and the original config keys,
so plugin APIs, hooks and WebUI code stay untouched.
"""

from __future__ import annotations

import asyncio
import base64
import contextvars
import importlib
import json
import os
import struct
import sys
from typing import Any

from a0flatpak import plugin_guard

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
SPEECH_MODEL = os.environ.get("A0_SPEECH_MODEL", "lfm3-omni:2b-q4_K_M")
SPEECH_VOICE = os.environ.get("A0_SPEECH_VOICE", "female")
SPEECH_TIMEOUT = float(os.environ.get("A0_SPEECH_TIMEOUT", "180"))
# httpx timeouts are per-read, not total: a streaming generator keeps the read
# alive, so a long input can run for minutes without ever tripping the timeout.
# A length cap is the only bound that holds, and it refuses rather than
# truncating, because silently dropping the tail of a sentence produces audio
# that sounds right and says the wrong thing.
SPEECH_MAX_CHARS = int(os.environ.get("A0_SPEECH_MAX_CHARS", "1200"))


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


# A muted microphone still sends a valid WAV full of zeros. Whisper answers
# that with an invented phrase instead of an empty string, so the caller
# cannot tell "nobody spoke" from "the model heard something". The gate
# refuses clips below these levels before they reach the model. The default
# sits between a quiet room (about 0.003) and normal speech (about 0.08) and
# leaves an order of magnitude of headroom on the speech side.
STT_MIN_RMS = _env_float("A0_STT_MIN_RMS", 0.005)
STT_MIN_DURATION = _env_float("A0_STT_MIN_DURATION", 0.3)

_STT_GATE_RESULT: contextvars.ContextVar[dict[str, Any] | None] = (
    contextvars.ContextVar("a0flatpak_stt_gate", default=None)
)

class SpeechInputTooLong(ValueError):
    """The text exceeds A0_SPEECH_MAX_CHARS."""


def _repair_wav(data: bytes) -> bytes:
    """Fill in the RIFF and data chunk sizes of a streamed WAV.

    Ollama writes the header before it knows how long the audio is, so it puts
    ``0xFFFFFFFF`` in both size fields. ``wave`` trusts them and reports
    2147483647 frames (about 24 hours at 24 kHz), which makes any duration
    assertion meaningless and makes strict players refuse the file.

    Only the two sizes are rewritten; the payload is never touched. Anything
    that is not RIFF/WAVE is returned unchanged, because this function cannot
    know what format it is looking at.
    """
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return data

    buf = bytearray(data)
    struct.pack_into("<I", buf, 4, len(buf) - 8)

    offset = 12
    while offset + 8 <= len(buf):
        chunk_id = bytes(buf[offset : offset + 4])
        size = struct.unpack_from("<I", buf, offset + 4)[0]
        payload = offset + 8
        if size == 0xFFFFFFFF:
            if chunk_id == b"data":
                struct.pack_into("<I", buf, offset + 4, len(buf) - payload)
            # A container chunk with an unknown size hides everything after it,
            # so the walk stops here with the RIFF size already corrected.
            break
        if payload + size > len(buf):
            if chunk_id == b"data":
                struct.pack_into("<I", buf, offset + 4, len(buf) - payload)
            break
        if chunk_id == b"data":
            struct.pack_into("<I", buf, offset + 4, len(buf) - payload)
            break
        offset = payload + size + (size & 1)  # odd-sized chunks are padded
    return bytes(buf)


def _wav_ok(data: bytes) -> bool:
    """Report whether the stdlib parser accepts the repaired bytes."""
    import io
    import wave

    try:
        with wave.open(io.BytesIO(data), "rb") as handle:
            handle.getnframes()
        return True
    except Exception:
        return False


_FMT_PCM = 1
_FMT_FLOAT = 3
_FMT_EXTENSIBLE = 0xFFFE


def _scaled_samples(payload: bytes, tag: int, width: int):
    """Yield every sample normalised to [-1, 1], one channel at a time."""
    if tag == _FMT_FLOAT:
        code = "f" if width == 4 else "d"
        for (value,) in struct.iter_unpack(f"<{code}", payload):
            yield value
    elif width == 1:
        for byte in payload:
            yield (byte - 128) / 128.0
    elif width == 2:
        for (value,) in struct.iter_unpack("<h", payload):
            yield value / 32768.0
    elif width == 3:
        for offset in range(0, len(payload), 3):
            value = (
                payload[offset]
                | payload[offset + 1] << 8
                | payload[offset + 2] << 16
            )
            if value & 0x800000:
                value -= 0x1000000
            yield value / 8388608.0
    else:
        for (value,) in struct.iter_unpack("<i", payload):
            yield value / 2147483648.0


def _wav_levels(data: bytes) -> tuple[float, float, float] | None:
    """Return ``(rms, peak, duration_s)`` for a PCM or float WAV.

    ``None`` means the bytes are not a WAV this reader understands. The
    caller then lets the clip through, because the gate must not guess about
    formats it cannot measure.
    """
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return None

    fmt = None
    payload = None
    offset = 12
    while offset + 8 <= len(data):
        chunk = data[offset : offset + 4]
        size = struct.unpack_from("<I", data, offset + 4)[0]
        start = offset + 8
        if chunk == b"fmt ":
            fmt = data[start : start + size]
        elif chunk == b"data":
            end = len(data) if size == 0xFFFFFFFF else min(len(data), start + size)
            payload = data[start:end]
            break
        if size == 0xFFFFFFFF:
            return None
        offset = start + size + (size & 1)

    if fmt is None or payload is None or len(fmt) < 16:
        return None
    tag, channels, rate, _, _, bits = struct.unpack_from("<HHIIHH", fmt)
    if tag == _FMT_EXTENSIBLE:
        if len(fmt) < 40:
            return None
        tag = struct.unpack_from("<H", fmt, 24)[0]
    width = bits // 8
    if channels < 1 or rate < 1:
        return None
    if tag == _FMT_FLOAT:
        if width not in (4, 8):
            return None
    elif tag == _FMT_PCM:
        if width not in (1, 2, 3, 4):
            return None
    else:
        return None

    block = width * channels
    frames = len(payload) // block
    if frames < 1:
        return None
    payload = payload[: frames * block]

    total = 0.0
    peak = 0.0
    for value in _scaled_samples(payload, tag, width):
        total += value * value
        magnitude = abs(value)
        if magnitude > peak:
            peak = magnitude
    return (total / (frames * channels)) ** 0.5, peak, frames / rate


def _describe(prefix: str, url: str, exc: BaseException | None = None,
              response: Any = None) -> str:
    """Build one line that names the model, the status and the body."""
    if response is not None:
        body = (response.text or "").strip().replace("\n", " ")[:200]
        return (
            f"{prefix}: model={SPEECH_MODEL} "
            f"status={response.status_code} body={body!r}"
        )
    return (
        f"{prefix}: model={SPEECH_MODEL} url={url} "
        f"error={type(exc).__name__}: {exc}"
    )


def _speech_request(text: str) -> bytes:
    import httpx

    if len(text) > SPEECH_MAX_CHARS:
        raise SpeechInputTooLong(
            f"speech input is {len(text)} characters, the limit is "
            f"{SPEECH_MAX_CHARS} (A0_SPEECH_MAX_CHARS); split the text into "
            "segments and synthesize each one"
        )

    url = f"{OLLAMA_URL}/v1/audio/speech"
    try:
        response = httpx.post(
            url,
            json={
                "model": SPEECH_MODEL,
                "input": text,
                "voice": SPEECH_VOICE,
                "response_format": "wav",
            },
            timeout=SPEECH_TIMEOUT,
        )
    except Exception as exc:
        raise RuntimeError(_describe("Ollama speech failed", url, exc=exc)) from exc
    if response.status_code >= 400:
        raise RuntimeError(_describe("Ollama speech failed", url, response=response))

    audio = _repair_wav(response.content)
    if not _wav_ok(audio):
        # The audio is more useful than the error: hand it back and say the
        # header could not be trusted.
        print(
            "a0flatpak: repaired WAV still does not parse; returning the bytes "
            f"as received ({len(audio)} bytes)",
            file=sys.stderr,
        )
    return audio


def _transcription_request(audio_bytes: bytes, language: str | None) -> dict[str, Any]:
    import httpx

    data: dict[str, Any] = {"model": SPEECH_MODEL, "response_format": "verbose_json"}
    if language:
        data["language"] = language
    url = f"{OLLAMA_URL}/v1/audio/transcriptions"
    try:
        response = httpx.post(
            url,
            data=data,
            files={"file": ("audio.wav", audio_bytes, "audio/wav")},
            timeout=SPEECH_TIMEOUT,
        )
    except Exception as exc:
        raise RuntimeError(
            _describe("Ollama transcription failed", url, exc=exc)
        ) from exc
    if response.status_code >= 400:
        raise RuntimeError(
            _describe("Ollama transcription failed", url, response=response)
        )
    payload = response.json()
    if not isinstance(payload, dict):
        return {"text": str(payload)}
    payload.setdefault("text", "")
    payload.setdefault("segments", [])
    payload.setdefault("language", language or "")
    return payload


def _stt_gate(audio_bytes: bytes) -> dict[str, Any] | None:
    """Refuse clips that carry no speech before they reach the model.

    Duration is checked first: a clip shorter than the minimum is not worth
    transcribing even when it is loud, and the 0.2 s fragments that reach the
    endpoint usually sit in the silent lead-in and would otherwise be
    reported as silence.
    """
    levels = _wav_levels(audio_bytes)
    if levels is None:
        return None
    rms, peak, duration = levels
    seconds = round(duration, 3)
    if duration < STT_MIN_DURATION:
        plugin_guard.log(
            "speech.stt",
            f"too_short: duration={seconds}s rms={rms:.6f} peak={peak:.6f} "
            f"min_duration={STT_MIN_DURATION}s",
        )
        return {"success": True, "text": "", "too_short": True, "duration_s": seconds}
    if rms < STT_MIN_RMS:
        plugin_guard.log(
            "speech.stt",
            f"silence: rms={rms:.6f} peak={peak:.6f} duration={seconds}s "
            f"min_rms={STT_MIN_RMS}",
        )
        return {"success": True, "text": "", "silence": True, "duration_s": seconds}
    return None


def _transcribe_blocking(
    audio_bytes_b64: str, language: str | None
) -> dict[str, Any]:
    audio_bytes = base64.b64decode(audio_bytes_b64)
    gate = _stt_gate(audio_bytes)
    if gate is not None:
        return gate
    return _transcription_request(audio_bytes, language)


def _patch_tts_module(tts_runtime) -> None:
    if (
        getattr(tts_runtime, "_a0flatpak_patched", False)
        and getattr(tts_runtime.synthesize_sentences, "__module__", "") == __name__
    ):
        return

    async def synthesize_sentences(
        sentences: list[str], config: dict[str, Any] | None = None
    ) -> str:
        text = "\n".join(sentence.strip() for sentence in sentences if sentence.strip())
        if not text:
            return ""
        audio = await asyncio.to_thread(_speech_request, text)
        return base64.b64encode(audio).decode("utf-8")

    async def is_downloaded(config: dict[str, Any] | None = None) -> bool:
        return True

    tts_runtime.synthesize_sentences = synthesize_sentences
    tts_runtime.is_downloaded = is_downloaded
    tts_runtime._a0flatpak_patched = True


def _patch_stt_module(stt_runtime) -> None:
    if (
        getattr(stt_runtime, "_a0flatpak_patched", False)
        and getattr(stt_runtime.transcribe, "__module__", "") == __name__
    ):
        return

    async def _transcribe(
        model_name: str, audio_bytes_b64: str, *, language: str | None = None
    ) -> dict[str, Any]:
        result = await asyncio.to_thread(
            _transcribe_blocking, audio_bytes_b64, language
        )
        _STT_GATE_RESULT.set(
            result
            if isinstance(result, dict)
            and (result.get("silence") or result.get("too_short"))
            else None
        )
        return result

    async def transcribe(
        audio_bytes_b64: str, config: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        cfg = stt_runtime.normalize_config(config or stt_runtime.get_config())
        return await _transcribe(
            str(cfg["model_size"]),
            audio_bytes_b64,
            language=stt_runtime._resolve_language(str(cfg["language"])),
        )

    async def preload(model_name: str | None = None) -> bool:
        return True

    async def is_downloaded(config: dict[str, Any] | None = None) -> bool:
        return True

    stt_runtime._transcribe = _transcribe
    stt_runtime.transcribe = transcribe
    stt_runtime.preload = preload
    stt_runtime.is_downloaded = is_downloaded
    stt_runtime._a0flatpak_patched = True


def _error_response(status: int, code: str, message: str):
    from helpers.api import Response

    return Response(
        json.dumps(
            {"success": False, "ok": False, "error": code, "message": message}
        ),
        status=status,
        mimetype="application/json",
    )


def _wrap_handler_class(handler) -> None:
    if getattr(handler, "_a0flatpak_speech_patched", False):
        return
    original = handler.process

    async def process(self, input, request):
        ensure()
        text = str((input or {}).get("text") or "")
        if len(text) > SPEECH_MAX_CHARS:
            return _error_response(
                413,
                "SPEECH_INPUT_TOO_LONG",
                f"speech input is {len(text)} characters, the limit is "
                f"{SPEECH_MAX_CHARS} (A0_SPEECH_MAX_CHARS); split the text "
                "into segments and synthesize each one",
            )
        return await original(self, input, request)

    handler.process = process
    handler._a0flatpak_speech_patched = True


def _patch_tts_handler_module(module) -> None:
    handler = getattr(module, "Synthesize", None)
    if isinstance(handler, type):
        _wrap_handler_class(handler)


def _wrap_stt_handler_class(handler) -> None:
    """Keep the gate's explanation on the response.

    The upstream handler builds its reply from ``text`` and ``language``
    alone, so ``silence`` and ``too_short`` would disappear and leave the
    caller with an empty string and no reason. The gate recorded its result
    for this request; copy those keys onto the reply.
    """
    if getattr(handler, "_a0flatpak_stt_patched", False):
        return
    original = handler.process

    async def process(self, input, request):
        ensure()
        _STT_GATE_RESULT.set(None)
        reply = await original(self, input, request)
        gate = _STT_GATE_RESULT.get()
        if isinstance(reply, dict) and gate:
            for key in ("silence", "too_short", "duration_s"):
                if key in gate:
                    reply[key] = gate[key]
        return reply

    handler.process = process
    handler._a0flatpak_stt_patched = True


def _patch_stt_handler_module(module) -> None:
    handler = getattr(module, "Transcribe", None)
    if isinstance(handler, type):
        _wrap_handler_class(handler)
        _wrap_stt_handler_class(handler)


def apply_kokoro() -> None:
    runtimes = plugin_guard.live_modules("_kokoro_tts.helpers.runtime")
    if not runtimes:
        from plugins._kokoro_tts.helpers import runtime as fallback
        runtimes = [fallback]
    for runtime in runtimes:
        _patch_tts_module(runtime)
    handlers = plugin_guard.live_modules("_kokoro_tts.api.synthesize")
    if not handlers:
        from plugins._kokoro_tts.api import synthesize as fallback
        handlers = [fallback]
    for module in handlers:
        _patch_tts_handler_module(module)


def apply_whisper() -> None:
    runtimes = plugin_guard.live_modules("_whisper_stt.helpers.runtime")
    if not runtimes:
        from plugins._whisper_stt.helpers import runtime as fallback
        runtimes = [fallback]
    for runtime in runtimes:
        _patch_stt_module(runtime)
    handlers = plugin_guard.live_modules("_whisper_stt.api.transcribe")
    if not handlers:
        from plugins._whisper_stt.api import transcribe as fallback
        handlers = [fallback]
    for module in handlers:
        _patch_stt_handler_module(module)


def ensure() -> None:
    """Re-apply both patches through the shared plugin guard."""
    plugin_guard.ensure("_kokoro_tts")
    plugin_guard.ensure("_whisper_stt")


def _neutralise_module(name: str) -> None:
    """Drop an unavailable local-inference module from the import cache.

    The plugin modules import ``whisper`` and ``soundfile`` at module scope.
    Registering empty stand-ins keeps those imports cheap; the patched
    functions never touch the stand-ins.
    """
    import sys
    import types

    if name in sys.modules:
        return
    try:
        __import__(name)
    except Exception:
        sys.modules[name] = types.ModuleType(name)


def apply() -> None:
    """Install the speech replacements after the plugin runtimes import."""
    _neutralise_module("whisper")
    _neutralise_module("soundfile")
    _neutralise_module("kokoro")

    plugin_guard.register("_kokoro_tts", apply_kokoro)
    plugin_guard.register("_whisper_stt", apply_whisper)
    plugin_guard.register_module("_kokoro_tts.helpers.runtime", _patch_tts_module)
    plugin_guard.register_module("_whisper_stt.helpers.runtime", _patch_stt_module)
    plugin_guard.register_module("_kokoro_tts.api.synthesize", _patch_tts_handler_module)
    plugin_guard.register_module("_whisper_stt.api.transcribe", _patch_stt_handler_module)
    plugin_guard.ensure()
