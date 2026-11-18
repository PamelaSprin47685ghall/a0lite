#!/bin/bash
# Agent Zero launcher for the Flatpak build.
#
# Prepares the framework environment with the bundled uv on first start, runs
# the Web UI, and starts the bundled Ollama server when the Models extension is
# installed.
#
# The interpreter comes from uv, not from the bundle: `uv venv` downloads a
# standalone CPython into the user data directory on first start. The gi, cairo
# and xpra extension modules that ship in /app are copied into that environment
# afterwards, because they are built for the interpreter version uv selects.

set -euo pipefail

APP_ROOT="/app/share/agent-zero"
PY_DEPS="/app/share/python-deps"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/agent-zero"
VENV="${A0_VENV:-$DATA_DIR/venv}"
MODELS_ROOT="${A0_MODELS_ROOT:-/app/share/agent-zero/models}"
LOG_DIR="$DATA_DIR/logs"

OLLAMA_BIN="$MODELS_ROOT/bin/ollama"
# The framework writes under usr/ next to its code, which is read-only in the
# bundle. Point it at a writable tree seeded from the bundle on first start.
BASE_DIR="${A0_BASE_DIR:-$DATA_DIR}"
export A0_BASE_DIR="$BASE_DIR"

# Build identity from scripts/build.sh. The sandbox has no git binary, so the
# UI version, the health endpoint and the seed marker read these values.
if [ -r "$APP_ROOT/.a0-build-info" ]; then
    set -a
    . "$APP_ROOT/.a0-build-info"
    set +a
fi

# Seed the writable tree once: configuration, agents and knowledge that the
# framework reads and writes next to its code.
# Each directory is seeded on its own, so a partially seeded tree heals on the
# next start instead of staying incomplete.
#
# prompts/ is merged on every start instead. The framework reads prompt files
# without a fallback, so a prompt added by an upgrade must reach the writable
# tree or the next error handler that reads it dies with FileNotFoundError
# (fw.msg_output_limit.md was exactly that case). cp -n fills in absent files
# and leaves a prompt the user edited alone.
#
# webui is deliberately not in this list. It is read-only shipped markup, and
# its Alpine templates must match the version of the plugins that extend them
# (plugins/_discovery teleports into slots that only the new welcome screen
# defines). A one-time seed would leave the old copy in place after an upgrade;
# the old markup has no such slot, the teleport fails, and the exception kills
# the global MutationObserver, which is what makes every dialog render blank.
mkdir -p "$BASE_DIR/usr/plugins" "$BASE_DIR/prompts"

# The bundle stores every source mtime as the Unix epoch, and `cp -a` would
# carry that 1970 timestamp into the writable tree, where the file browser
# renders it as 1/1/70. The copies below drop timestamps. This repairs the
# top-level directories that an earlier run seeded with the old behaviour.
# Only the directory is touched; files the user wrote keep their own mtime.
refresh_dir_mtime() {
    [ -d "$1" ] || return 0
    mtime=$(stat -c %Y "$1" 2>/dev/null || echo 0)
    if [ "$mtime" -lt 946684800 ]; then touch "$1" 2>/dev/null || true; fi
}

if [ -d "$APP_ROOT/prompts" ]; then
    cp -an --no-preserve=timestamps "$APP_ROOT/prompts/." "$BASE_DIR/prompts/" 2>/dev/null || true
fi
for name in conf agents knowledge instruments; do
    if [ -d "$APP_ROOT/$name" ] && [ ! -d "$BASE_DIR/$name" ]; then
        cp -a --no-preserve=timestamps "$APP_ROOT/$name" "$BASE_DIR/$name" 2>/dev/null || true
    fi
done
if [ ! -e "$BASE_DIR/usr/.gitkeep" ] && [ -d "$APP_ROOT/usr" ]; then
    cp -a --no-preserve=timestamps "$APP_ROOT/usr/." "$BASE_DIR/usr/" 2>/dev/null || true
fi

# The framework's own tools live at the bundle root, and its resolver looks for
# them under the writable root: `files.get_abs_path("tools", name)`. Without
# this copy the lookup misses, `Agent.get_tool` falls back to tools/unknown.py,
# and the model is told the tool does not exist even though the matching
# prompt file was seeded. Copy on every start, like prompts: a tool an upgrade
# changed must reach the writable tree, and the framework has no fallback to
# the read-only copy.
if [ -d "$APP_ROOT/tools" ]; then
    mkdir -p "$BASE_DIR/tools"
    cp -a --no-preserve=timestamps "$APP_ROOT/tools/." "$BASE_DIR/tools/" 2>/dev/null || true
fi

# The framework still resolves a few paths against /a0, the directory its
# container image used. Inside the sandbox / is writable but ephemeral, so point
# that name at the persistent tree instead: files the agent creates there then
# survive a restart and live on the real disk.
#
# /a0 is a property of this process tree only: Flatpak builds a fresh tmpfs for
# the sandbox root on every run, so a separate `flatpak run --command=sh` probe
# will not see the link. Check it from inside the running app instead:
#   ls -l /proc/<run_ui.py pid>/root/a0
# A failure here is not silent any more: without /a0 the framework falls back to
# relative paths and those land in the read-only bundle.
if [ ! -e /a0 ] && [ -w / ]; then
    if ! ln -s "$BASE_DIR" /a0 2>/dev/null; then
        echo "agent-zero: warning: /a0 could not be created; the framework will" >&2
        echo "agent-zero: resolve its paths against $APP_ROOT, which is read-only" >&2
    fi
fi

# The framework's own environment prompt describes a Kali Docker container with
# root. Replace it while it is still the shipped text, and leave a prompt the
# user edited alone.
ENV_PROMPT="$BASE_DIR/prompts/agent.system.main.environment.md"
if [ -f "$APP_ROOT/flatpak/prompts/agent.system.main.environment.md" ] &&
   { [ ! -f "$ENV_PROMPT" ] || grep -q "kali linux docker container" "$ENV_PROMPT"; }; then
    cp -a --no-preserve=timestamps "$APP_ROOT/flatpak/prompts/agent.system.main.environment.md" "$ENV_PROMPT"
fi

# Plugins and extensions are resolved against the writable root, and some of
# them write state inside their own directory, so they are merged rather than
# linked. The merge refreshes code from the bundle on every start and leaves
# whatever the previous run wrote in place.
#
# webui belongs here, next to the code that extends it: a copy that survives an
# upgrade is worse than no copy, because the old templates outlive the plugins
# they were written for. `cp -a` overwrites same-named files, drops mtimes and
# never deletes: files the new bundle dropped stay behind and are harmless,
# since the new index.html no longer references them.
#
# This copy runs once per build, not on every start. The plugin watchdog treats
# a rewritten plugins/*.py as a code change and purges the plugin namespace;
# a second `flatpak run` used to make the running instance reload every plugin
# and lose its speech patch. The marker carries the build time as well as the
# commit, so a rebuild from a dirty tree still refreshes the copy.
SEED_MARKER="$BASE_DIR/.a0-seeded-${A0_BUILD_COMMIT:-unknown}"
SEED_STAMP="${A0_BUILD_COMMIT:-unknown} ${A0_BUILD_TIME:-unknown}"
if [ ! -f "$SEED_MARKER" ] || [ "$(cat "$SEED_MARKER" 2>/dev/null)" != "$SEED_STAMP" ]; then
    for name in api plugins extensions webui; do
        if [ -d "$APP_ROOT/$name" ]; then
            mkdir -p "$BASE_DIR/$name"
            cp -a --no-preserve=timestamps "$APP_ROOT/$name/." "$BASE_DIR/$name/" 2>/dev/null || true
        fi
    done
    printf '%s\n' "$SEED_STAMP" > "$SEED_MARKER"
fi

# Paths the bundle dropped in the scheduler move. Removing them keeps the
# writable webui identical to the shipped one, which the upgrade check asserts.
# This list is deliberately explicit: when upstream moves files again, add the
# old paths here. `rm -rf "$BASE_DIR/webui"` would be shorter and wrong, because
# it would also delete whatever an operator put under webui/ - assets belong in
# conf/ or usr/, as README says.
for stale in components/modals/scheduler components/sidebar/tasks \
             css/scheduler.css css/scheduler-datepicker.css; do
    rm -rf "$BASE_DIR/webui/$stale"
done

for name in prompts conf agents knowledge instruments tools usr api plugins extensions webui; do
    refresh_dir_mtime "$BASE_DIR/$name"
done

export OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
export OLLAMA_MODELS="$MODELS_ROOT/models"
# Two models stay resident on purpose: OCR, embeddings and speech each use a
# different model, and MAX_LOADED_MODELS=1 made them evict and reload each
# other (docs/manual-acceptance/a0lite-deploy/probe-pdf.md).  Operators with
# less VRAM can lower it; nothing here overrides a value already set.
export OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-2}"
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
# These four are fallbacks, not overrides. ``a0flatpak`` calls
# ``helpers.dotenv.load_dotenv()``, which passes ``override=True``, so a key in
# ``usr/.env`` replaces whatever was exported here. Keep the export for the
# values the bundle owns, and let the file win for the rest:
#   OLLAMA_MODELS            bundle layout; the Models extension mounts there
#   OLLAMA_HOST              client URL; a remote Ollama is a valid choice
#   OLLAMA_*_MODELS/_ALIVE   memory tuning; operator territory
CUDA_ROOT="${A0_CUDA_ROOT:-/app/share/agent-zero/cuda}"
export LD_LIBRARY_PATH="$CUDA_ROOT/cuda_v12:$CUDA_ROOT/cuda_v13:$MODELS_ROOT/lib/ollama${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# The Web UI's own address. Both the origin check below and the final exec use
# these, so they are resolved once, here.
A0_PORT="${A0_PORT:-5080}"
A0_HOST="${A0_HOST:-127.0.0.1}"

# Upstream refuses every CSRF token request when no login is configured and the
# request's Origin is not in ALLOWED_ORIGINS; without a token every POST is
# rejected with 403, so the Settings and Projects dialogs stay empty and chat
# cannot send. That is a hard dependency, not an optional hardening.
#
# Upstream's built-in fallback only matches loopback (``*://localhost*``,
# ``*://127.0.0.1:*``, ``*://0.0.0.0:*``), which is why any other host - a LAN
# address, or the public domain of a reverse proxy - fails until the operator
# adds it. The default below keeps the loopback pair the browser actually
# visits and appends the configured bind address when it is a real one.
#
# A value the operator set is used as is: no appending, no rewriting. A tunnel
# domain cannot be inferred here, so README says to add it by hand.
if [ -z "${ALLOWED_ORIGINS:-}" ]; then
    # A value in usr/.env is operator input too. ``load_dotenv`` currently runs
    # with ``override=True`` (helpers/dotenv.py), so the file would win anyway;
    # the check keeps that true if upstream ever flips to the python-dotenv
    # default of not overwriting. Without it, exporting a default here would
    # silently mask the file.
    if [ -f "$BASE_DIR/usr/.env" ] && \
       grep -qE '^[[:space:]]*(export[[:space:]]+)?ALLOWED_ORIGINS=' "$BASE_DIR/usr/.env"; then
        :
    else
        ALLOWED_ORIGINS="http://127.0.0.1:$A0_PORT,http://localhost:$A0_PORT"
        case "$A0_HOST" in
            127.0.0.1|localhost|0.0.0.0|::|::1)
                # A wildcard bind has no browsable origin of its own; the
                # loopback pair above is what a local browser sends.
                ;;
            *)
                ALLOWED_ORIGINS="$ALLOWED_ORIGINS,http://$A0_HOST:$A0_PORT"
                ;;
        esac
        export ALLOWED_ORIGINS
    fi
fi

mkdir -p "$DATA_DIR" "$LOG_DIR"

# A complete environment has the framework requirements in place. The marker
# is written last so an interrupted first start is retried from scratch.
VENV_MARKER="$VENV/.a0-ready"

# The bundled xpra script resolves its modules from the running interpreter,
# which is the environment prepared below rather than the runtime's python.
# PyGObject needs the gobject-introspection library that ships in /app/lib/gi.
export PYTHONPATH="$PY_DEPS${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="/app/lib/gi${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# The gi, cairo and xpra trees are copied out of the read-only bundle into the
# venv. They must be refreshed whenever the bundle changes: a venv built by an
# older image keeps the old xpra, and the new code then imports a submodule the
# old layout does not have ("No module named 'xpra.net.mmap.common'; 'xpra.net.mmap'
# is not a package"). Old layout plus new code is the normal upgrade path, so the
# copy cannot be one-shot.
#
# The stamp is written at build time from the file list and sizes of those three
# trees (see the xpra module in the manifest). File mtimes are useless here: the
# build normalises every mtime to the epoch, so a mtime stamp would never change.
py_deps_version() {
    cat "$PY_DEPS/.a0-python-deps" 2>/dev/null || echo unknown
}

install_extension_modules() {
    local site stamp
    site="$("$VENV/bin/python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
    stamp="$site/.a0-python-deps"
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$(py_deps_version)" ]; then
        return 0
    fi
    # Only these three trees are replaced. Everything else in the venv belongs
    # to the framework requirements and must survive.
    rm -rf "$site/xpra" "$site/gi" "$site/cairo"
    find "$site" -maxdepth 2 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
    cp -a "$PY_DEPS"/. "$site"/
    py_deps_version > "$stamp"
}

if [ ! -f "$VENV_MARKER" ]; then
    echo "agent-zero: preparing the framework environment" >&2
    rm -rf "$VENV"
    /app/bin/uv venv --python 3.14 "$VENV"
    /app/bin/uv pip install --python "$VENV/bin/python" \
        --override "$APP_ROOT/flatpak/overrides.txt" \
        -r "$APP_ROOT/flatpak/requirements-flatpak.txt"
    touch "$VENV_MARKER"
fi

# Unconditional: a venv from an older image is otherwise never refreshed.
install_extension_modules

OLLAMA_PID=""
if [ -x "$OLLAMA_BIN" ] && [ -n "$(ls -A "$OLLAMA_MODELS" 2>/dev/null)" ]; then
    # CPU-only unless the caller selects a GPU. The Cuda extension provides
    # the CUDA kernels; without it a GPU id has no effect.
    export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:--1}"

    # AMD integrated GPUs are dropped by default; enable Vulkan inference on
    # them. A0_OLLAMA_IGPU=0 restores the previous CPU-only behaviour, and a
    # value the operator already set wins. See
    # docs/manual-acceptance/a0lite-deploy/amd-gpu-inventory.md.
    if [ "${A0_OLLAMA_IGPU:-1}" = "1" ]; then
        : "${OLLAMA_IGPU_ENABLE:=1}"
        : "${GGML_VK_VISIBLE_DEVICES:=0}"
        export OLLAMA_IGPU_ENABLE GGML_VK_VISIBLE_DEVICES
    fi

    # Vulkan tuning measured on Radeon 780M; see vulkan-tuning.md.  These
    # trade VRAM, not speed: context 4096 saves 349 MB, and flash attention
    # is the prerequisite for KV cache quantization (q8_0 saves 6 MB).
    # Speed stays within noise: no setting here moved tps by more than ~1%.
    # num_batch has no environment variable in Ollama 0.40, so it is not set
    # here; a request can pass 512 to save another 320 MB.
    : "${OLLAMA_CONTEXT_LENGTH:=4096}"
    : "${OLLAMA_FLASH_ATTENTION:=1}"
    : "${OLLAMA_KV_CACHE_TYPE:=q8_0}"
    export OLLAMA_CONTEXT_LENGTH OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE

    # OLLAMA_HOST is the URL clients dial; the server bind is separate because
    # Ollama refuses requests whose Host header is not loopback when it listens
    # on loopback. Set A0_OLLAMA_BIND=0.0.0.0:11434 to reach it through a
    # tunnel, and accept that the port is then open to the network.
    OLLAMA_BIND="${A0_OLLAMA_BIND:-127.0.0.1:11434}"
    # Not under logs/: the framework's migration step deletes "$BASE_DIR/logs"
    # on start ("Removing logs...", helpers/migration.py) *after* Ollama has
    # already opened its file, which leaves the process writing to an unlinked
    # inode and no log on disk. $DATA_DIR itself survives that cleanup.
    OLLAMA_LOG="$DATA_DIR/ollama.log"
    OLLAMA_HOST="$OLLAMA_BIND" "$OLLAMA_BIN" serve >>"$OLLAMA_LOG" 2>&1 &
    OLLAMA_PID=$!
    trap '[ -n "$OLLAMA_PID" ] && kill "$OLLAMA_PID" 2>/dev/null || true' EXIT

    for _ in $(seq 1 120); do
        if curl -fsS "${OLLAMA_HOST}/api/version" >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done

    # A stale process from an earlier run can hold the port. The readiness probe
    # above cannot tell that apart from a healthy start, so check the child.
    if ! kill -0 "$OLLAMA_PID" 2>/dev/null; then
        echo "agent-zero: ollama exited during startup; see $OLLAMA_LOG" >&2
        echo "agent-zero: another process may already own $OLLAMA_BIND" >&2
    fi
else
    echo "agent-zero: no model backend at $MODELS_ROOT" >&2
    echo "agent-zero: install org.agentzero.AgentZero.Models for chat, OCR and speech" >&2
    export A0_MODELS_MISSING=1
fi

# Load the bundled-Ollama adaptations before the framework starts.
# The sandbox has no git binary; GitPython warns on import otherwise.
export GIT_PYTHON_REFRESH=quiet

export PYTHONPATH="$APP_ROOT/flatpak${PYTHONPATH:+:$PYTHONPATH}"

cd "$APP_ROOT"
exec "$VENV/bin/python" -c \
    "import a0flatpak; a0flatpak.apply(); import runpy; runpy.run_path('run_ui.py', run_name='__main__')" \
    --port="$A0_PORT" \
    --host="$A0_HOST" \
    "$@"
