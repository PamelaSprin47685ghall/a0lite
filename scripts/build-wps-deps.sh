#!/bin/sh
# Produce wps-office-mcp-deps.tar.gz, the prebuilt dependency tree the WPS
# manifest consumes.
#
# The build sandbox has no DNS, so the server's node_modules and compiled dist
# are packaged ahead of time and pinned by checksum in
# org.agentzero.AgentZero.Wps.yml. This script rebuilds that tarball from the
# same pinned upstream archive the manifest uses.
#
# Usage: build-wps-deps.sh [output-dir]
#
# Requires: curl, tar, bun. Not npm: bun is the runtime the server ships with.

set -eu

OUT=${1:-$(pwd)}
SKILLS_COMMIT=a82533662268b3245f93d8685bc45dffede048b6
SKILLS_SHA256=b86b1f221952ef8fcdcac028e24b4ce472163c0079487264ec1a649c0cbf1761
ARCHIVE="wps-skills-$SKILLS_COMMIT.tar.gz"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

command -v bun >/dev/null || { echo "build-wps-deps: bun is required" >&2; exit 1; }

cd "$WORK"
curl -fsSL -o "$ARCHIVE" "https://github.com/lc2panda/wps-skills/archive/$SKILLS_COMMIT.tar.gz"
echo "$SKILLS_SHA256  $ARCHIVE" | sha256sum -c - || {
    echo "build-wps-deps: upstream archive does not match the pinned checksum" >&2
    exit 1
}
tar -xf "$ARCHIVE"

SERVER=wps-skills-$SKILLS_COMMIT/wps-office-mcp
[ -d "$SERVER" ] || { echo "build-wps-deps: $SERVER missing in archive" >&2; exit 1; }

cd "$SERVER"
bun install --frozen-lockfile
bun run build

# The manifest strips one component and expects node_modules/ and dist/ at the
# module root.
tar -czf "$OUT/wps-office-mcp-deps.tar.gz" node_modules dist

echo "written: $OUT/wps-office-mcp-deps.tar.gz"
echo "sha256 : $(sha256sum "$OUT/wps-office-mcp-deps.tar.gz" | cut -d' ' -f1)"
echo "pinned : ff53b5920ebd705b0f47e9ee8dcd04b0755cab1f937e515a0f1ee28ea547ec73"
echo
echo "A mismatch is not fatal: update the sha256 in"
echo "org.agentzero.AgentZero.Wps.yml to the value printed above. Byte-for-byte"
echo "equality depends on the bun version reproducing identical output."
