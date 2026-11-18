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
flatpak build-export repo build
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
| `wps-office-mcp-deps.tar.gz` | `bun install` needs DNS |
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

Two groups are treated differently:

- `conf/ agents/ knowledge/ instruments/` are seeded once and then left alone,
  because they hold what the user edits.
- `prompts/` is merged on **every** start: files absent from the writable tree
  are copied in, existing files are left alone. The framework reads prompt
  files without a fallback, so a prompt added by an upgrade must reach the
  writable tree; otherwise any error handler that reads it fails with
  `FileNotFoundError` instead of reporting the original error. This is what
  made `fw.msg_output_limit.md` turn every model error into a second failure.
- `api/ plugins/ extensions/ webui/` are refreshed from the bundle on **every**
  start. `webui` is read-only shipped markup and must stay the same version as
  the plugins that extend it: the newer `plugins/_discovery` teleports into
  slots that only the newer `webui/components/welcome/welcome-screen.html`
  defines. When an old `webui` survives an upgrade, the teleport has no target,
  Alpine throws inside its global mutation callback and never reconnects, and
  every dynamically inserted dialog - Settings, Projects - renders blank.

The refresh copies over same-named files and never deletes: files a newer
bundle dropped stay behind, which is harmless because the new `index.html` no
longer references them.

**Customise through `conf/` or `usr/`, never through `webui/`.** A file placed
in `webui/` is overwritten by the next start; the bundle is the authority for
that tree.

## Runtime layout

The Models extension mounts at `/app/share/agent-zero/models`:

```
bin/ollama                 server binary
lib/ollama/                CPU kernels, plus cuda_v12 and cuda_v13 from Cuda
models/                    OLLAMA_MODELS, the weight store
```

The Cuda extension mounts at `lib/ollama` inside that tree, so installing it
adds kernels without touching the weights. Remove it to fall back to CPU.

## Authentication

`A0_AUTH_KEY` turns on the check that the framework lacks. It is applied inside
the process, where the serving stack is handed to uvicorn
(`helpers.server_startup.run_uvicorn_with_retries`), so it covers the Flask
routes, the MCP and A2A mounts and the socket.io channel at once:

```bash
flatpak override --user --env=A0_AUTH_KEY=AP4XA org.agentzero.AgentZero
```

A request without the key gets `401`. The key is accepted as
`Authorization: Bearer`, `X-API-Key`, the `a0key` cookie, or a one-time
`?key=` that sets that cookie, so a browser only needs the query once.

The desktop inherits the same key on both paths: `a0flatpak/desktop.py` sets
`XPRA_PASSWORD` from it and adds `--tcp-auth=env` for the host-display session
and for the headless one, so Xpra asks for the key before it accepts a desktop
connection. The HTML page itself is served without a key; the session behind
it is not.

### Origins when no login is set

The CSRF token endpoint refuses any request whose `Origin` is not allow-listed,
and without a token every `POST` is rejected with `403`. The visible symptom is
an empty Settings or Projects dialog and a chat that never sends. The launcher
therefore fills `ALLOWED_ORIGINS` when the operator leaves it empty:

```
http://127.0.0.1:$A0_PORT,http://localhost:$A0_PORT
```

`A0_HOST` is appended as `http://$A0_HOST:$A0_PORT` unless it is loopback or a
wildcard bind. **Behind a reverse proxy or a tunnel, add your public URL** - the
launcher cannot infer it:

```bash
flatpak override --user \
  --env=ALLOWED_ORIGINS=https://example.test:12443,http://127.0.0.1:5080 \
  org.agentzero.AgentZero
```

A value you set is used verbatim: nothing is appended or rewritten.

Ollama has no authentication of any kind and no hook to add one. An exposed
Ollama port is open to anyone who reaches it; keep it behind a tunnel or a
firewall, or leave it unexposed.

Its log is `$DATA_DIR/ollama.log`, not `$DATA_DIR/logs/ollama.log`: the
framework's migration step deletes `logs/` on start, after Ollama has already
opened its file.

## Exposing Ollama

The launcher binds Ollama to `127.0.0.1:11434` and keeps `OLLAMA_HOST` pointing
at that URL for its own clients. Ollama answers 403 to any request whose `Host`
header is not loopback while it listens on loopback, so a TCP tunnel that
forwards to it without rewriting the header cannot reach it. Bind it to the
wildcard instead:

```bash
flatpak override --user --env=A0_OLLAMA_BIND=0.0.0.0:11434 org.agentzero.AgentZero
```

That opens 11434 to the network. Ollama has no authentication; expose it only
behind a tunnel or a firewall.

## GPU

CPU is the default. To use a GPU, install the Cuda extension and pass a device:

```bash
flatpak run --env=CUDA_VISIBLE_DEVICES=0 org.agentzero.AgentZero
```

Without the extension, any device id is ignored and inference runs on CPU.

## WPS

The WPS extension provides an MCP server. WPS Office itself must come from the
host: the add-in runs inside the host's WPS process and writes into the host's
WPS profile, and Flatpak cannot express that as a manifest dependency because
WPS Office is not on Flathub.

Two halves must both be present:

1. `org.agentzero.AgentZero.Wps` — the MCP server on stdio, plus a poll
   endpoint on `127.0.0.1:58891` that the add-in calls.
2. The add-in in the host's WPS profile — installed by
   `flatpak/install-wps-addon.sh`, which refuses to run unless `wps` is on
   `PATH` or `/opt/kingsoft/wps-office` exists
   (<https://linux.wps.cn>). `org.agentzero.AgentZero.Wps.yml` keeps
   `--filesystem=~/.local/share/Kingsoft/wps/jsaddons:ro` so the extension can
   read it.

```bash
bash flatpak/install-wps-addon.sh
```

### Register the server

Paste `flatpak/wps-mcp-config.json` into Agent Zero's MCP settings
(Settings → MCP). The main bundle starts the server through `flatpak-spawn
--host`, because Flatpak hides its own install tree from the sandbox (see
below). The file describes a per-user install, which is what the build
commands above produce. An install built before this permission was added
needs the talk permission described under Sandbox visibility first; one
override enables it without a rebuild:

The `env` block is required, not decorative. The MCP client gives a stdio
server only the SDK's default environment (`HOME`, `LOGNAME`, `PATH`,
`SHELL`, `TERM`, `USER`); it does not inherit the app's
`DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`, `DISPLAY` or `XAUTHORITY`.
Without the bus address, `flatpak-spawn --watch-bus` exits with
`Can't find bus: Cannot autolaunch D-Bus without X11 $DISPLAY`, and the
client reports `McpError: Connection closed`. Keep these four values in the
registration when copying the snippet.

`--directory` is the second required argument. The app's working directory is
`/app/share/agent-zero`, which does not exist on the host; without an explicit
`--directory=/`, `flatpak-spawn --host` fails with
`Failed to change to directory ?/app/share/agent-zero? (No such file or
directory)` before the server starts. The example below uses `/`, which exists on every host. The four `env` values above are this host's; a different user must
change `XDG_RUNTIME_DIR` and `XAUTHORITY` (and `DISPLAY` if not `:0`).

```json
{
  "mcpServers": {
    "wps-office": {
      "command": "/usr/bin/flatpak-spawn",
      "env": {
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/flatpak/bus",
        "XDG_RUNTIME_DIR": "/run/user/1000",
        "DISPLAY": ":0.0",
        "XAUTHORITY": "/run/flatpak/Xauthority"
      },
      "args": [
        "--directory=/",
        "--watch-bus",
        "--host",
        "/home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/bin/bun",
        "/home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/wps-skills/wps-office-mcp/dist/index.js"
      ]
    }
  }
}
```

A system-wide install keeps the same `command` and changes the two host paths
to `/var/lib/flatpak`:

```json
{
  "mcpServers": {
    "wps-office": {
      "command": "/usr/bin/flatpak-spawn",
      "args": [
        "--watch-bus",
        "--host",
        "/var/lib/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/bin/bun",
        "/var/lib/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/wps-skills/wps-office-mcp/dist/index.js"
      ]
    }
  }
}
```

Use absolute paths for the two host arguments and replace `/home/kunweiz`
with your own home directory. Agent Zero splits `command` with `shlex.split`
and checks it with `shutil.which` (`helpers/mcp_handler.py:118` and `:1566`),
and it starts the process without a shell. Neither step expands `~` or
`$HOME`, so a literal `~` fails with `Command '~/...' not found`.

`--watch-bus` makes the host-side server exit when the sandboxed caller
disappears, so a crashed client does not leave a process holding port 58891.

Do not use `.../files/bin/wps-mcp` as the command. That entry point sets
`EXT_ROOT=/app` and only works through
`flatpak run --command=wps-mcp org.agentzero.AgentZero.Wps`.

### Sandbox visibility

`--filesystem=host` covers the user's files but not Flatpak's own install
tree: inside the sandbox `~/.local/share/flatpak` is an empty directory, and
`/var/lib/flatpak` is hidden the same way. The sandbox also has no `flatpak`
command, so it cannot run the extension with `flatpak run` either. The WPS
bundle is an app, not a runtime, and the main manifest does not list it under
`add-extensions`, so there is no mount point to fall back on.

`flatpak-spawn --host` is the bridge. The main manifest grants
`--talk-name=org.freedesktop.Flatpak`; that is the minimum that lets a
sandboxed process ask the host to run a command. It is also a real widening of
the sandbox boundary: the agent can run any host command it can name. The
bundle already grants `--filesystem=host` because the agent works on the
machine, so this adds little in practice, but it is not free.

An installed main bundle keeps the permissions it was built with. Enable the
bridge on an existing install without rebuilding:

```bash
flatpak override --user --talk-name=org.freedesktop.Flatpak org.agentzero.AgentZero
```

This writes `~/.local/share/flatpak/overrides/org.agentzero.AgentZero`. Remove
it with `flatpak override --user --reset org.agentzero.AgentZero`; that reset
also drops any other per-user override for this app.

Verified with only that permission: a sandboxed process ran
`flatpak-spawn --host <bun> <dist/index.js>`, completed `initialize`, listed
250 tools, and answered `wps_list_cache` in 4 ms. Without the permission,
`flatpak-spawn --host` fails with `Portal call failed:
org.freedesktop.DBus.Error.ServiceUnknown`.

On a host checkout there is no `flatpak-spawn` binary. Run the extension's
`bun` and `dist/index.js` directly there; the `--host` wrapper is only for the
Flatpak sandbox.

### Without WPS Office

The server still starts and completes the MCP handshake on a host without WPS
Office. `initialize` reports `wps-office-mcp` with protocol `2024-11-05`, and
`tools/list` returns 250 tools. Only the four cross-application cache tools
(`wps_cache_data`, `wps_get_cached_data`, `wps_list_cache`,
`wps_clear_cache`) work without the add-in; they answer in milliseconds.
`wps_ppt_set_active_target` also answers immediately when called with
`clear=true` or without a name, because that branch only changes a variable in
the server process.

Every tool that needs the add-in goes through port 58891 and waits for it.
`wps_check_connection` returns `{"connected":false,...}` after about 30 s, and
document, workbook and presentation tools fail the same way with
`Command timeout after 30000ms: <action>`. Errors are readable; the process
does not crash and does not hang forever. Do not read a successful handshake
as a working WPS integration.

`wps_check_connection` returns `isError: false` even though the payload says
`connected: false`. That is upstream behavior; read the payload, not only
`isError`. `wps_common_get_app_info` returns `isError: true` for the same
failure.

`switchApp` is also upstream and macOS-shaped: it runs `wps-auto.sh`, which
calls `open` and reads `/tmp/server.log`. On a Linux host it cannot start WPS
and adds about 30 s before the tool's own 30 s timeout.

Handshake check from inside the main bundle's sandbox, without starting Agent
Zero:

```bash
# Only needed on an installed bundle built before the manifest change:
flatpak override --user --talk-name=org.freedesktop.Flatpak org.agentzero.AgentZero

flatpak run --user --command=/usr/bin/python3 org.agentzero.AgentZero - <<'PY'
import json, os, subprocess

ext = os.path.expanduser("~/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files")
proc = subprocess.Popen(
    ["/usr/bin/flatpak-spawn", "--watch-bus", "--host",
     ext + "/bin/bun", ext + "/wps-skills/wps-office-mcp/dist/index.js"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
)

def send(message):
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()

def receive():
    return json.loads(proc.stdout.readline())

send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2024-11-05", "capabilities": {},
    "clientInfo": {"name": "probe", "version": "1"}}})
print(receive()["result"]["serverInfo"])
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
tools = receive()["result"]["tools"]
print(len(tools), [tool["name"] for tool in tools[:5]])
proc.stdin.close()
proc.terminate()
proc.wait()
PY
```

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
| `prompts/` | environment prompt override |
| `install-wps-addon.sh` | host-side add-in installer |
| `wps-mcp-config.json` | MCP registration snippet |
