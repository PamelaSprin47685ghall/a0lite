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
# Seed the writable tree once: configuration, prompts and plugin state that
# the framework reads and writes next to its code.
# Each directory is seeded on its own, so a partially seeded tree heals on the
# next start instead of staying incomplete.
mkdir -p "$BASE_DIR/usr/plugins"
for name in conf prompts agents knowledge instruments webui; do
    if [ -d "$APP_ROOT/$name" ] && [ ! -d "$BASE_DIR/$name" ]; then
        cp -a "$APP_ROOT/$name" "$BASE_DIR/$name" 2>/dev/null || true
    fi
done
if [ ! -f "$BASE_DIR/usr/.env" ] && [ -f "$APP_ROOT/usr/.env" ]; then
    cp -a "$APP_ROOT/usr/." "$BASE_DIR/usr/" 2>/dev/null || true
fi

# The framework's own environment prompt describes a Kali Docker container with
# root. Replace it while it is still the shipped text, and leave a prompt the
# user edited alone.
ENV_PROMPT="$BASE_DIR/prompts/agent.system.main.environment.md"
if [ -f "$APP_ROOT/flatpak/prompts/agent.system.main.environment.md" ] &&
   { [ ! -f "$ENV_PROMPT" ] || grep -q "kali linux docker container" "$ENV_PROMPT"; }; then
    cp -a "$APP_ROOT/flatpak/prompts/agent.system.main.environment.md" "$ENV_PROMPT"
fi

# Plugins and extensions are resolved against the writable root, and some of
# them write state inside their own directory, so they are merged rather than
# linked. The merge refreshes code from the bundle on every start and leaves
# whatever the previous run wrote in place.
for name in api plugins extensions; do
    if [ -d "$APP_ROOT/$name" ]; then
        mkdir -p "$BASE_DIR/$name"
        cp -a "$APP_ROOT/$name/." "$BASE_DIR/$name/" 2>/dev/null || true
    fi
done

export OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
export OLLAMA_MODELS="$MODELS_ROOT/models"
export OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-2}"
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
CUDA_ROOT="${A0_CUDA_ROOT:-/app/share/agent-zero/cuda}"
export LD_LIBRARY_PATH="$CUDA_ROOT/cuda_v12:$CUDA_ROOT/cuda_v13:$MODELS_ROOT/lib/ollama${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

mkdir -p "$DATA_DIR" "$LOG_DIR"

# A complete environment has the framework requirements in place. The marker
# is written last so an interrupted first start is retried from scratch.
VENV_MARKER="$VENV/.a0-ready"

# The bundled xpra script resolves its modules from the running interpreter,
# which is the environment prepared below rather than the runtime's python.
# PyGObject needs the gobject-introspection library that ships in /app/lib/gi.
export PYTHONPATH="$PY_DEPS${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="/app/lib/gi${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

install_extension_modules() {
    local site
    site="$("$VENV/bin/python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
    if [ -d "$site/xpra" ]; then
        return 0
    fi
    cp -a "$PY_DEPS"/. "$site"/
}

if [ ! -f "$VENV_MARKER" ]; then
    echo "agent-zero: preparing the framework environment" >&2
    rm -rf "$VENV"
    /app/bin/uv venv --python 3.14 "$VENV"
    /app/bin/uv pip install --python "$VENV/bin/python" \
        --override "$APP_ROOT/flatpak/overrides.txt" \
        -r "$APP_ROOT/flatpak/requirements-flatpak.txt"
    install_extension_modules
    touch "$VENV_MARKER"
fi

OLLAMA_PID=""
if [ -x "$OLLAMA_BIN" ] && [ -n "$(ls -A "$OLLAMA_MODELS" 2>/dev/null)" ]; then
    # CPU-only unless the caller selects a GPU. The Cuda extension provides
    # the CUDA kernels; without it a GPU id has no effect.
    export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:--1}"

    # OLLAMA_HOST is the URL clients dial; the server bind is separate because
    # Ollama refuses requests whose Host header is not loopback when it listens
    # on loopback. Set A0_OLLAMA_BIND=0.0.0.0:11434 to reach it through a
    # tunnel, and accept that the port is then open to the network.
    OLLAMA_BIND="${A0_OLLAMA_BIND:-127.0.0.1:11434}"
    OLLAMA_HOST="$OLLAMA_BIND" "$OLLAMA_BIN" serve >>"$LOG_DIR/ollama.log" 2>&1 &
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
        echo "agent-zero: ollama exited during startup; see $LOG_DIR/ollama.log" >&2
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
    --port="${A0_PORT:-5080}" \
    --host="${A0_HOST:-127.0.0.1}" \
    "$@"
