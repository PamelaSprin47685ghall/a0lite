# Flatpak packaging

Four bundles, built from this directory. Only the main bundle is required.

| Bundle | ID | Contents | Required |
| --- | --- | --- | --- |
| Main | `org.agentzero.AgentZero` | Python 3.14, uv, Xpra, Agent Zero, runtime adaptations | yes |
| Models | `org.agentzero.AgentZero.Models` | Ollama server, CPU kernels, model weights | no |
| Cuda | `org.agentzero.AgentZero.Cuda` | CUDA kernels for Ollama | no |
| WPS | `org.agentzero.AgentZero.Wps` | MCP server and skills for WPS Office | no |

## What each combination gives you

| Installed | Chat | OCR | Speech | Embeddings | Desktop | Browser |
| --- | --- | --- | --- | --- | --- | --- |
| Main | — | — | — | — | host | host Chrome |
| Main + Models | yes | yes | yes | yes | host | host Chrome |
| Main + Models + Cuda | GPU-accelerated | GPU-accelerated | GPU-accelerated | GPU-accelerated | host | host Chrome |
| Main + WPS | WPS tools, needs a chat model | — | — | — | host | host Chrome |

The main bundle starts and serves the Web UI with no model backend. Model
calls report that no backend is present until the Models extension is
installed.

## Build

The main bundle must be built and installed first: the extensions fill points
it declares.

```bash
flatpak-builder --user --install --force-clean state/main  flatpak/org.agentzero.AgentZero.yml
flatpak-builder --user --install --force-clean state/cuda  flatpak/org.agentzero.AgentZero.Cuda.yml
flatpak-builder --user --install --force-clean state/wps   flatpak/org.agentzero.AgentZero.Wps.yml
```

Export the bundles:

```bash
flatpak build-bundle ~/.local/share/flatpak/repo agent-zero.flatpak org.agentzero.AgentZero master
flatpak build-bundle --runtime state/cache agent-zero-cuda.flatpak org.agentzero.AgentZero.Cuda 12
flatpak build-bundle state/cache agent-zero-wps.flatpak org.agentzero.AgentZero.Wps 1.0
```

### Models bundle

The weights are not fetched during the build: the build sandbox has no DNS.
Create them first, then package the tree:

```bash
export OLLAMA_MODELS=/path/to/stage/models
/path/to/stage/bin/ollama serve &
ollama pull lfm3-omni:2b-q4_K_M
ollama pull qwen3-embedding:4b-q4_K_M
cd /path/to/ocr && ollama create xiaomi-ocr -f Modelfile

flatpak build-init --type=extension --base=org.agentzero.AgentZero build \
    org.agentzero.AgentZero.Models org.freedesktop.Sdk/x86_64/25.08 \
    org.agentzero.AgentZero/x86_64/master 1.0
cp -a /path/to/stage/bin /path/to/stage/lib /path/to/stage/models build/files/
flatpak build-finish \
    "--extension=org.agentzero.AgentZero.Models=directory=share/agent-zero/models" build
flatpak build-export repo build 1.0   # branch must be explicit
```

## Distributing the models

`flatpak build-bundle` gzips every ostree object. The weights are GGUF, already
compressed, so that pass buys nothing and costs hours: a 4.7 GB repository
yields ~24 MB/min. Measured on the same repository:

| Path | Command | Time |
| --- | --- | --- |
| Plain tar | `tar -cf models-repo.tar repo2` | 3 s |
| OCI, zstd | `build-bundle --runtime --oci --oci-layer-compress=zstd` | 70 s |
| Default bundle | `build-bundle --runtime` | ~3.7 h |

`--oci-layer-compress` accepts only `gzip` or `zstd`; there is no uncompressed
OCI layer. Ship the repository itself, which is uncompressed by construction:

```bash
tar -cf models-repo.tar -C /path/to/export repo2        # 4.7 GB, 3 s
scp models-repo.tar target:/tmp/ && ssh target '
  tar -xf /tmp/models-repo.tar -C $HOME
  flatpak remote-add --user --no-gpg-verify models-local file://$HOME/repo2
  flatpak install --user -y models-local org.agentzero.AgentZero.Models'
```

Use the OCI form when a single `.flatpak`-style artifact is required:

```bash
flatpak build-bundle --runtime --oci --oci-layer-compress=zstd repo2 models.oci \
    org.agentzero.AgentZero.Models 1.0
tar -cf models-oci.tar -C /tmp models.oci
# target:
tar -xf models-oci.tar -C /tmp
flatpak install --user oci:/tmp/models.oci
```

`flatpak install oci:<dir>` reads the extracted layout directly; the archive is
only a transport wrapper. Verified by uninstalling the WPS runtime and
reinstalling it from its OCI directory.

### Killing a running instance

Do not put the application id in a `pkill -f` pattern in the same shell command
that also starts it: the remote shell's own command line matches and `pkill`
takes the session down. Kill and start in separate calls, and escape the dot:

```bash
pgrep -f "org[.]agentzero" | xargs -r kill -9
```

### Build sandbox limits

The build sandbox has no DNS and no C compiler. Everything that would fetch or
compile is prebuilt and pinned by checksum:

| Piece | Why it is prebuilt |
| --- | --- |
| `wps-office-mcp-deps.tar.gz` | `bun install` needs DNS; produced by `scripts/build-wps-deps.sh`, not stored in the repository |
| `overrides.txt` | `langsmith` and `unstructured` cap `zstandard` and `numpy` below the last CPython 3.14 wheel |
| `requirements-flatpak.txt` | every entry resolves to a wheel except two pure-Python sdists |

## Python version

The main bundle runs CPython 3.14 from python-build-standalone. That choice is
what lets Xpra ship as prebuilt Debian payloads: its C extensions are compiled
for CPython 3.14, matching the interpreter in the bundle.

Two dependency pins differ from the upstream `requirements.txt` for this
reason:

| Package | Upstream | Here | Why |
| --- | --- | --- | --- |
| `tiktoken` | `==0.8.0` | `>=0.12.0,<1.0` | `litellm` requires the newer floor on 3.14 |
| `pydantic` | `==2.11.7` | `>=2.12.0,<3.0.0` | `litellm` requires the newer floor on 3.14 |
| `langchain-unstructured` | `==0.1.6` | removed | pins `onnxruntime<=1.19.2`, which has no 3.14 wheel |

The catch-all document parser is reimplemented in `a0flatpak/parsers.py`, so
removing `langchain-unstructured` costs no parsing capability.

## Runtime state

The application directory is read-only. The framework writes configuration,
prompts, the Web UI assets and plugin state next to its code, so the launcher
seeds a writable tree under `$XDG_DATA_HOME/agent-zero` on first start and
`a0flatpak/base_dir.py` points `helpers.files` at it:

```
$XDG_DATA_HOME/agent-zero/
├── conf/  prompts/  agents/  knowledge/  instruments/  webui/
└── usr/            plugin state, .env, desktop sessions
```

Seeding is per directory, so a partially seeded tree heals on the next start.
`A0_BASE_DIR` overrides the root when a different location is wanted.

## Runtime layout

The Models extension mounts at `/app/share/agent-zero/models`:

```
bin/ollama                 server binary
lib/ollama/                CPU kernels, plus cuda_v12 and cuda_v13 from Cuda
models/                    OLLAMA_MODELS, the weight store
```

The Cuda extension mounts at `lib/ollama` inside that tree, so installing it
adds kernels without touching the weights. Remove it to fall back to CPU.

## GPU

CPU is the default. To use a GPU, install the Cuda extension and pass a device:

```bash
flatpak run --env=CUDA_VISIBLE_DEVICES=0 org.agentzero.AgentZero
```

Without the extension, any device id is ignored and inference runs on CPU.

## WPS

The WPS extension depends on WPS Office being installed on the host. Flatpak
cannot express that as a manifest dependency, because WPS Office is not
available on Flathub: the add-in must run inside the host's own WPS process
and write into the host's WPS profile.

So the dependency is indirect and declared in two places:

1. `install-wps-addon.sh` refuses to run unless `wps` is on `PATH` or
   `/opt/kingsoft/wps-office` exists, and points at <https://linux.wps.cn>.
2. `org.agentzero.AgentZero.Wps.yml` keeps `--filesystem=~/.local/share/Kingsoft/wps/jsaddons:ro`
   so the extension can read the add-in the host installed.

The extension provides the MCP server; the add-in must be installed into the
user's WPS profile on the host:

```bash
bash flatpak/install-wps-addon.sh
```

Then register the server with Agent Zero by pasting
`flatpak/wps-mcp-config.json` into the MCP settings, replacing
`/var/lib/flatpak` when the installation lives elsewhere.

## Files

| File | Purpose |
| --- | --- |
| `org.agentzero.AgentZero.yml` | main bundle |
| `org.agentzero.AgentZero.Models.yml` | Ollama plus weights |
| `org.agentzero.AgentZero.Cuda.yml` | CUDA kernels |
| `org.agentzero.AgentZero.Wps.yml` | WPS MCP server |
| `agent-zero.sh` | main launcher |
| `wps-mcp.sh` | WPS extension entry point |
| `requirements-flatpak.txt` | framework dependencies |
| `a0flatpak/` | runtime adaptations |
| `install-wps-addon.sh` | host-side add-in installer |
| `wps-mcp-config.json` | MCP registration snippet |
