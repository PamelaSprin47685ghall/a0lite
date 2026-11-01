"""Serve speech synthesis and recognition from Ollama.

Two plugin runtimes import local inference stacks:

* ``plugins/_kokoro_tts/helpers/runtime`` imports ``soundfile`` and either the
  kokoro pipeline (torch) or the paradee ONNX model (onnxruntime).
* ``plugins/_whisper_stt/helpers/runtime`` imports ``whisper`` (torch).

The Flatpak build ships neither stack. This module replaces the two functions
the plugins expose to the rest of the framework:

* ``synthesize_sentences`` returns base64 WAV built from
  ``POST /v1/audio/speech``.
* ``transcribe`` returns the dict shape ``/v1/audio/transcriptions`` produces.

Both replacements keep the original signatures and the original config keys,
so plugin APIs, hooks and WebUI code stay untouched.
"""

from __future__ import annotations

import asyncio
import base64
import os
from typing import Any

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
SPEECH_MODEL = os.environ.get("A0_SPEECH_MODEL", "lfm3-omni:2b-q4_K_M")
SPEECH_VOICE = os.environ.get("A0_SPEECH_VOICE", "female")
SPEECH_TIMEOUT = float(os.environ.get("A0_SPEECH_TIMEOUT", "180"))


def _speech_request(text: str) -> bytes:
    import httpx

    response = httpx.post(
        f"{OLLAMA_URL}/v1/audio/speech",
        json={"model": SPEECH_MODEL, "input": text, "voice": SPEECH_VOICE},
        timeout=SPEECH_TIMEOUT,
    )
    response.raise_for_status()
    return response.content


def _transcription_request(audio_bytes: bytes, language: str | None) -> dict[str, Any]:
    import httpx

    data: dict[str, Any] = {"model": SPEECH_MODEL, "response_format": "verbose_json"}
    if language:
        data["language"] = language
    response = httpx.post(
        f"{OLLAMA_URL}/v1/audio/transcriptions",
        data=data,
        files={"file": ("audio.wav", audio_bytes, "audio/wav")},
        timeout=SPEECH_TIMEOUT,
    )
    response.raise_for_status()
    payload = response.json()
    if not isinstance(payload, dict):
        return {"text": str(payload)}
    payload.setdefault("text", "")
    payload.setdefault("segments", [])
    payload.setdefault("language", language or "")
    return payload


def _patch_tts() -> None:
    from plugins._kokoro_tts.helpers import runtime as tts_runtime

    if getattr(tts_runtime, "_a0flatpak_patched", False):
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

    def is_updating(config: dict[str, Any] | None = None) -> bool:
        return False

    tts_runtime.synthesize_sentences = synthesize_sentences
    tts_runtime.is_downloaded = is_downloaded
    tts_runtime.is_updating = is_updating
    tts_runtime._a0flatpak_patched = True


def _patch_stt() -> None:
    from plugins._whisper_stt.helpers import runtime as stt_runtime

    if getattr(stt_runtime, "_a0flatpak_patched", False):
        return

    async def _transcribe(
        model_name: str, audio_bytes_b64: str, *, language: str | None = None
    ) -> dict[str, Any]:
        audio_bytes = base64.b64decode(audio_bytes_b64)
        return await asyncio.to_thread(_transcription_request, audio_bytes, language)

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

    try:
        _patch_tts()
    except ImportError:
        pass

    try:
        _patch_stt()
    except ImportError:
        pass
