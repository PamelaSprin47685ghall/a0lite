# Host Ollama Backend (Flatpak / Bare-Metal Deployment)

Agent Zero runs without Docker when its model backends live on the host.
This document describes the host-side Ollama layout used by the Flatpak
build. Nothing here runs inside the bundle: the bundle only talks HTTP.

## Model set

All three models use Q4_K_M quantization and fit an 8 GB GPU together.

| Role | Model tag | Size | Notes |
| --- | --- | --- | --- |
| Document parsing / OCR | `xiaomi-ocr` (local Modelfile) | 0.74 GB | Whole-page Markdown, no layout SDK |
| Speech (TTS + ASR) | `lfm3-omni:2b-q4_K_M` | 2.00 GB | Audio in, 24 kHz speech out |
| Memory embedding | `qwen3-embedding:4b-q4_K_M` | 2.50 GB | 2560-dim, MTEB multilingual 69.45 |

Total resident weights: 5.24 GB.

## Pull the registry models

```bash
ollama pull lfm3-omni:2b-q4_K_M
ollama pull qwen3-embedding:4b-q4_K_M
```

`qwen3-embedding:4b` and `qwen3-embedding:4b-q4_K_M` resolve to the same
manifest, so either tag works.

## Build the OCR model locally

The Xiaomi OCR weights are community GGUF conversions. Download the Q4_K_M
model and the BF16 vision projector, then register them:

```bash
mkdir -p ~/.local/share/a0-models/xiaomi-ocr
cd ~/.local/share/a0-models/xiaomi-ocr

curl -fL -O https://huggingface.co/prithivMLmods/Xiaomi-OCR-0-GGUF/resolve/main/Xiaomi-OCR-0.Q4_K_M.gguf
curl -fL -O https://huggingface.co/prithivMLmods/Xiaomi-OCR-0-GGUF/resolve/main/Xiaomi-OCR-0.mmproj-bf16.gguf

cat > Modelfile <<'EOF'
FROM ./Xiaomi-OCR-0.Q4_K_M.gguf
FROM ./Xiaomi-OCR-0.mmproj-bf16.gguf
PARAMETER num_ctx 8192
PARAMETER temperature 0
EOF

ollama create xiaomi-ocr -f Modelfile
```

## Server settings

```bash
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_MAX_LOADED_MODELS=2
export OLLAMA_NUM_PARALLEL=2
ollama serve
```

`OLLAMA_MAX_LOADED_MODELS=2` keeps two models resident so that switching
between OCR and speech does not reload weights on every request. Raise it to
3 when the GPU has more than 8 GB.

## Endpoints used by Agent Zero

| Agent Zero feature | Endpoint | Model |
| --- | --- | --- |
| Memory and document retrieval | `POST /api/embed` | `qwen3-embedding:4b-q4_K_M` |
| Speech synthesis | `POST /v1/audio/speech` | `lfm3-omni:2b-q4_K_M` |
| Speech recognition | `POST /v1/audio/transcriptions` | `lfm3-omni:2b-q4_K_M` |
| Document parsing / OCR | `POST /api/chat` | `xiaomi-ocr` |

## OCR prompts

Xiaomi-OCR-0 expects a task prompt, not a bare image:

| Task | Prompt |
| --- | --- |
| Whole page | `Extract all information from the main body of the document image and represent it in markdown format, ignoring headers and footers. Tables should be expressed in OTSL format, formulas in LaTeX.` |
| Text region | `Extract the text in the image.` |
| Table region | `Parse the table in the image into OTSL.` |
| Formula region | `Identify the formula in the image and represent it using LATEX format.` |
| Key information | `Extract key information in the image`, followed by a JSON schema |

The whole-page prompt needs no layout detection step.

## Unverified behaviour

These items are untested and must be checked before relying on them.

1. **Audio capability of the Ollama package.** The `lfm3-omni` tag page lists
   `Text, Image input` and does not list audio input. Verify both directions:

   ```bash
   curl -sS http://127.0.0.1:11434/v1/audio/speech \
     -H 'Content-Type: application/json' \
     -d '{"model":"lfm3-omni:2b-q4_K_M","input":"你好","voice":"default"}' \
     -o /tmp/tts.wav

   curl -sS http://127.0.0.1:11434/v1/audio/transcriptions \
     -F model=lfm3-omni:2b-q4_K_M -F file=@/tmp/tts.wav
   ```

   If either call fails, serve the same GGUF with `llama serve` from
   llama.cpp, which documents `/v1/realtime` and `/tts`.

2. **Accuracy of the Q4_K_M OCR conversion.** The Xiaomi model card states
   that community GGUF conversions were not evaluated and that the published
   benchmark scores do not carry over. Compare Q4_K_M against BF16 on a
   Chinese document before depending on it.

3. **Chinese speech quality of `lfm3-omni`.** Chinese appears in the model's
   speech language list, but no quality reference exists. Listen to a sample
   before enabling TTS.

4. **Peak GPU memory with three models resident.** 5.24 GB of weights plus
   KV cache and runtime buffers may exceed 8 GB. If Ollama evicts models on
   every request, lower `OLLAMA_MAX_LOADED_MODELS` to 1.

## Connecting the bundle

The Flatpak bundle reaches the host server through `--share=network` and
`OLLAMA_HOST`:

```bash
flatpak run --env=OLLAMA_HOST=http://127.0.0.1:11434 org.agentzero.AgentZero
```
