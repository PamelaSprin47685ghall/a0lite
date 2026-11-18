#!/bin/sh
# Point GRUB at a known kernel and remove the one-shot next_entry.
#
# This script only edits /boot/grub/grubenv through grub-editenv. It never
# runs grub-mkconfig, never installs or removes packages, and never rebuilds
# initramfs. Those stay manual decisions in 760K-handover.md.
#
# On a live USB, skip chroot and point at the mounted file:
#   sudo env GRUBENV=/mnt/boot/grub/grubenv sh 02-fix-boot.sh --to old
#
# usage: 02-fix-boot.sh [--to old|new] [--dry-run]

set -eu

GRUBENV=${GRUBENV:-/boot/grub/grubenv}
OLD_ID='gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2'
NEW_ID='gnulinux-7.2.9-1-MANJARO x64-advanced-/dev/sda2'
TO=old
DRY_RUN=0

usage() {
    cat <<'EOF'
usage: 02-fix-boot.sh [--to old|new] [--dry-run]
  --to old   boot 7.3.0-rc6-1-MANJARO (default; known-good with the 615 driver)
  --to new   boot 7.2.9-1-MANJARO (only when you are testing the new kernel)
  --dry-run  print the grub-editenv commands; change nothing
EOF
}

die_usage() {
    printf '02-fix-boot: %s\n' "$*" >&2
    usage >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --to)
            [ "$#" -ge 2 ] || die_usage "--to needs old or new"
            TO=$2
            shift 2
            ;;
        --to=*)
            TO=${1#--to=}
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die_usage "unknown argument: $1"
            ;;
    esac
done

case "$TO" in
    old) ENTRY_ID=$OLD_ID ;;
    new) ENTRY_ID=$NEW_ID ;;
    *) die_usage "--to must be old or new, got: $TO" ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$GRUBENV" = /boot/grub/grubenv ] && [ -f /mnt/boot/grub/grubenv ]; then
        printf '[dry-run] note: /mnt/boot/grub/grubenv exists; on a live USB pass GRUBENV=/mnt/boot/grub/grubenv.\n'
    fi
    cat <<EOF
[dry-run] no command runs; no file changes.
would run as root:
  grub-editenv $GRUBENV list
  grub-editenv $GRUBENV unset next_entry
  grub-editenv $GRUBENV set saved_entry='$ENTRY_ID'
  grub-editenv $GRUBENV list
target: $TO
would then assert: no line starts with next_entry=, and saved_entry equals the id above.
EOF
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    printf 'run with sudo\n' >&2
    exit 1
fi

command -v grub-editenv >/dev/null 2>&1 || {
    printf '02-fix-boot: grub-editenv not found (is grub installed?)\n' >&2
    exit 1
}
if [ "$GRUBENV" = /boot/grub/grubenv ] && [ -f /mnt/boot/grub/grubenv ]; then
    printf 'REFUSING: /mnt/boot/grub/grubenv exists; you are probably on a live USB.\n' >&2
    printf 'Pass the target explicitly:\n' >&2
    printf '  sudo env GRUBENV=/mnt/boot/grub/grubenv sh %s --to old\n' "$0" >&2
    exit 1
fi
[ -f "$GRUBENV" ] || {
    printf '02-fix-boot: missing %s (live USB? mount /boot/efi and chroot first)\n' "$GRUBENV" >&2
    exit 1
}

printf '== grubenv before ==\n'
grub-editenv "$GRUBENV" list

grub-editenv "$GRUBENV" unset next_entry || {
    printf '02-fix-boot: unset next_entry failed\n' >&2
    exit 1
}
grub-editenv "$GRUBENV" set saved_entry="$ENTRY_ID" || {
    printf '02-fix-boot: set saved_entry failed\n' >&2
    exit 1
}

if ! AFTER=$(grub-editenv "$GRUBENV" list); then
    printf '02-fix-boot: cannot read grubenv back\n' >&2
    exit 1
fi
printf '== grubenv after ==\n%s\n' "$AFTER"

if printf '%s\n' "$AFTER" | grep -q '^next_entry='; then
    printf 'FAIL: next_entry is still present; do not reboot yet\n' >&2
    exit 1
fi
if ! printf '%s\n' "$AFTER" | grep -Fqx "saved_entry=$ENTRY_ID"; then
    printf 'FAIL: saved_entry does not match the requested id:\n  %s\n' "$ENTRY_ID" >&2
    exit 1
fi

printf 'OK: next_entry is gone; saved_entry=%s\n' "$TO"
