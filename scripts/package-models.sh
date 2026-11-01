#!/bin/sh
# Package Ollama weights as the Models extension and emit a transferable
# repository.
#
# Usage: package-models.sh <ollama-dir> [output-dir]
#
# <ollama-dir> is an Ollama installation whose OLLAMA_MODELS directory holds
# the three models the runtime expects. Create them there first:
#
#   export OLLAMA_MODELS=$STAGE/models
#   $STAGE/bin/ollama serve &
#   ollama pull lfm3-omni:2b-q4_K_M
#   ollama pull qwen3-embedding:4b-q4_K_M
#   (cd $OCR_DIR && ollama create xiaomi-ocr -f Modelfile)
#
# The build sandbox has no DNS, so weights are never fetched during a build;
# they are packaged afterwards from a staged tree.
#
# Output: models-repo.tar, an uncompressed copy of the ostree repository. Ship
# that, not a .flatpak: build-bundle gzips every object and the weights are
# already compressed, which costs hours for no gain.

set -eu

STAGE=${1:?usage: package-models.sh <ollama-dir> [output-dir]}
OUT=${2:-$(pwd)}
HERE=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD:-$HERE/build/models}
REPO=${REPO:-$HERE/build/models-repo}

[ -x "$STAGE/bin/ollama" ] || { echo "package-models: no ollama in $STAGE" >&2; exit 1; }
[ -d "$STAGE/models/blobs" ] || { echo "package-models: no weights in $STAGE/models" >&2; exit 1; }

mkdir -p "$OUT"

if [ ! -d "$BUILD/files" ]; then
    flatpak build-init --type=extension --base=org.agentzero.AgentZero \
        "$BUILD" org.agentzero.AgentZero.Models \
        org.freedesktop.Sdk/x86_64/25.08 \
        org.agentzero.AgentZero/x86_64/master 1.0
fi

rm -rf "$BUILD/files/bin" "$BUILD/files/lib" "$BUILD/files/models"
cp -a "$STAGE/bin" "$STAGE/lib" "$STAGE/models" "$BUILD/files/"

flatpak build-finish \
    "--extension=org.agentzero.AgentZero.Models=directory=share/agent-zero/models" \
    "$BUILD"
# The branch must be explicit: without it the ref lands on `master` and
# the extension does not mount, because the manifest asks for 1.0.
flatpak build-export "$REPO" "$BUILD" 1.0

# Uncompressed transport. build-bundle would gzip 5 GB of GGUF weights at about
# 24 MB/min; tar does it in seconds and flatpak install reads the repo directly.
tar -cf "$OUT/models-repo.tar" -C "$(dirname "$REPO")" "$(basename "$REPO")"

ls -lh "$OUT/models-repo.tar"
echo
echo "On the target:"
echo "  tar -xf models-repo.tar -C \$HOME"
echo "  flatpak remote-add --user --no-gpg-verify models-local file://\$HOME/$(basename "$REPO")"
echo "  flatpak install --user -y models-local org.agentzero.AgentZero.Models"
