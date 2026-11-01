#!/bin/bash
# Install the WPS add-in that talks to the wps-skills MCP server.
#
# The add-in is a JavaScript bundle WPS loads from the user profile:
#   ~/.local/share/Kingsoft/wps/jsaddons/claude-assistant_/
# The trailing underscore is required by WPS.
#
# The MCP server itself comes from org.agentzero.AgentZero.Wps. Both halves
# are needed: the add-in polls http://127.0.0.1:58891, and the extension serves
# it.
#
# Run this on the host, not inside the sandbox:
#   bash flatpak/install-wps-addon.sh [source-dir]

set -euo pipefail

# A user-level install lives under ~/.local/share/flatpak; a system install
# under /var/lib/flatpak. The first existing path wins.
for candidate in \
    "$HOME/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/wps-skills/wps-claude-assistant" \
    "/var/lib/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/wps-skills/wps-claude-assistant"; do
    if [ -d "$candidate" ]; then
        default_source="$candidate"
        break
    fi
done
SOURCE_DIR="${1:-${default_source:-}}"
TARGET_DIR="$HOME/.local/share/Kingsoft/wps/jsaddons/claude-assistant_"
PUBLISH_FILE="$HOME/.local/share/Kingsoft/wps/jsaddons/publish.xml"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "error: add-in source not found: $SOURCE_DIR" >&2
    echo "hint: pass the extension path explicitly, or install org.agentzero.AgentZero.Wps first" >&2
    exit 1
fi

if ! command -v wps >/dev/null 2>&1 && [ ! -d /opt/kingsoft/wps-office ]; then
    echo "error: WPS Office is not installed on this host" >&2
    echo "hint: install it from https://linux.wps.cn" >&2
    exit 1
fi

mkdir -p "$(dirname "$TARGET_DIR")"
rm -rf "$TARGET_DIR"
cp -a "$SOURCE_DIR" "$TARGET_DIR"

if [ ! -f "$PUBLISH_FILE" ]; then
    cat > "$PUBLISH_FILE" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<jsplugins>
  <jsplugin name="claude-assistant" type="wps" url="./claude-assistant_/"/>
</jsplugins>
XML
fi

echo "add-in installed: $TARGET_DIR"
echo "restart WPS Office, then start Agent Zero and open a document"
