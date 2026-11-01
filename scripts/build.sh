#!/bin/sh
# Build the three application bundles from this repository.
#
# Usage: A0_SRC=/path/to/agent-zero build.sh [output-dir]
#
# A0_SRC must be a checkout of https://github.com/agent0ai/agent-zero. The main
# manifest copies its parent directory (`path: ..`) into the image, so the
# packaging layer has to sit inside that checkout as `flatpak/`.
#
# This script copies the layer in, builds, and writes the bundles. It installs
# nothing. Each manifest declares its own branch, so no branch flag is needed.

set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
A0_SRC=${A0_SRC:?set A0_SRC to an agent-zero checkout}
OUT=${OUT:-$HERE/bundles}
STATE=${STATE:-$HERE/build}
CACHE=$STATE/cache

[ -f "$A0_SRC/run_ui.py" ] || {
    echo "build: $A0_SRC does not look like an agent-zero checkout" >&2
    exit 1
}

mkdir -p "$OUT" "$STATE"

# The layer is ours; the rest of the checkout is upstream.
cp -a "$HERE/flatpak" "$A0_SRC/"
if [ -d "$HERE/docs" ]; then cp -a "$HERE/docs" "$A0_SRC/"; fi

# wps-office-mcp-deps.tar.gz is not in this repository: it is third-party
# output, so it is produced here and checked against the manifest pin.
DEPS=$A0_SRC/flatpak/wps-office-mcp-deps.tar.gz
PIN=$(awk '/path: wps-office-mcp-deps.tar.gz$/ { getline; if ($1 == "sha256:") print $2 }' \
        "$A0_SRC/flatpak/org.agentzero.AgentZero.Wps.yml")
[ -n "$PIN" ] || { echo "build: no checksum pinned for the deps tarball" >&2; exit 1; }

if [ -f "$DEPS" ]; then
    ACTUAL=$(sha256sum "$DEPS" | cut -d' ' -f1)
    if [ "$ACTUAL" != "$PIN" ]; then
        echo "build: deps tarball does not match the pin, rebuilding it"
        rm -f "$DEPS"
    fi
fi

if [ ! -f "$DEPS" ]; then
    echo "build: producing wps-office-mcp-deps.tar.gz"
    "$HERE/scripts/build-wps-deps.sh" "$A0_SRC/flatpak"
fi

cd "$A0_SRC"

# The main bundle must be built first: the extensions fill points it declares.
for manifest in org.agentzero.AgentZero org.agentzero.AgentZero.Cuda \
                org.agentzero.AgentZero.Wps; do
    echo "=== $manifest"
    flatpak-builder --user --force-clean --disable-rofiles-fuse \
        --state-dir="$STATE" --install-deps-from=flathub \
        "$STATE/build-${manifest##*.}" "flatpak/$manifest.yml"
done

flatpak build-bundle "$CACHE" "$OUT/agent-zero.flatpak" \
    org.agentzero.AgentZero master
flatpak build-bundle --runtime "$CACHE" "$OUT/agent-zero-cuda.flatpak" \
    org.agentzero.AgentZero.Cuda 12
flatpak build-bundle "$CACHE" "$OUT/agent-zero-wps.flatpak" \
    org.agentzero.AgentZero.Wps 1.0

ls -lh "$OUT"
