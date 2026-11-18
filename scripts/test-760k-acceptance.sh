#!/bin/sh
# Manual acceptance for the cases that only the 760K target can exercise.
#
# First run against 760K pending; paths verified against repo at commit 4d0ccd2c.
#
# Usage:
#   test-760k-acceptance.sh [--destructive] [--dry-run] [--only C53,C55] [--out DIR]
#
# Groups:
#   A  environment and NVIDIA/CUDA visibility (A1-A4)
#   B  systemd units and restart behaviour (C53-C57)
#   C  Xpra / headless desktop (C44-C48)
#   D  WPS MCP extension (C49-C52)
#   E  resources and hygiene (E1-E3)
#
# Default is read-only: C44, C47, C48, C54, C55 and C56 are skipped without
# --destructive. C44/C47 create a desktop session; C48 clears sessions; C54
# restarts the service; C55 kills the main process. C56 (reboot) additionally
# requires --only C56 and the literal confirmation string in REBOOT_CONFIRM
# (the hyphenated REBOOT-CONFIRM name is accepted with the same value):
#   REBOOT_CONFIRM=REBOOT-CONFIRM test-760k-acceptance.sh --destructive --only C56
# After the host returns, run:
#   test-760k-acceptance.sh --only C56
#
# The script writes results.json, results.md, one .log and one .cmd per case,
# plus the WPS JSON-RPC transcripts. It never edits Flatpak sources, bundles,
# pacman state, grub, or /etc. The only writes outside the output directory are
# the desktop sessions that C44/C47 create and C48 clears (after backup), the
# WPS probe's transient MCP server, and the reboot marker under $HOME.
#
# Exit status: 0 all selected cases PASS; 1 at least one FAIL; 3 no FAIL but
# at least one SKIP; 2 usage/setup error. Read results.json for the verdict.
#
# Paths verified in:
#   flatpak/a0flatpak/desktop.py
#   plugins/_desktop/api/desktop_session.py
#   plugins/_desktop/helpers/desktop_session.py
#   systemd/agent-zero.service, systemd/agent-zero-desktop.service
#   systemd/a0-desktop-start, scripts/install-services.sh
#   flatpak/wps-mcp-config.json, flatpak/wps-mcp.sh
#
set -eu

APP_ID=org.agentzero.AgentZero
APP_USER=${A0_APP_USER:-kunweiz}

die_setup() {
    printf 'test-760k-acceptance: %s\n' "$*" >&2
    exit 2
}

case "$APP_USER" in
    -*) die_setup "unsupported user name: $APP_USER" ;;
esac
case "$APP_USER" in
    *[!A-Za-z0-9._@-]*) die_setup "unsupported user name: $APP_USER" ;;
esac

ACTUAL_UID=$(id -u -- "$APP_USER") || die_setup "no such user: $APP_USER"
APP_UID=${A0_APP_UID:-$ACTUAL_UID}
case "$APP_UID" in *[!0-9]*) die_setup "bad UID: $APP_UID" ;; esac
[ "$APP_UID" = "$ACTUAL_UID" ] ||
    die_setup "A0_APP_UID=$APP_UID does not match $APP_USER ($ACTUAL_UID)"

if [ -n "${A0_HOME:-}" ]; then
    APP_HOME=$A0_HOME
elif command -v getent >/dev/null 2>&1; then
    APP_HOME=$(getent passwd "$APP_USER" | cut -d: -f6)
else
    APP_HOME=/home/$APP_USER
fi
[ -n "$APP_HOME" ] || die_setup "cannot resolve home for $APP_USER"

check_path() {
    cp_label=$1
    cp_value=$2
    case "$cp_value" in
        ''|/) die_setup "$cp_label is empty or /" ;;
        /*) ;;
        *) die_setup "$cp_label is not absolute: $cp_value" ;;
    esac
    case "$cp_value" in
        *[!A-Za-z0-9._/@+:-]*)
            die_setup "$cp_label contains unsupported characters: $cp_value"
            ;;
    esac
    case "$cp_value" in
        */) die_setup "$cp_label must not end with /: $cp_value" ;;
    esac
    case "/$cp_value/" in
        */../*) die_setup "$cp_label contains ..: $cp_value" ;;
        *"/./"*) die_setup "$cp_label contains /.: $cp_value" ;;
    esac
}

check_path APP_HOME "$APP_HOME"
APP_VAR=$APP_HOME/.var/app/$APP_ID
DATA=${A0_DATA_DIR:-$APP_VAR/data}
check_path APP_VAR "$APP_VAR"
check_path DATA "$DATA"

OUT_ROOT=${A0_OUT_ROOT:-$APP_HOME/a0-760k-acceptance}
check_path OUT_ROOT "$OUT_ROOT"

check_not_system_dir() {
    case "$1" in
        /etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|\
        /boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*|\
        /root|/home|/var|/tmp|/var/tmp)
            die_setup "$2 is a system directory: $1"
            ;;
    esac
}
check_not_system_dir "$DATA" DATA
OUT_DIR=
DESTRUCTIVE=0
DRY_RUN=0
ONLY=
LAST_STATUS=
C50_PASS=0
WPS_READY=1
CAN_ADMIN=1
A0_KEY=
A0_KEY_FOUND=0

REBOOT_MARKER=$APP_HOME/.a0-760k-acceptance-reboot-pending
check_path REBOOT_MARKER "$REBOOT_MARKER"

WPS_ROOT=${A0_WPS_ROOT:-$APP_HOME/.local/share/flatpak/app/$APP_ID.Wps/current/active/files}
check_path WPS_ROOT "$WPS_ROOT"
WPS_BUN=$WPS_ROOT/bin/bun
WPS_SERVER=$WPS_ROOT/wps-skills/wps-office-mcp/dist/index.js

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

usage() {
    cat <<'EOF'
usage: test-760k-acceptance.sh [--destructive] [--dry-run] [--only C53,C55] [--out DIR]

  --destructive  allow C44/C47 (create a desktop session), C48 (clear
                 desktop sessions and restart), C54 (systemctl restart),
                 C55 (kill -9 MainPID) and C56 (reboot).
  --dry-run      print every command; execute nothing and write nothing.
  --only LIST    comma-separated CASE IDs or groups: A, B, C, D, E,
                 C44, C45, ..., C57, E1-E3.
  --out DIR      output directory (default:
                 $APP_HOME/a0-760k-acceptance/YYYYmmdd-HHMMSS).

C56 reboot also requires --only C56 and REBOOT_CONFIRM=REBOOT-CONFIRM
(REBOOT-CONFIRM=REBOOT-CONFIRM is accepted too).
EOF
}

die_usage() {
    printf 'test-760k-acceptance: %s\n' "$*" >&2
    usage >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --destructive)
            DESTRUCTIVE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --only)
            [ "$#" -ge 2 ] || die_usage "--only needs a value"
            ONLY=$2
            shift 2
            ;;
        --out)
            [ "$#" -ge 2 ] || die_usage "--out needs a value"
            OUT_DIR=$2
            shift 2
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

ONLY=$(printf '%s' "$ONLY" | tr '[:lower:]' '[:upper:]')
if [ -z "$OUT_DIR" ]; then
    OUT_DIR=$OUT_ROOT/$(date +%Y%m%d-%H%M%S)-$$
fi
check_path OUT_DIR "$OUT_DIR"
check_not_system_dir "$OUT_DIR" OUT_DIR
[ ! -L "$OUT_DIR" ] || die_setup "OUT_DIR must not be a symlink: $OUT_DIR"

cleanup_secrets() {
    [ "${DRY_RUN:-0}" -eq 0 ] || return 0
    [ -n "${OUT_DIR:-}" ] || return 0
    rm -f "$OUT_DIR/.cookies" "$OUT_DIR"/.hdr.* "$OUT_DIR/.c45.headers.raw" 2>/dev/null || true
}
trap cleanup_secrets EXIT
trap 'exit 130' INT HUP TERM

if [ "$(id -u)" -eq 0 ] && [ "$APP_USER" != root ]; then
    FP="sudo -u $APP_USER env XDG_RUNTIME_DIR=/run/user/$APP_UID HOME=$APP_HOME flatpak"
    SC=systemctl
    JC=journalctl
    REBOOT=reboot
elif [ "$(id -u)" -eq 0 ]; then
    FP=flatpak
    SC=systemctl
    JC=journalctl
    REBOOT=reboot
else
    FP=flatpak
    SC=systemctl
    JC=journalctl
    REBOOT=
fi

if [ "$DRY_RUN" -eq 1 ]; then
    # The printed command list must show the reboot step even when this host
    # is not root; the real run resolves the sudo prefix below.
    REBOOT=reboot
fi

if [ "$DRY_RUN" -eq 0 ]; then
    for tool in flatpak curl jq awk sed grep timeout mktemp chmod stat getent id pgrep ss setsid; do
        command -v "$tool" >/dev/null 2>&1 || {
            printf 'test-760k-acceptance: missing required tool: %s\n' "$tool" >&2
            exit 2
        }
    done

    if [ "$(id -u)" -ne 0 ]; then
        if sudo -n true 2>/dev/null; then
            SC='sudo -n systemctl'
            JC='sudo -n journalctl'
            REBOOT='sudo -n reboot'
        else
            CAN_ADMIN=0
        fi
    fi
fi

selected() {
    [ -z "$ONLY" ] && return 0
    old_ifs=$IFS
    IFS=,
    for token in $ONLY; do
        if [ "$token" = "$1" ] || [ "$token" = "$2" ]; then
            IFS=$old_ifs
            return 0
        fi
    done
    IFS=$old_ifs
    return 1
}

is_destructive() {
    case "$1" in
        C44|C47|C48|C54|C55|C56) return 0 ;;
        *) return 1 ;;
    esac
}

needs_admin() {
    case "$1" in
        C48|C54|C55|C56) return 0 ;;
        *) return 1 ;;
    esac
}

group_of() {
    case "$1" in
        A*) printf 'A' ;;
        C4[4-8]) printf 'C' ;;
        C49|C5[0-2]) printf 'D' ;;
        C5[3-7]) printf 'B' ;;
        E*) printf 'E' ;;
        *) printf '?' ;;
    esac
}

record_result() {
    rr_id=$1
    rr_group=$2
    rr_desc=$3
    rr_status=$4
    rr_rc=$5
    rr_secs=$6
    rr_ev=$7
    rr_note=$8
    rr_dest=$9

    jq -cn \
        --arg id "$rr_id" \
        --arg group "$rr_group" \
        --arg description "$rr_desc" \
        --arg status "$rr_status" \
        --arg exit_code "$rr_rc" \
        --argjson seconds "$rr_secs" \
        --arg evidence "$rr_ev" \
        --arg note "$rr_note" \
        --argjson destructive "$rr_dest" \
        '{id:$id,group:$group,description:$description,status:$status,
          exit_code:$exit_code,seconds:$seconds,evidence:$evidence,
          note:$note,destructive:$destructive}' \
        >> "$OUT_DIR/results.jsonl"
}

skip_case() {
    sk_id=$1
    sk_group=$2
    sk_desc=$3
    sk_reason=$4

    selected "$sk_id" "$sk_group" || return 0
    [ "$DRY_RUN" -eq 1 ] && return 0

    printf 'SKIP %s %s (%s)\n' "$sk_id" "$sk_desc" "$sk_reason"
    sk_dest=0
    is_destructive "$sk_id" && sk_dest=1
    record_result "$sk_id" "$sk_group" "$sk_desc" SKIP '' 0 '' "$sk_reason" "$sk_dest"
    LAST_STATUS=SKIP
}

run_case() {
    rc_id=$1
    rc_desc=$2
    rc_cmd=$3
    rc_group=$(group_of "$rc_id")

    selected "$rc_id" "$rc_group" || return 0

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '\n[dry-run] %s  %s\n' "$rc_id" "$rc_desc"
        printf '%s\n' "$rc_cmd"
        return 0
    fi

    if is_destructive "$rc_id" && [ "$DESTRUCTIVE" -eq 1 ]; then
        printf 'DESTRUCTIVE %s in 3s: %s\n' "$rc_id" "$rc_desc"
        sleep 3
    fi

    printf '\n== %s %s ==\n' "$rc_id" "$rc_desc"
    printf '%s\n' "$rc_cmd" > "$OUT_DIR/$rc_id.cmd"

    rc_start=$(date +%s)
    rc_log=$OUT_DIR/$rc_id.log
    set +e
    ( set -e; eval "$rc_cmd" ) > "$rc_log" 2>&1
    rc_rc=$?
    set -e
    rc_end=$(date +%s)
    rc_secs=$((rc_end - rc_start))

    if [ "$rc_rc" -eq 0 ]; then
        rc_status=PASS
    else
        rc_status=FAIL
    fi
    printf '%s %s (%ss, %s)\n' "$rc_status" "$rc_id" "$rc_secs" "$rc_log"
    tail -n 8 "$rc_log" | sed 's/^/    /' || true

    rr_dest=0
    is_destructive "$rc_id" && rr_dest=1
    record_result "$rc_id" "$rc_group" "$rc_desc" "$rc_status" "$rc_rc" "$rc_secs" "$rc_id.log" '' "$rr_dest"
    LAST_STATUS=$rc_status
}

run_dispatch() {
    rd_id=$1
    rd_group=$2
    rd_desc=$3
    rd_cmd=$4

    selected "$rd_id" "$rd_group" || return 0

    if [ "$DRY_RUN" -eq 0 ]; then
        case "$rd_id" in
            C50|C51|C52)
                if [ "$WPS_READY" -eq 0 ]; then
                    skip_case "$rd_id" "$rd_group" "$rd_desc" 'WPS extension not installed'
                    return 0
                fi
                ;;
        esac
        if is_destructive "$rd_id" && [ "$DESTRUCTIVE" -eq 0 ]; then
            skip_case "$rd_id" "$rd_group" "$rd_desc" 'needs --destructive'
            return 0
        fi
        if needs_admin "$rd_id" && [ "$CAN_ADMIN" -eq 0 ]; then
            skip_case "$rd_id" "$rd_group" "$rd_desc" 'needs root or passwordless sudo'
            return 0
        fi
    fi

    run_case "$rd_id" "$rd_desc" "$rd_cmd"
}

# ---------------------------------------------------------------------------
# Command builders. They only produce text; run_case executes the text with
# eval so helper functions and variables stay visible.

cmd_a1() {
    cat <<'EOF'
uname -r
nproc
free -g
if ls /dev/nvidia* >/dev/null 2>&1; then
    echo 'NVIDIA_DEVICES:'
    ls -l /dev/nvidia*
else
    echo 'NVIDIA_DEVICES: none'
    exit 1
fi
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
EOF
}

cmd_a2() {
    cat <<EOF
$FP run --user --command=sh $APP_ID -c 'ls /dev/nvidia* 2>/dev/null; nvidia-smi -L 2>&1 | head -2' > "$OUT_DIR/A2.sandbox.log" 2>&1 || true
cat "$OUT_DIR/A2.sandbox.log"
grep -q 'GPU 0:' "$OUT_DIR/A2.sandbox.log"
EOF
}

cmd_a3() {
    cat <<EOF
$FP list --user --columns=application,commit 2>&1 | grep -i 'AgentZero.Cuda' || { echo 'Cuda extension not installed'; exit 1; }
$FP run --user --command=sh ${APP_ID}.Cuda -c 'for p in /app/cuda /app/share/agent-zero/cuda; do if [ -d "\$p/cuda_v12" ]; then echo "CUDA_ROOT=\$p"; ls -l "\$p/cuda_v12" | head -5; find "\$p/cuda_v12" -maxdepth 1 -name "*.so*" | head -3; exit 0; fi; done; echo "cuda_v12 not found in extension"; exit 1' > "$OUT_DIR/A3.ext.log" 2>&1 || true
cat "$OUT_DIR/A3.ext.log"
$FP run --user --command=sh $APP_ID -c 'for p in /app/share/agent-zero/cuda /app/cuda; do if [ -d "\$p/cuda_v12" ]; then echo "CUDA_ROOT=\$p"; ls -l "\$p/cuda_v12" | head -5; find "\$p/cuda_v12" -maxdepth 1 -name "*.so*" | head -3; exit 0; fi; done; echo "cuda_v12 not found in app"; exit 1' > "$OUT_DIR/A3.app.log" 2>&1
cat "$OUT_DIR/A3.app.log"
grep -q 'CUDA_ROOT=' "$OUT_DIR/A3.app.log"
grep -q '\.so' "$OUT_DIR/A3.app.log"
$FP run --user --command=sh $APP_ID -c 'ls /dev/nvidia* >/dev/null 2>&1 && echo GPU_DEVICE_OK' > "$OUT_DIR/A3.gpu.log" 2>&1 || true
cat "$OUT_DIR/A3.gpu.log"
grep -q 'GPU_DEVICE_OK' "$OUT_DIR/A3.gpu.log"
EOF
}

cmd_a4() {
    cat <<EOF
for f in "$DATA/agent-zero/ollama.log" "$DATA/ollama.log"; do
    if [ -f "\$f" ]; then
        echo "== \$f =="
        tail -30 "\$f"
    fi
done
grep -R --include='*.log' -m5 -E 'library=(cuda|rocm)|inference compute' "$DATA" 2>/dev/null | tail -5 || true
if [ -f "$DATA/agent-zero/ollama.log" ]; then
    grep -E 'library=cuda|inference compute.*(CUDA|cuda)' "$DATA/agent-zero/ollama.log" | tail -5 || true
fi
grep -Eq 'library=cuda|inference compute.*(CUDA|cuda)' "$DATA/agent-zero/ollama.log"
EOF
}

cmd_c53() {
    cat <<EOF
bad=0
for u in agent-zero.service agent-zero-desktop.service; do
    e=\$($SC is-enabled "\$u" 2>&1 || true)
    a=\$($SC is-active "\$u" 2>&1 || true)
    echo "\$u enabled=\$e active=\$a"
    [ "\$e" = enabled ] || bad=1
    [ "\$a" = active ] || bad=1
done
$SC cat agent-zero.service agent-zero-desktop.service 2>&1 | grep -E '^(ExecStart|Restart)=' || bad=1
if command -v systemd-analyze >/dev/null 2>&1; then
    if ! verify=\$(systemd-analyze verify /etc/systemd/system/agent-zero.service /etc/systemd/system/agent-zero-desktop.service 2>&1); then
        bad=1
    fi
else
    verify='systemd-analyze not found'
    bad=1
fi
printf '%s\n' "\$verify"
[ "\$bad" -eq 0 ]
EOF
}

cmd_c54() {
    cat <<EOF
$SC is-enabled --quiet agent-zero.service || { echo 'agent-zero.service is not enabled'; exit 2; }
$SC is-active --quiet agent-zero.service || { echo 'agent-zero.service is not active'; exit 2; }
start=\$(date +%s)
$SC restart agent-zero.service
i=0
code=000
while [ "\$i" -lt 120 ]; do
    code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:5080/api/health || true)
    [ "\$code" = 200 ] && break
    i=\$((i + 1))
    sleep 2
done
elapsed=\$(( \$(date +%s) - start ))
echo "HTTP=\$code elapsed=\${elapsed}s"
$SC is-active agent-zero.service
[ "\$code" = 200 ] && [ "\$elapsed" -le 240 ] && $SC is-active --quiet agent-zero.service
EOF
}

cmd_c55() {
    cat <<EOF
$SC is-enabled --quiet agent-zero.service || { echo 'agent-zero.service is not enabled'; exit 2; }
$SC is-active --quiet agent-zero.service || { echo 'agent-zero.service is not active'; exit 2; }
old=\$($SC show -p MainPID --value agent-zero.service | tr -d '[:space:]')
echo "OLD_PID=\$old"
[ -n "\$old" ] && [ "\$old" != 0 ] || exit 1
$SC kill -s KILL agent-zero.service
i=0
new=
code=000
while [ "\$i" -lt 45 ]; do
    new=\$($SC show -p MainPID --value agent-zero.service | tr -d '[:space:]' || true)
    code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:5080/api/health || true)
    if [ -n "\$new" ] && [ "\$new" != 0 ] && [ "\$new" != "\$old" ] && [ "\$code" = 200 ]; then
        break
    fi
    i=\$((i + 1))
    sleep 2
done
echo "NEW_PID=\$new HTTP=\$code waited=\$((i * 2))s"
$SC is-active agent-zero.service
$JC -u agent-zero -n 20 --no-pager 2>/dev/null | tail -20 || true
[ -n "\$new" ] && [ "\$new" != 0 ] && [ "\$new" != "\$old" ] && [ "\$code" = 200 ] && $SC is-active --quiet agent-zero.service
EOF
}

cmd_c56_post() {
    cat <<EOF
old_boot=\$(sed -n 's/^boot_id=//p' "$REBOOT_MARKER" | head -1)
new_boot=\$(cat /proc/sys/kernel/random/boot_id)
echo "OLD_BOOT=\$old_boot NEW_BOOT=\$new_boot"
[ -n "\$old_boot" ] && [ "\$old_boot" != "\$new_boot" ] || { echo 'boot_id unchanged or marker missing' >&2; exit 1; }
i=0
a=
d=
code=000
while [ "\$i" -lt 120 ]; do
    a=\$($SC is-active agent-zero.service 2>&1 || true)
    d=\$($SC is-active agent-zero-desktop.service 2>&1 || true)
    code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:5080/api/health || true)
    [ "\$a" = active ] && [ "\$d" = active ] && [ "\$code" = 200 ] && break
    i=\$((i + 1))
    sleep 2
done
echo "agent-zero=\$a agent-zero-desktop=\$d HTTP=\$code waited=\$((i * 2))s"
uptime -p 2>/dev/null || uptime || true
[ "\$a" = active ] && [ "\$d" = active ] && [ "\$code" = 200 ]
EOF
}

cmd_c56_reboot() {
    cat <<EOF
# requires --destructive --only C56 and REBOOT_CONFIRM=REBOOT-CONFIRM
printf 'boot_id=%s\\n' "\$(cat /proc/sys/kernel/random/boot_id)" > "$REBOOT_MARKER"
sync
$REBOOT
EOF
}

cmd_c57() {
    cat <<EOF
$JC -u agent-zero -n 200 --no-pager > "$OUT_DIR/journal-C57.txt" 2>&1 || true
tail -40 "$OUT_DIR/journal-C57.txt"
grep -E 'Scheduled restart|Restarting|Started Agent Zero|Stopped Agent Zero' "$OUT_DIR/journal-C57.txt" | tail -20
grep -qE 'Scheduled restart|Restarting|Started Agent Zero|Stopped Agent Zero' "$OUT_DIR/journal-C57.txt"
EOF
}

desktop_api_cmd() {
    d_out=$1
    cat <<EOF
umask 077
jar="$OUT_DIR/.cookies"
hdr="\$(mktemp "$OUT_DIR/.hdr.XXXXXX")" || exit 1
chmod 600 "\$hdr"
trap 'rm -f "\$hdr"' EXIT HUP INT TERM
rm -f "\$jar"
if [ -n "\${A0_KEY:-}" ]; then
    printf 'X-API-Key: %s\n' "\$A0_KEY" > "\$hdr"
    csrf=\$(curl -sS --max-time 10 -c "\$jar" -b "\$jar" -H 'Origin: http://127.0.0.1:5080' -H @"\$hdr" http://127.0.0.1:5080/api/csrf_token)
else
    csrf=\$(curl -sS --max-time 10 -c "\$jar" -b "\$jar" -H 'Origin: http://127.0.0.1:5080' http://127.0.0.1:5080/api/csrf_token)
fi
printf '%s\n' "\$csrf" | sed -E 's/("token"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"<redacted>"/'
token=\$(printf '%s' "\$csrf" | jq -r '.token // empty')
[ -n "\$token" ] || { echo 'no CSRF token from /api/csrf_token'; exit 1; }
if [ -n "\${A0_KEY:-}" ]; then
    {
        printf 'X-API-Key: %s\n' "\$A0_KEY"
        printf 'X-CSRF-Token: %s\n' "\$token"
    } > "\$hdr"
else
    printf 'X-CSRF-Token: %s\n' "\$token" > "\$hdr"
fi
raw=\$(curl -sS --max-time 180 -c "\$jar" -b "\$jar" -H 'Origin: http://127.0.0.1:5080' -H 'Content-Type: application/json' -H @"\$hdr" -d '{"action":"desktop"}' http://127.0.0.1:5080/api/plugins/_desktop/desktop_session)
if printf '%s' "\$raw" | jq -e . >/dev/null 2>&1; then
    printf '%s' "\$raw" | jq 'if .desktop then .desktop |= (del(.token) | .url = ((.url // "") | sub("[?#].*$"; "?<redacted>"))) else . end' > "$d_out"
    cat "$d_out"
else
    printf '{"error":"non-JSON response from desktop API"}\n' > "$d_out"
    cat "$d_out"
    exit 1
fi
EOF
}

cmd_c44() {
    cat <<EOF
$(desktop_api_cmd "$OUT_DIR/C44.json")
jq -e '.ok == true and .desktop.available == true and ((.desktop.url // "") | length > 0)' "$OUT_DIR/C44.json" >/dev/null
jq -c '.desktop | {available, session_id, display, url}' "$OUT_DIR/C44.json"
EOF
}

cmd_c45() {
    cat <<EOF
raw_headers="$OUT_DIR/.c45.headers.raw"
umask 077
: > "\$raw_headers"
code=\$(curl -sS -o "$OUT_DIR/C45.body" -D "\$raw_headers" -w '%{http_code}' --max-time 10 http://127.0.0.1:14500/ || true)
sed -E 's/^(Set-Cookie|Authorization|Proxy-Authorization|X-Auth-Token|X-Xpra-Auth):.*/\1: <redacted>/I' "\$raw_headers" > "$OUT_DIR/C45.headers"
rm -f "\$raw_headers"
echo "HTTP=\$code"
cat "$OUT_DIR/C45.headers"
grep -i 'server:.*Xpra-WebSocket-Server' "$OUT_DIR/C45.headers"
[ "\$code" = 200 ]
grep -ci xpra "$OUT_DIR/C45.body"
EOF
}

cmd_c46() {
    cat <<EOF
pgrep -af 'xpra|Xvfb' 2>/dev/null | sed -E 's/(--password[= ])[^ ]+/\1<redacted>/g; s/(XPRA_PASSWORD=)[^ ]+/\1<redacted>/g' > "$OUT_DIR/C46.ps.txt" || true
cat "$OUT_DIR/C46.ps.txt"
grep -q 'Xvfb-for-Xpra-120' "$OUT_DIR/C46.ps.txt"
grep -q 'start-desktop :120' "$OUT_DIR/C46.ps.txt"
if [ -n "\${A0_KEY:-}" ]; then
    grep -q -- '--tcp-auth=env' "$OUT_DIR/C46.ps.txt"
else
    echo 'A0_AUTH_KEY is unset; headless xpra has no --tcp-auth=env'
    exit 1
fi
if grep -q -- '--mmap=no' "$OUT_DIR/C46.ps.txt"; then
    echo 'found --mmap=no in xpra command line'
    exit 1
fi
echo C46_OK
EOF
}

cmd_c47() {
    cat <<EOF
$FP run --user --command=sh $APP_ID -s > "$OUT_DIR/C47.sandbox.log" 2>&1 <<'A0INNER'
set -eu
unset DISPLAY
export LD_LIBRARY_PATH=/app/lib/gi:/app/lib/xvfb
B="\$HOME/.var/app/$APP_ID/data/agent-zero"
export A0_BASE_DIR="\$B"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps "\$B/venv/bin/python" - <<'A0PY'
import os, shutil
import a0flatpak
a0flatpak.apply()
from a0flatpak import desktop
print("DISPLAY=" + repr(os.environ.get("DISPLAY")))
try:
    host = desktop._host_display()
    print("host_display=" + repr(host))
except Exception as exc:
    print("host_display_error=" + type(exc).__name__ + ": " + str(exc))
print("BUNDLED_XVFB_exists=" + str(os.path.isfile(desktop.BUNDLED_XVFB)))
print("xpra_bin_exists=" + str(os.path.isfile("/app/bin/xpra")))
print("xpra_which=" + (shutil.which("xpra") or ""))
print("XVFB_OK")
A0PY
A0INNER
cat "$OUT_DIR/C47.sandbox.log"
grep -q 'XVFB_OK' "$OUT_DIR/C47.sandbox.log"
grep -q 'BUNDLED_XVFB_exists=True' "$OUT_DIR/C47.sandbox.log"
grep -q 'xpra_bin_exists=True' "$OUT_DIR/C47.sandbox.log"
grep -Eq "host_display=(''|None|:[0-9]+)|host_display_error=.*No desktop to share" "$OUT_DIR/C47.sandbox.log"
$(desktop_api_cmd "$OUT_DIR/C47.json")
jq -e '.desktop.available == true and .desktop.display == ":120" and ((.desktop.url // "") | length > 0)' "$OUT_DIR/C47.json" >/dev/null
jq -c '.desktop | {available, display, url}' "$OUT_DIR/C47.json"
EOF
}

cmd_c48() {
    cat <<EOF
sessions="$DATA/agent-zero/usr/plugins/_desktop/sessions"
backup="$OUT_DIR/backup/sessions"
case "\$sessions" in
    "$DATA"/agent-zero/usr/plugins/_desktop/sessions) ;;
    *) echo "unexpected sessions path: \$sessions" >&2; exit 1 ;;
esac
mkdir -p "\$backup"
if [ -d "\$sessions" ]; then
    cp -a "\$sessions/." "\$backup/" || { echo "backup failed: \$sessions" >&2; exit 1; }
    find "\$sessions" -maxdepth 1 -type f -name '*.json' -delete || { echo "clear failed: \$sessions" >&2; exit 1; }
fi
echo "cleared sessions; backup at \$backup"
if $SC is-active --quiet agent-zero.service 2>/dev/null; then
    $SC restart agent-zero.service
else
    $FP kill $APP_ID 2>/dev/null || true
    i=0
    while [ "\$i" -lt 10 ]; do
        if ! $FP ps 2>/dev/null | awk -v id="$APP_ID" '\$3 == id { found=1 } END { exit !found }'; then
            break
        fi
        i=\$((i + 1))
        sleep 1
    done
    if $FP ps 2>/dev/null | awk -v id="$APP_ID" '\$3 == id { found=1 } END { exit !found }'; then
        echo "old flatpak instance is still running; refusing to start a second" >&2
        exit 1
    fi
    setsid $FP run --user $APP_ID > "$OUT_DIR/app-restart.log" 2>&1 </dev/null &
fi
i=0
code=000
while [ "\$i" -lt 120 ]; do
    code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:5080/api/health || true)
    [ "\$code" = 200 ] && break
    i=\$((i + 1))
    sleep 2
done
echo "HTTP=\$code after restart"
[ "\$code" = 200 ] || exit 1
if $SC cat agent-zero-desktop.service >/dev/null 2>&1; then
    $SC restart agent-zero-desktop.service
fi
$(desktop_api_cmd "$OUT_DIR/C48.json")
jq -e '.desktop.available == true and .desktop.display == ":120" and ((.desktop.url // "") | length > 0)' "$OUT_DIR/C48.json" >/dev/null
jq -c '.desktop | {available, display, url}' "$OUT_DIR/C48.json"
i=0
while [ "\$i" -lt 30 ]; do
    if pgrep -af 'Xvfb-for-Xpra-120' >/dev/null 2>&1 && pgrep -af 'start-desktop :120' >/dev/null 2>&1; then
        break
    fi
    i=\$((i + 1))
    sleep 2
done
pgrep -af 'Xvfb-for-Xpra-120|start-desktop :120' || true
pgrep -af 'Xvfb-for-Xpra-120' >/dev/null
pgrep -af 'start-desktop :120' >/dev/null
echo "RESTORE: cp -a '\$backup/.' '\$sessions/'"
EOF
}

cmd_c49() {
    cat <<EOF
ext_list=\$($FP list --user --columns=application,branch,commit 2>&1)
case "\$ext_list" in
    *'Unknown column'*) ext_list=\$($FP list --user --columns=application,branch 2>&1) ;;
esac
printf '%s\n' "\$ext_list" | grep -i wps || true
printf '%s\n' "\$ext_list" | grep -q '${APP_ID}.Wps' || { echo 'WPS extension not installed'; exit 1; }
cfg=
for f in "$DATA/agent-zero/usr/settings.json" "$APP_VAR/config/wps-mcp-config.json" "$DATA/config/wps-mcp-config.json"; do
    [ -f "\$f" ] || continue
    if jq -e '.mcpServers["wps-office"]' "\$f" >/dev/null 2>&1 || jq -e '.mcp_servers' "\$f" >/dev/null 2>&1; then
        cfg=\$f
        break
    fi
done
if [ -z "\$cfg" ]; then
    echo "WPS MCP runtime config not found; checked $DATA/agent-zero/usr/settings.json and $APP_VAR/config/wps-mcp-config.json"
    if [ -f "$REPO/flatpak/wps-mcp-config.json" ]; then
        echo "repo template exists but is not runtime state: $REPO/flatpak/wps-mcp-config.json"
    fi
    exit 1
fi
echo "config=\$cfg"
if jq -e '.mcp_servers | type == "string"' "\$cfg" >/dev/null 2>&1; then
    jq -r '.mcp_servers | fromjson | .mcpServers["wps-office"] | {command, args}' "\$cfg" > "$OUT_DIR/C49.server.json"
else
    jq -r '.mcpServers["wps-office"] | {command, args}' "\$cfg" > "$OUT_DIR/C49.server.json"
fi
cat "$OUT_DIR/C49.server.json"
jq -e '.command | endswith("flatpak-spawn")' "$OUT_DIR/C49.server.json" >/dev/null
jq -e '(.args | index("--watch-bus")) != null' "$OUT_DIR/C49.server.json" >/dev/null
jq -e '(.args | index("--host")) != null' "$OUT_DIR/C49.server.json" >/dev/null
jq -e '(.args | index("--directory=/")) != null' "$OUT_DIR/C49.server.json" >/dev/null
if jq -r '.command, (.args[])' "$OUT_DIR/C49.server.json" | grep -Eq '/var/lib/flatpak|/bin/node'; then
    echo 'config points at a system path or bin/node'
    exit 1
fi
bun=\$(jq -r '.args[-2]' "$OUT_DIR/C49.server.json")
server=\$(jq -r '.args[-1]' "$OUT_DIR/C49.server.json")
echo "bun=\$bun server=\$server"
[ -r "\$bun" ] && [ -x "\$bun" ] || { echo "bun is not executable: \$bun" >&2; exit 1; }
[ -r "\$server" ] || { echo "server is not readable: \$server" >&2; exit 1; }
$FP run --user --command=sh $APP_ID -c 'test -x /usr/bin/flatpak-spawn && echo FLATPAK_SPAWN_OK'
echo CMD_OK
EOF
}

wps_handshake() {
    wh_out=$1
    wh_in=$OUT_DIR/wps-handshake.in
    {
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"a0-760k","version":"1.0"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    } > "$wh_in"
    wh_rc=0
    timeout --kill-after=5 45 $FP run --user --command=sh "$APP_ID" -c "exec /usr/bin/flatpak-spawn --directory=/ --watch-bus --host $WPS_BUN $WPS_SERVER" < "$wh_in" > "$wh_out" 2> "$wh_out.err" || wh_rc=$?
    cat "$wh_out.err" >&2
    cat "$wh_out"
    # The stdio server may stay alive after the last reply; timeout 124 is not
    # a handshake failure when the expected JSON-RPC line is present.
    echo "wrapper_rc=$wh_rc (124 means the server stayed alive after replying)"
    return 0
}

wps_call_check() {
    wc_out=$1
    wc_in=$OUT_DIR/wps-call.in
    {
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"a0-760k","version":"1.0"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wps_check_connection","arguments":{}}}'
    } > "$wc_in"
    wc_rc=0
    timeout --kill-after=5 45 $FP run --user --command=sh "$APP_ID" -c "exec /usr/bin/flatpak-spawn --directory=/ --watch-bus --host $WPS_BUN $WPS_SERVER" < "$wc_in" > "$wc_out" 2> "$wc_out.err" || wc_rc=$?
    cat "$wc_out.err" >&2
    cat "$wc_out"
    # wps_check_connection takes about 30 s when no WPS is running. The server
    # then waits for more input, so the wrapper is killed at 45 s. The reply is
    # already on stdout; C52 asserts the structured result, not the wrapper rc.
    echo "wrapper_rc=$wc_rc (124 means the server stayed alive after replying)"
    return 0
}

cmd_c50() {
    cat <<EOF
echo 'WPS MCP transport: stdio via flatpak-spawn (flatpak/wps-mcp.sh); no HTTP endpoint'
wps_handshake "$OUT_DIR/C50.jsonl" || exit \$?
jq -s -e 'map(select(.id==1))[0].result.serverInfo.name == "wps-office-mcp"' "$OUT_DIR/C50.jsonl" >/dev/null
jq -s -e 'map(select(.id==1))[0].result.protocolVersion | length > 0' "$OUT_DIR/C50.jsonl" >/dev/null
jq -s -c 'map(select(.id==1))[0].result | {protocolVersion, serverInfo}' "$OUT_DIR/C50.jsonl"
EOF
}

cmd_c51() {
    cat <<EOF
if [ "$C50_PASS" -eq 1 ] && [ -s "$OUT_DIR/C50.jsonl" ]; then
    h="$OUT_DIR/C50.jsonl"
else
    wps_handshake "$OUT_DIR/C51.jsonl" || exit \$?
    h="$OUT_DIR/C51.jsonl"
fi
count=\$(jq -s 'map(select(.id==2))[0].result.tools | length' "\$h")
echo "tool_count=\$count"
case "\$count" in
    ''|*[!0-9]*) exit 1 ;;
esac
[ "\$count" -gt 200 ]
jq -s -e 'map(select(.id==2))[0].result.tools | map(.name) | index("wps_check_connection") != null' "\$h" >/dev/null
jq -s -r 'map(select(.id==2))[0].result.tools | map(.name) | .[0:8][]' "\$h"
EOF
}

cmd_c52() {
    cat <<EOF
echo 'WPS MCP transport: stdio via flatpak-spawn (flatpak/wps-mcp.sh); no HTTP endpoint'
wps_call_check "$OUT_DIR/C52.jsonl" || exit \$?
jq -s -e 'map(select(.id==2))[0].result | ((.content | type) == "array" and (.content | length) > 0) and ((.isError | type) == "boolean") and (((.content[0].text // "") | length) > 0)' "$OUT_DIR/C52.jsonl" >/dev/null
jq -s -c 'map(select(.id==2))[0].result | {isError, text: (.content[0].text // "")}' "$OUT_DIR/C52.jsonl"
EOF
}

cmd_e1() {
    cat <<EOF
$FP ps > "$OUT_DIR/E1.flatpak-ps.txt" 2>&1 || true
cat "$OUT_DIR/E1.flatpak-ps.txt"
n=\$($FP ps 2>/dev/null | awk '\$3 == "$APP_ID" { c++ } END { print c + 0 }')
u=\$(pgrep -fc 'run_ui.py' 2>/dev/null || true)
echo "flatpak_entries=\$n run_ui=\$u"
ss -ltnp 2>/dev/null | grep -E ':(5080|11434|11450|14500)\b' || true
[ "\$n" -ge 1 ]
[ "\$u" -eq 1 ]
ss -ltn 2>/dev/null | grep -qE ':5080\b'
ss -ltn 2>/dev/null | grep -qE ':11434\b'
EOF
}

cmd_e2() {
    cat <<EOF
df -h /home /var
du -sh "$APP_VAR"
EOF
}

cmd_e3() {
    cat <<EOF
raw_override=\$($FP override --user --show $APP_ID 2>&1) || {
    printf '%s\n' "\$raw_override" | sed -E 's/(A0_AUTH_KEY=).*/\1<redacted>/'
    exit 1
}
printf '%s\n' "\$raw_override" | sed -E 's/(A0_AUTH_KEY=).*/\1<redacted>/'
EOF
}

# ---------------------------------------------------------------------------
# Runtime setup that must not run for --dry-run.

if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$OUT_DIR"
    [ ! -L "$OUT_DIR" ] || die_setup "OUT_DIR became a symlink: $OUT_DIR"
    OUT_OWNER=$(stat -c %u "$OUT_DIR") || die_setup "cannot stat OUT_DIR: $OUT_DIR"
    [ "$OUT_OWNER" = "$(id -u)" ] ||
        die_setup "OUT_DIR is not owned by the current user: $OUT_DIR"
    chmod 700 "$OUT_DIR"
    : > "$OUT_DIR/results.jsonl"

    read_auth_key() {
        k=
        if [ -n "${A0_AUTH_KEY:-}" ]; then
            k=$A0_AUTH_KEY
        fi
        if [ -z "$k" ]; then
            k=$($FP override --user --show "$APP_ID" 2>/dev/null | sed -n 's/^A0_AUTH_KEY=//p' | head -1 || true)
        fi
        if [ -z "$k" ] && [ -f "$DATA/agent-zero/usr/.env" ]; then
            k=$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?A0_AUTH_KEY=//p' "$DATA/agent-zero/usr/.env" | head -1 | tr -d '"' | tr -d "'" || true)
        fi
        k=$(printf '%s' "$k" | tr -d '\r\n')
        printf '%s' "$k"
    }

    A0_KEY=$(read_auth_key)
    if [ -n "$A0_KEY" ]; then
        A0_KEY_FOUND=1
    fi

    if ! $FP list --user --columns=application 2>/dev/null | grep -q "${APP_ID}.Wps"; then
        WPS_READY=0
    fi
else
    A0_KEY='<A0_AUTH_KEY if configured>'
    A0_KEY_FOUND='unknown (dry-run)'
fi

# ---------------------------------------------------------------------------
# Case table.

run_dispatch A1 A 'host kernel, CPU, RAM and NVIDIA devices' "$(cmd_a1)"
run_dispatch A2 A 'NVIDIA devices and nvidia-smi inside the app sandbox' "$(cmd_a2)"
run_dispatch A3 A 'Cuda extension mounted and NVIDIA devices visible in the app' "$(cmd_a3)"
run_dispatch A4 A 'CUDA library evidence in the Ollama log' "$(cmd_a4)"

run_dispatch C53 B 'systemd units enabled, active, verify and unit fields' "$(cmd_c53)"
run_dispatch C54 B 'systemctl restart agent-zero: health 200 within 240 s' "$(cmd_c54)"
run_dispatch C55 B 'kill -9 MainPID: Restart=always gives a new PID and health 200' "$(cmd_c55)"

# C56 is special: the first invocation only records the reboot marker.
if selected C56 B; then
    if [ -f "$REBOOT_MARKER" ]; then
        run_case C56 'after reboot: both units active and health 200' "$(cmd_c56_post)"
        if [ "${LAST_STATUS:-}" = PASS ]; then
            if [ "$DRY_RUN" -eq 0 ]; then
                mv "$REBOOT_MARKER" "$OUT_DIR/C56.marker"
            fi
        fi
    elif [ "$DRY_RUN" -eq 1 ]; then
        printf '\n[dry-run] C56  reboot; requires --destructive --only C56 and REBOOT_CONFIRM=REBOOT-CONFIRM\n'
        printf '%s\n' "$(cmd_c56_reboot)"
    elif [ "$DESTRUCTIVE" -eq 0 ]; then
        skip_case C56 B 'reboot and post-reboot unit check' 'needs --destructive'
    elif [ "$CAN_ADMIN" -eq 0 ]; then
        skip_case C56 B 'reboot and post-reboot unit check' 'needs root or passwordless sudo'
    elif [ "$ONLY" != 'C56' ]; then
        skip_case C56 B 'reboot and post-reboot unit check' 'reboot requires --only C56'
    elif ! $SC is-enabled --quiet agent-zero.service 2>/dev/null || ! $SC is-enabled --quiet agent-zero-desktop.service 2>/dev/null; then
        skip_case C56 B 'reboot and post-reboot unit check' 'precondition: both units must be enabled'
    else
        confirm=${REBOOT_CONFIRM:-}
        if [ -z "$confirm" ]; then
            confirm=$(printenv 'REBOOT-CONFIRM' 2>/dev/null || true)
        fi
        if [ "$confirm" != 'REBOOT-CONFIRM' ]; then
            skip_case C56 B 'reboot and post-reboot unit check' 'REBOOT_CONFIRM=REBOOT-CONFIRM not set'
        else
            printf 'DESTRUCTIVE C56 in 3s: reboot the host\n'
            sleep 3
            {
                printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
                printf 'issued=%s\n' "$(date -Is 2>/dev/null || date)"
            } > "$REBOOT_MARKER"
            cp "$REBOOT_MARKER" "$OUT_DIR/C56.reboot-marker" 2>/dev/null || true
            record_result C56 B 'reboot and post-reboot unit check' SKIP '' 0 'C56.reboot-marker' 'reboot issued; rerun --only C56 after the host returns' 1
            LAST_STATUS=SKIP
            sync
            printf 'rebooting now; rerun --only C56 after the host returns\n'
            $REBOOT
        fi
    fi
elif [ "$DRY_RUN" -eq 0 ]; then
    :
fi

run_dispatch C57 B 'journal contains start/stop/restart lines' "$(cmd_c57)"

run_dispatch C44 C 'desktop API returns available:true and a url' "$(cmd_c44)"
run_dispatch C45 C 'Xpra HTML5 page on 14500 returns 200 and Xpra-WebSocket-Server' "$(cmd_c45)"
run_dispatch C46 C 'headless Xvfb :120 with --tcp-auth=env and no --mmap=no' "$(cmd_c46)"
run_dispatch C47 C 'headless fallback with DISPLAY unset returns :120' "$(cmd_c47)"
run_dispatch C48 C 'clear desktop sessions, restart, recreate :120 and start-desktop' "$(cmd_c48)"

run_dispatch C49 D 'WPS extension installed and runtime MCP config points at flatpak-spawn --host' "$(cmd_c49)"
C50_PASS=0
run_dispatch C50 D 'WPS MCP initialize handshake' "$(cmd_c50)"
if selected C50 D && [ "$DRY_RUN" -eq 0 ] && [ "${LAST_STATUS:-}" = PASS ]; then
    C50_PASS=1
fi
run_dispatch C51 D 'WPS MCP tools/list has more than 200 tools' "$(cmd_c51)"
run_dispatch C52 D 'WPS wps_check_connection returns a structured result without crashing' "$(cmd_c52)"

run_dispatch E1 E 'one run_ui.py, flatpak entries and listening ports' "$(cmd_e1)"
run_dispatch E2 E 'disk space and app data size' "$(cmd_e2)"
run_dispatch E3 E 'flatpak user override (recorded, no assertion)' "$(cmd_e3)"

# ---------------------------------------------------------------------------
# Reports.

if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n[dry-run] WPS MCP helpers used by C50/C51/C52:\n'
    cat <<EOF
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"a0-760k","version":"1.0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | timeout --kill-after=5 45 $FP run --user --command=sh $APP_ID -c "exec /usr/bin/flatpak-spawn --directory=/ --watch-bus --host $WPS_BUN $WPS_SERVER"
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"a0-760k","version":"1.0"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wps_check_connection","arguments":{}}}' | timeout --kill-after=5 45 $FP run --user --command=sh $APP_ID -c "exec /usr/bin/flatpak-spawn --directory=/ --watch-bus --host $WPS_BUN $WPS_SERVER"
EOF
    printf '\n[dry-run] A0_AUTH_KEY: %s\n' "$A0_KEY_FOUND"
    printf '[dry-run] no files written; would use %s\n' "$OUT_DIR"
    exit 0
fi

if [ ! -s "$OUT_DIR/results.jsonl" ]; then
    printf 'test-760k-acceptance: no cases selected\n' >&2
    exit 2
fi

jq -s '.' "$OUT_DIR/results.jsonl" > "$OUT_DIR/results.json"

{
    printf '# a0lite 760K acceptance\n\n'
    printf -- '- date: %s\n' "$(date -Is 2>/dev/null || date)"
    printf -- '- host: %s %s\n' "$(uname -n)" "$(uname -r)"
    printf -- '- destructive: %s\n' "$DESTRUCTIVE"
    printf -- '- only: %s\n' "${ONLY:-<all>}"
    printf -- '- A0_AUTH_KEY found: %s\n' "$A0_KEY_FOUND"
    printf -- '- output: %s\n\n' "$OUT_DIR"
    printf '| CASE | group | status | seconds | evidence |\n'
    printf '|---|---|---|---:|---|\n'
    jq -r '[.id, .group, .status, (.seconds|tostring), .evidence] | @tsv' "$OUT_DIR/results.jsonl" |
        while IFS="$(printf '\t')" read -r id group status secs ev; do
            printf '| %s | %s | %s | %s | %s |\n' "$id" "$group" "$status" "$secs" "${ev:-—}"
        done
    printf '\n## Non-pass details\n\n'
    jq -r 'select(.status != "PASS") | .id' "$OUT_DIR/results.jsonl" |
        while read -r id; do
            note=$(jq -r --arg id "$id" 'select(.id == $id) | .note' "$OUT_DIR/results.jsonl")
            status=$(jq -r --arg id "$id" 'select(.id == $id) | .status' "$OUT_DIR/results.jsonl")
            printf '### %s %s\n\n' "$id" "$status"
            if [ -n "$note" ]; then
                printf '%s\n\n' "$note"
            fi
            if [ -f "$OUT_DIR/$id.log" ]; then
                printf '```\n'
                tail -n 30 "$OUT_DIR/$id.log"
                printf '```\n\n'
            fi
        done
} > "$OUT_DIR/results.md"

rm -f "$OUT_DIR/.cookies"

printf '\n== summary ==\n'
jq -s -r 'group_by(.status)[] | "\(.[0].status): \(length)"' "$OUT_DIR/results.jsonl"
jq -r 'select(.status == "FAIL") | "FAIL \(.id) \(.description)"' "$OUT_DIR/results.jsonl"
printf '\nresults: %s/results.json\n' "$OUT_DIR"
printf 'report:  %s/results.md\n' "$OUT_DIR"

FAILED=$(jq -s '[.[] | select(.status == "FAIL")] | length' "$OUT_DIR/results.jsonl")
SKIPPED=$(jq -s '[.[] | select(.status == "SKIP")] | length' "$OUT_DIR/results.jsonl")
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
    exit 3
fi
exit 0
