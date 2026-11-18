#!/bin/sh
# Read-only 760K diagnosis. Writes one text file in the current directory and
# nothing else. Safe on a live USB, an emergency shell, or a running system.
# Every section keeps going when its command fails.

set -u

HOST=$(hostname 2>/dev/null || echo unknown)
HOST=$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9._-' '_')
[ -n "$HOST" ] || HOST=unknown
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="760k-diagnose-${HOST}-${STAMP}.txt"

if ! : > "$OUT" 2>/dev/null; then
    printf '01-diagnose: cannot write %s in %s\n' "$OUT" "$(pwd)" >&2
    exit 1
fi

section() {
    title=$1
    cmd=$2
    {
        printf '\n===== %s =====\n$ %s\n' "$title" "$cmd"
        sh -c "$cmd" 2>&1
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '[exit %s; continued]\n' "$rc"
        fi
    } >> "$OUT"
}

{
    printf '# 760K read-only diagnosis\n'
    printf '# host: %s\n' "$HOST"
    printf '# date: %s\n' "$(date -Iseconds 2>/dev/null || date)"
    printf '# user: %s (uid %s)\n' "$(id -un 2>/dev/null || echo unknown)" "$(id -u 2>/dev/null || echo unknown)"
    printf '# cwd: %s\n' "$(pwd)"
    printf '# this file is the only thing written\n'
    printf '# [exit N; continued] means that command failed or grep found nothing; later sections still ran.\n'
} >> "$OUT"

section 'kernel release' 'uname -r'
section 'Manjaro release' 'cat /etc/manjaro-release'
section 'addresses' 'ip -br a'
section 'NetworkManager devices' 'nmcli device status'
section 'routes' 'ip route'
section 'neighbours' 'ip neigh'
section 'boot files' 'ls /boot'
section 'grubenv' 'grub-editenv /boot/grub/grubenv list'
section 'failed units' 'systemctl --failed --no-legend'
section 'frp and agent-zero units' "systemctl list-units --all | grep -iE 'frp|agent-zero'"
section 'recent boot errors' 'journalctl -b -p err --no-pager | tail -40'
section 'nvidia and tun modules' "lsmod | grep -E 'nvidia|tun'"
section 'GPU' 'nvidia-smi --query-gpu=name,driver_version --format=csv'
section 'wireless and firmware messages' "dmesg | grep -iE 'firmware|mt79|rtw|iwlwifi' | tail -20"
section 'disk space' 'df -h / /home'
section 'flatpak version' 'flatpak --version'

LINES=$(wc -l < "$OUT" 2>/dev/null || echo '?')
printf 'wrote %s (%s lines); nothing outside this file was written\n' "$OUT" "$LINES"
