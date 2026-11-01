#!/bin/bash
# Entry point for the WPS extension.
#
# Agent Zero starts this through MCP:
#   flatpak run --command=wps-mcp org.agentzero.AgentZero.Wps
#
# The process speaks MCP on stdin/stdout and serves the WPS add-in poll API on
# 127.0.0.1:58891. It runs on Bun, which is what the build uses. The add-in
# itself is installed into the user's WPS profile by
# flatpak/install-wps-addon.sh, because it must live where the host WPS process
# reads it.

set -euo pipefail

EXT_ROOT="/app"
BUN="$EXT_ROOT/bin/bun"
SERVER="$EXT_ROOT/wps-skills/wps-office-mcp/dist/index.js"

if [ ! -x "$BUN" ]; then
    echo "wps-mcp: bun is missing from the extension" >&2
    exit 1
fi

if [ ! -f "$SERVER" ]; then
    echo "wps-mcp: MCP server is missing at $SERVER" >&2
    exit 1
fi

exec "$BUN" "$SERVER" "$@"
