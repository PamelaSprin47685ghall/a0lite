# a0lite

Portable [Agent Zero](https://github.com/agent0ai/agent-zero) as a Flatpak, with
every model-backed feature served by a local Ollama instead of bundled
inference stacks. No VM, no Docker, no Python toolchain on the target machine.

This repository contains only the packaging layer: the manifests, the launcher,
the runtime patches and the build/deploy scripts. The application source is
upstream and is not vendored here.

## What gets removed

The upstream image ships its own inference stack. None of it is in these
bundles; each is replaced by an HTTP call to Ollama:

| Removed | Replaced by |
| --- | --- |
| `torch`, `triton`, `nvidia-*` | `POST /api/chat`, `POST /api/embed` |
| `onnxruntime`, `kokoro`, `misaki`, `spacy` | `POST /v1/audio/speech` |
| `openai-whisper` | `POST /v1/audio/transcriptions` |
| `faiss-cpu`, `sentence-transformers` | `POST /api/embed` plus a numpy index |
| `unstructured[all-docs]` | `unstructured` → `soffice` → `ollama` chain |
| Patchright Chromium download | the host's own Chrome, through `nodriver` |

Python itself is not bundled either: `uv` provisions CPython 3.14 into the
writable data directory on first start. That is what lets Xpra ship as prebuilt
Debian payloads whose C extensions are compiled for 3.14.

## Layout

| Path | What it is |
| --- | --- |
| `flatpak/org.agentzero.AgentZero.yml` | main application |
| `flatpak/org.agentzero.AgentZero.Models.yml` | Ollama runtime, CPU kernels, weights |
| `flatpak/org.agentzero.AgentZero.Cuda.yml` | optional CUDA kernels, branch `12` |
| `flatpak/org.agentzero.AgentZero.Wps.yml` | optional WPS office MCP server |
| `flatpak/agent-zero.sh` | launcher: seeds the writable tree, provisions the venv, starts Ollama and the Web UI |
| `flatpak/a0flatpak/` | runtime patches, applied by the launcher before the app imports, including the request authentication that `A0_AUTH_KEY` enables |
| `flatpak/requirements-flatpak.txt` | upstream requirements with the inference stack removed and two pins raised for CPython 3.14 |
| `flatpak/overrides.txt` | two dependency caps relaxed for CPython 3.14 |
| `flatpak/unpack-deb.sh` | `dpkg-deb` replacement; the SDK has no `dpkg-deb` |
| `flatpak/install-wps-addon.sh` | installs the WPS add-in into the user's WPS profile |
| `flatpak/README.md` | packaging detail: runtime paths, extension points, per-feature notes |
| `docs/setup/host-ollama.md` | host-side Ollama setup, models, endpoint contract |
| `scripts/` | build, package and deploy |
| `systemd/` | system units that keep the app and the desktop running across reboots |

### Runtime patches

`a0flatpak.apply()` runs before the framework imports. Each module is
independent and idempotent:

| Module | Replaces |
| --- | --- |
| `provider_urls` | model provider endpoints with the local Ollama URL |
| `embeddings` | the embedding factory with an Ollama client |
| `vector_store` | faiss with a numpy index |
| `speech` | TTS and STT runtimes with the Ollama audio endpoints |
| `ocr` | the OCR pipeline with a vision request |
| `parsers` | the `unstructured` catch-all with a three-step chain |
| `browser` | Patchright with `stealth-browser` driving the host Chrome |
| `desktop` | the bundled desktop with a host display or Xvfb |
| `packages` | package-manager installs, which cannot run in a read-only sandbox |
| `rfc_loop` | the remote function call loop, which would otherwise poll forever |
| `base_dir` | the framework's write root, redirected into `$XDG_DATA_HOME` |
| `auth` | nothing: it adds the key check the framework does not have |
| `health` | nothing: it adds the `/api/health` route the startup probe polls |

## Not in this repository

| Piece | Where it comes from |
| --- | --- |
| Agent Zero source | `https://github.com/agent0ai/agent-zero`, copied in by `scripts/build.sh` |
| Model weights | pulled with `ollama`; see `docs/setup/host-ollama.md` |
| `wps-office-mcp-deps.tar.gz` | `scripts/build-wps-deps.sh`, from the pinned `lc2panda/wps-skills` archive |
| WPS skills and add-in | the same pinned archive, fetched by the WPS manifest |
| Xpra, Xvfb, Debian libraries | pinned by URL and `sha256` in the main manifest |

Every remote input is pinned by `sha256` or commit. Two things are not:

* the Agent Zero checkout, which the main manifest consumes as `path: ..`;
* `wps-office-mcp-deps.tar.gz`, whose bytes depend on the `bun` version and on
  build timestamps. `scripts/build.sh` compares a copy against the manifest
  pin, rebuilds it when it differs, and re-pins it in the build copy while
  reporting the new checksum. The pin in this repository describes the artifact
  that was actually shipped, not a value any rebuild can reproduce.

## Build

```bash
git clone https://github.com/agent0ai/agent-zero
A0_SRC=$PWD/agent-zero scripts/build.sh
```

Produces `bundles/agent-zero.flatpak`, `agent-zero-cuda.flatpak` and
`agent-zero-wps.flatpak`. The main bundle must be built first: the extensions
fill extension points it declares.

The build needs `flatpak-builder`, the `org.freedesktop.Sdk` 25.08 runtime and
network access for the pinned sources. It needs no C compiler and no Python.

## Models

Weights are never fetched during a build. Stage them with a local Ollama, then
package the tree:

```bash
scripts/package-models.sh /path/to/staged/ollama
```

Produces `models-repo.tar`, an uncompressed ostree repository.

Do not use `flatpak build-bundle` for this. It gzips every object, and GGUF
weights are already compressed, so the pass costs hours and saves nothing:

| Transport | Command | 4.7 GB repository |
| --- | --- | --- |
| Plain tar | `tar -cf models-repo.tar repo` | 3 s |
| OCI, zstd | `build-bundle --oci --oci-layer-compress=zstd` | 70 s |
| Default bundle | `build-bundle` | ~3.7 h |

`--oci-layer-compress` accepts only `gzip` or `zstd`; there is no uncompressed
OCI layer. The repository itself is uncompressed by construction, and
`flatpak install` reads it directly from a `file://` remote or from an
extracted `oci:` directory.

## Deploy

```bash
scripts/deploy.sh user@host
```

Copies the bundles, installs them per user, unpacks the models repository,
registers it as a local remote, starts the application detached and waits for
the UI.

## Running as a service

Two system units start at boot from `graphical.target`. They live in
`/etc/systemd/system` and run as the desktop user, so they are ordinary system
services rather than user units:

| Unit | What it starts |
| --- | --- |
| `agent-zero.service` | the application, which starts Ollama itself |
| `agent-zero-desktop.service` | the Xpra session on the host display |

```bash
sudo scripts/install-services.sh kunweiz
```

`agent-zero.service` waits for the display manager and the network but does not
order itself after `graphical.target`: a unit that is both wanted by a target
and ordered after it creates an ordering cycle, and systemd breaks the cycle by
stopping the unit. `agent-zero-desktop.service` waits for the UI's health
endpoint before it starts Xpra, because the two units start at the same time.

## Verified

Built and run on a Manjaro host with `flatpak` 1.18.4 against
`org.freedesktop.Platform` 25.08, installed on a second machine with no X server
(4 cores, RTX 3070 Ti, tty only):

| Check | Result |
| --- | --- |
| Web UI | HTTP 200 |
| Ollama inside the sandbox | `lfm3-omni:2b-q4_K_M`, `qwen3-embedding:4b-q4_K_M`, `xiaomi-ocr:latest` |
| Embeddings through the framework factory | 2560 dimensions |
| Speech synthesis through the plugin runtime | 84 524-byte RIFF WAV |
| Speech recognition | transcribed back as `Deployment verified.` |
| OCR | `Agent Zero OCR 2026` |
| Desktop | Xpra listening on `127.0.0.1:14500`, HTML5 reachable |
| CUDA extension | `cuda_v12` mounted, `libcublas.so.12` resolvable |
| WPS MCP | `initialize` plus 250 tools |

## License

MIT. Agent Zero itself is MIT; see its repository for the upstream copyright.
