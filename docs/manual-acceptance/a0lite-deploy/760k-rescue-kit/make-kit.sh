#!/bin/sh
# Pack the rescue kit: four files + the handover, plus the two systemd support
# trees that 03-deploy.sh --with-services needs on an offline machine.
# The three .flatpak bundles are deliberately excluded; copy them separately.
#
# usage: make-kit.sh

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$HERE/../../../.." && pwd)
HANDOVER=$(CDPATH= cd -- "$HERE/.." && pwd)/760K-handover.md
OUT="$HERE/a0lite-760k-rescue-kit.tar.gz"

for file in \
    "$HERE/README.md" \
    "$HERE/01-diagnose.sh" \
    "$HERE/02-fix-boot.sh" \
    "$HERE/03-deploy.sh" \
    "$HANDOVER" \
    "$REPO_ROOT/systemd/agent-zero.service" \
    "$REPO_ROOT/systemd/agent-zero-desktop.service" \
    "$REPO_ROOT/systemd/a0-desktop-start" \
    "$REPO_ROOT/scripts/install-services.sh"
do
    [ -f "$file" ] || {
        printf 'make-kit: missing %s\n' "$file" >&2
        exit 1
    }
done

tar -czf "$OUT" \
    -C "$HERE" README.md 01-diagnose.sh 02-fix-boot.sh 03-deploy.sh \
    -C "$(dirname -- "$HANDOVER")" 760K-handover.md \
    -C "$REPO_ROOT" systemd scripts/install-services.sh

printf '== tar contents ==\n'
tar -tzf "$OUT"
printf '\n== artifact ==\n'
printf '%s\n' "$OUT"
printf 'size: %s bytes\n' "$(wc -c < "$OUT" | tr -d ' ')"
sha256sum "$OUT"
