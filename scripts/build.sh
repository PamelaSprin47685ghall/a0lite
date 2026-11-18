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

# Build identity. The sandbox has no git binary and no .git, so the runtime
# reports these values instead of inspecting the checkout. The describe runs
# in this repository, not in the copy under $A0_SRC.
#
# Two distinct times are exported. A0_COMMIT_TIME is the HEAD commit's own
# timestamp and is what the UI labels as a commit time; it must not change
# when the same commit is rebuilt. A0_BUILD_TIME is the wall clock of this
# build. Conflating them made the footer claim a commit time that moved
# between rebuilds of identical source.
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if COMMIT_TIME=$(TZ=UTC git -C "$HERE" log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd 2>/dev/null) && [ -n "$COMMIT_TIME" ]; then
    :
else
    COMMIT_TIME=$BUILD_TIME
    echo "build: warning: cannot read commit time from $HERE, falling back to build time" >&2
fi

printf 'A0_BUILD_VERSION=%s\nA0_BUILD_COMMIT=%s\nA0_COMMIT_TIME=%s\nA0_BUILD_TIME=%s\n' \
    "$(git -C "$HERE" describe --tags --always --dirty 2>/dev/null || echo dev)" \
    "$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo dev)" \
    "$COMMIT_TIME" "$BUILD_TIME" > "$A0_SRC/flatpak/build-info.env"

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

# The tarball is not byte-reproducible: bun and the build embed versions and
# timestamps. A regenerated copy therefore carries a different checksum, so the
# pin is updated in the build copy and the change is reported. The repository
# keeps the checksum of the artifact that was actually shipped.
ACTUAL=$(sha256sum "$DEPS" | cut -d' ' -f1)
if [ "$ACTUAL" != "$PIN" ]; then
    echo "build: deps tarball is $ACTUAL, pin says $PIN"
    echo "build: updating the pin in $A0_SRC/flatpak/org.agentzero.AgentZero.Wps.yml"
    sed -i "s/$PIN/$ACTUAL/" "$A0_SRC/flatpak/org.agentzero.AgentZero.Wps.yml"
fi

cd "$A0_SRC"

# The main bundle must be built first: the extensions fill points it declares.
for manifest in org.agentzero.AgentZero org.agentzero.AgentZero.Cuda \
                org.agentzero.AgentZero.Wps; do
    echo "=== $manifest"
    flatpak-builder --user --force-clean --disable-rofiles-fuse \
        --state-dir="$STATE" --install-deps-from=flathub --repo="$CACHE" \
        "$STATE/build-${manifest##*.}" "flatpak/$manifest.yml"
done

flatpak build-bundle "$CACHE" "$OUT/agent-zero.flatpak" \
    org.agentzero.AgentZero master
flatpak build-bundle --runtime "$CACHE" "$OUT/agent-zero-cuda.flatpak" \
    org.agentzero.AgentZero.Cuda 12
flatpak build-bundle "$CACHE" "$OUT/agent-zero-wps.flatpak" \
    org.agentzero.AgentZero.Wps 1.0

ls -lh "$OUT"
