# a0lite

Portable [Agent Zero](https://github.com/agent0ai/agent-zero) as a Flatpak, with
embeddings, speech and OCR served by a local Ollama instead of bundled
inference stacks, and chat through any OpenAI-compatible endpoint. No VM, no
Docker, no Python toolchain on the target machine.

This repository contains only the packaging layer: the manifests, the launcher,
the runtime patches and the build/deploy scripts. The application source is
upstream and is not vendored here.

## What gets removed

The upstream image ships its own inference stack. None of it is in these
bundles; each is replaced by an HTTP model call:

| Removed | Replaced by |
| --- | --- |
| `torch`, `triton`, `nvidia-*` | an OpenAI-compatible chat API, `POST /api/embed` |
| `onnxruntime`, `kokoro`, `misaki`, `spacy` | `POST /v1/audio/speech` |
| `openai-whisper` | `POST /v1/audio/transcriptions` |
| `faiss-cpu`, `sentence-transformers` | `POST /api/embed` plus a numpy index |
| `unstructured[all-docs]` | `unstructured` → `soffice` → `ollama` chain |
| Patchright Chromium download | the host's own Chrome, driven by Patchright |

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
| `browser` | Patchright driving the host Chrome |
| `desktop` | the bundled desktop with a host display or Xvfb |
| `packages` | package-manager installs, which cannot run in a read-only sandbox |
| `rfc_loop` | the remote function call loop, which would otherwise poll forever |
| `base_dir` | the framework's write root, redirected into `$XDG_DATA_HOME` |
| `compat` | nothing: it keeps `asyncio` and `sniffio` usable under the framework's nested event loop |
| `auth` | nothing: it adds the key check the framework does not have |
| `serve` | nothing: it wraps the callable uvicorn is given, which is where the key check is attached |

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

## Security boundaries

The sandbox is built to work on the real machine, so its boundary is the local
user account, not the Flatpak sandbox. Measured on 2026-11-18; the full probe
log is `docs/manual-acceptance/a0lite-deploy/security-audit.md`.

- **Loopback only.** `ss -tlnp` shows `127.0.0.1:5080` and nothing else.
  `nc 192.168.123.80 5080` returns Connection refused and `curl` returns 000,
  so the UI is unreachable from the LAN. The sandbox itself shares the host
  network (`curl 192.168.123.80` returns 404), so it can reach the LAN even
  though the LAN cannot reach the UI.
- **No authentication by default.** `A0_AUTH_KEY` is empty and the auth
  middleware is not installed. Any local process can request
  `GET /api/csrf_token` with `Origin: http://127.0.0.1:5080`, then call
  `POST /api/message` with the returned token. CSRF stops a cross-site browser,
  not a local process or a non-browser client.
- **Host command execution.** `--talk-name=org.freedesktop.Flatpak` makes
  `flatpak-spawn --host id` succeed inside the sandbox (host uid 1000, groups
  include `wheel`). The WPS MCP server needs this, and it is equivalent to
  arbitrary command execution on the host.
- **Home access, current bundle (`d7749980`).** `--filesystem=host` still gives
  read-write access to the real home, and `?path=/etc/passwd` returns 200. The
  manifest also adds eight `--nofilesystem` entries for `~/.ssh`, `~/.gnupg`,
  `~/.pki`, `~/.local/share/keyrings`, `~/.config/gh`, `~/.aws`, `~/.docker`
  and `~/.kube`; the file API returns `403 SENSITIVE_PATH_BLOCKED` for them.
  `flatpak info --show-permissions` does not print negative permissions, so
  read the installed `metadata` to see the eight entries, and run
  `scripts/verify-security-fix.sh --expect new` (12/12) to check both.
- **Do not expose it.** Even with `A0_AUTH_KEY` set, `--talk-name` plus
  `--filesystem=host` make this a single-user local tool. Do not bind it to
  `0.0.0.0` or put it behind a reverse proxy.

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

### Version strings

Three kinds of identifier are easy to confuse:

- The footer `Version 058582f-dirty 2026-11-02T18:56:58Z` is the source state.
  `scripts/build.sh` writes four keys into `.a0-build-info`:
  `A0_BUILD_VERSION` (short HEAD hash plus `-dirty` when the worktree is
  uncommitted), `A0_BUILD_COMMIT`, `A0_COMMIT_TIME` (the HEAD commit's authored
  time, from `git -C "$HERE" log -1 --format=%cd`) and `A0_BUILD_TIME` (the
  moment the bundle was built). The launcher exports all four, and the footer
  shows `<hash> <commit_time>`.
- Up to v16 the second field was the build clock mislabelled as `commit_time`.
  v16's snapshot shows `2026-11-17T21:50:08Z` for unchanged source `058582f`;
  v17 replaced it with the real commit time and added the separate
  `build_time` key. That is a metadata fix, not a code change.
- `flatpak --user info org.agentzero.AgentZero` prints
  `Commit: d77499804c13…`, the ostree commit of the installed bundle. It is
  generated at build time and is not a source hash.
- `/api/health` reports the source state: `gitinfo.commit_hash` is
  `058582f`, `gitinfo.commit_time` is `2026-11-02T18:56:58Z`, and
  `gitinfo.build_time` is `2026-11-18T01:52:13Z`.

Do not compare the footer or `gitinfo.commit_hash` with the package `Commit`;
they identify different objects.

### AMD GPUs (Vulkan)

Ollama ships a Vulkan backend (`libggml-vulkan.so`), but it drops integrated
GPUs by default:

```
dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1
```

`flatpak/agent-zero.sh` therefore sets `OLLAMA_IGPU_ENABLE=1` and
`GGML_VK_VISIBLE_DEVICES=0` before starting Ollama. On a Radeon 780M this
moved `size_vram` from 0 to 1.82 GiB (chat) and 7.25 GiB (embedding), and
raised generation from 32.27 to 58.36 tps (1.81×, median of three runs).
`A0_OLLAMA_IGPU=0` restores CPU-only behaviour. Discrete AMD GPUs use the same
path; NVIDIA still needs the Cuda extension.

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
the UI. A reinstall replaces the application deployment but leaves the data
under `~/.var/app/org.agentzero.AgentZero` in place: `flatpak install --user
--reinstall` does not delete it.

## Running as a service

Two system units start at boot. They live in `/etc/systemd/system` and run as
the desktop user, so they are ordinary system services rather than user units:

| Unit | What it starts |
| --- | --- |
| `agent-zero.service` | the application, which starts Ollama itself |
| `agent-zero-desktop.service` | the Xpra session on the host display |

`agent-zero.service` is wanted by `multi-user.target` and needs no display.
`agent-zero-desktop.service` is wanted by both `multi-user.target` and
`graphical.target`: it starts on a tty-only host too, waits briefly for the X
socket named by `DISPLAY`, and falls back to the bundled Xvfb when there is
none.

```bash
sudo scripts/install-services.sh kunweiz
```

The units contain no user names, UIDs or home paths. The installer writes
`<unit>.service.d/10-user.conf` with `User=`, `Group=`, the runtime directory
and the `user@<uid>.service` dependency, refuses root and unknown users, and
enables lingering so `/run/user/<uid>` and the session bus exist after a boot
with no login. The units assert that their drop-in exists, so a half-installed
copy fails closed instead of running as root.

`agent-zero-desktop.service` waits for the UI's health endpoint before it
starts Xpra and allows 300 s for a cold first start. It is a launcher, not a
supervisor: `is-active` means the launcher succeeded, not that Xpra is still
alive later.

Set `A0_STAGE_ROOT=/tmp/stage` to render the units under that root without
touching `/etc` or systemd.

## Verified

The application was built on a Manjaro host with `flatpak` 1.18.4 against
`org.freedesktop.Platform` 25.08 and first verified on a second machine with no
X server (4 cores, RTX 3070 Ti, tty only). The results below were re-measured
on a Manjaro host (16-core Ryzen 9 7940H, AMD 780M iGPU, no NVIDIA GPU) with
`org.agentzero.AgentZero` commit `ab3d8e61` (v14). The current baseline is v22
`d7749980` (`master`, built 2026-11-18 01:52:13Z); v15–v22 changed the packaging
layer, the sandbox permissions and the runtime patches, and their verification
is recorded in `docs/manual-acceptance/a0lite-deploy/` (`v15-v16-fix-run.md`,
`v19-fix-plan.md`, `v21-fix-run.md`, `v22-vulkan-fix.md`, `report.md`). The
rows below are the v14 measurements. The NVIDIA GPU rows were not re-tested
because that machine was decommissioned after a kernel change; the AMD Radeon
780M iGPU now uses Vulkan (see above). The desktop rows are shadow sessions on
the host X server, not a headless Xvfb session.

| Check | Result |
| --- | --- |
| Web UI | `/api/health` returns 200 on `127.0.0.1:5080`; `verify-ui-fix.sh` passes 6/6 |
| Ollama inside the sandbox | `lfm3-omni:2b-q4_K_M`, `qwen3-embedding:4b-q4_K_M` and `xiaomi-ocr:latest` all answer |
| Embeddings through the framework factory | 2560 dimensions |
| Speech synthesis through the plugin runtime | RIFF/WAVE, `pcm_s16le`, 24 kHz, mono, 3.68 s; `_repair_wav` in `a0flatpak/speech.py` fills in the header sizes Ollama leaves as `0xFFFFFFFF` |
| Speech recognition | similarity 0.9091; `language` misreports `english`, the transcribed text is usable |
| OCR | two Chinese lines read correctly in 3.5-6.3 s; incomplete pages return `> OCR incomplete: ...` |
| Desktop | `127.0.0.1:14500` returns 200 and the HTML5 client completes `Handshake complete` with `canvases=1`, showing the session windows; no XFCE wallpaper, panels or desktop icons appear |
| CUDA extension | *not re-checked*: this host has no NVIDIA GPU, and the target machine went unreachable after a kernel change |
| WPS MCP | `initialize` plus 250 tools inside the sandbox; document tools fail when the host has no WPS Office |

## Known limitations

- `/api/health` reports `gitinfo` from `.a0-build-info` and `error: null` on a
  current build. An older bundle returns `{"gitinfo": null, "error": "<data dir>"}`;
  that `error` text is the git probe's `InvalidGitRepositoryError`, not a
  service failure.
- A Chrome profile that cached an older Web UI keeps serving it from its
  Service Worker after an upgrade. Hard-reload the page, or use a fresh
  profile, when the UI still shows the previous build.
- `~/.var/app/org.agentzero.AgentZero/data/agent-zero/tmp/playwright/chromium-1228`
  is a 379 MB fallback browser that Patchright downloaded. The host Chrome is
  used when present, so the directory can be deleted.

## License

MIT. Agent Zero itself is MIT; see its repository for the upstream copyright.
