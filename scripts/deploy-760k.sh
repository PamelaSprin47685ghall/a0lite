#!/bin/sh
# Deploy the three a0lite bundles to the 760K target and start it.
#
# The target was unreachable when this script was written; it has not been
# executed end-to-end. Only the unreachable path (exit 2) and the shell syntax
# have been verified locally.
#
# The 760K target is decommissioned (2026-11-18: no reconnect for 10.5 h
# after the kernel change). The hashes below follow the local v22 build so
# that the script never stages a stale bundle if it is ever used again.
#
# Expected deliverables (fixed):
#   main  commit d7749980  sha256 97615832fa8ee5b80a8962ffc3840dca94a7e76b4a8734f4b3036a2a12412bc7
#   cuda  commit b0633fcb  sha256 1a5196a4d3e025fb132e8976c891ba603c31abb171e28ed4162bbd582a499f5f
#   wps   commit 790cee09  sha256 3ddbd3504f8b72aad84c1fa8f74830835722a5897253dd59125bc9bcdb768772
#
# Usage:
#   deploy-760k.sh [--target user@host] [--port N] [--bundle-dir DIR] [--dry-run] [--with-services]
#
# The bundles are staged in /home/kunweiz/a0-bundles, not /root: /root is 0700
# and the user installation runs as kunweiz. Installation order is main -> Cuda
# -> Wps; Cuda's runtime/base is the main package. The script never uninstalls
# unused packages, never updates the OS, and never edits grub.
#
# --with-services installs the two systemd units after the app is healthy.
# That path depends on the target's sudo being usable (passwordless or a known
# password); this host's sudo asks for a password, so it was not verified
# end-to-end.

set -eu

TARGET=root@127.0.0.1
PORT=12022
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUNDLE_DIR="$HERE/bundles"
REMOTE_DIR=/home/kunweiz/a0-bundles
SERVICES_DIR=/home/kunweiz/a0-services
DRY_RUN=0
WITH_SERVICES=0
INSTALL_STARTED=0
OLD_COMMIT=""
OLD_COMMIT_DEFAULT=b15bc3875ed0fbbb6c842e863259d19ac0dd7a3f3b72fc7019f6b620b190ad1d

MAIN_SHA=97615832fa8ee5b80a8962ffc3840dca94a7e76b4a8734f4b3036a2a12412bc7
CUDA_SHA=1a5196a4d3e025fb132e8976c891ba603c31abb171e28ed4162bbd582a499f5f
WPS_SHA=3ddbd3504f8b72aad84c1fa8f74830835722a5897253dd59125bc9bcdb768772

usage() {
    cat <<EOF
usage: deploy-760k.sh [--target user@host] [--port N] [--bundle-dir DIR] [--dry-run] [--with-services]
  --target   SSH target (default: root@127.0.0.1)
  --port     SSH port (default: 12022)
  --bundle-dir directory containing the three bundles (default: <repo>/bundles)
  --dry-run  print the steps; do not scp, chown, stop, install, or start
  --with-services install/refresh the two systemd units after health 200
EOF
}

die_usage() {
    printf 'deploy-760k: %s\n' "$*" >&2
    usage >&2
    exit 2
}

say() {
    printf '%s\n' "$*"
}

fail() {
    status=$1
    shift
    printf 'FAIL: %s\n' "$*" >&2
    if [ "$INSTALL_STARTED" -eq 1 ]; then
        cat >&2 <<EOF
ROLLBACK (copy/paste):
  ssh -o BatchMode=yes -p $PORT $TARGET 'sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak update --user --commit=${OLD_COMMIT:-$OLD_COMMIT_DEFAULT} org.agentzero.AgentZero'
  ssh -o BatchMode=yes -p $PORT $TARGET 'sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak uninstall --user -y org.agentzero.AgentZero'
  # If you kept the old bundle, reinstall it instead:
  # ssh -o BatchMode=yes -p $PORT $TARGET 'sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak install --user -y --noninteractive --reinstall /home/kunweiz/a0-bundles/<old>.flatpak'
  # User data is in ~/.var/app/org.agentzero.AgentZero; do not delete it.
EOF
    fi
    exit "$status"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            [ "$#" -ge 2 ] || die_usage "--target needs a value"
            TARGET=$2
            shift 2
            ;;
        --port)
            [ "$#" -ge 2 ] || die_usage "--port needs a value"
            PORT=$2
            shift 2
            ;;
        --bundle-dir)
            [ "$#" -ge 2 ] || die_usage "--bundle-dir needs a value"
            BUNDLE_DIR=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --with-services)
            WITH_SERVICES=1
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

case "$PORT" in
    ''|*[!0-9]*) die_usage "port must be numeric: $PORT" ;;
esac
[ -n "$TARGET" ] || die_usage "target must not be empty"

check_bundle() {
    name=$1
    expected=$2
    path=$BUNDLE_DIR/$name
    [ -f "$path" ] || fail 1 "missing local bundle: $path"
    actual=$(sha256sum "$path" | awk '{print $1}')
    [ "$actual" = "$expected" ] || fail 1 "local sha256 mismatch for $name: expected $expected, got $actual"
    say "local bundle ok: $name $actual"
}

print_plan() {
    cat <<EOF
[dry-run] target reachable; no scp/chown/systemctl/flatpak commands will run.

  ssh -o BatchMode=yes -o ConnectTimeout=5 -p $PORT $TARGET 'id -u kunweiz; flatpak --version; sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user list --columns=application; systemctl is-active agent-zero agent-zero-desktop || true; ss -ltn | grep -E ":(5080|11434)\\b" || true'
  ssh -o BatchMode=yes -p $PORT $TARGET 'install -d -o kunweiz -g kunweiz $REMOTE_DIR'
  scp -P $PORT -o BatchMode=yes "$BUNDLE_DIR/agent-zero.flatpak" "$TARGET:$REMOTE_DIR/"
  scp -P $PORT -o BatchMode=yes "$BUNDLE_DIR/agent-zero-cuda.flatpak" "$TARGET:$REMOTE_DIR/"
  scp -P $PORT -o BatchMode=yes "$BUNDLE_DIR/agent-zero-wps.flatpak" "$TARGET:$REMOTE_DIR/"
  ssh -o BatchMode=yes -p $PORT $TARGET 'chown kunweiz:kunweiz $REMOTE_DIR/*.flatpak; sha256sum $REMOTE_DIR/*.flatpak'
  ssh -o BatchMode=yes -p $PORT $TARGET 'systemctl stop agent-zero-desktop agent-zero || true'
  # wait up to 30 s for 5080/11434; then print pids and args if still held
  ssh -o BatchMode=yes -p $PORT $TARGET 'sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak install --user -y --noninteractive --reinstall $REMOTE_DIR/agent-zero.flatpak'
  ssh -o BatchMode=yes -p $PORT $TARGET 'sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak install --user -y --noninteractive --reinstall $REMOTE_DIR/agent-zero-cuda.flatpak'
  ssh -o BatchMode=yes -p $PORT $TARGET 'sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak install --user -y --noninteractive --reinstall $REMOTE_DIR/agent-zero-wps.flatpak'
  ssh -o BatchMode=yes -p $PORT $TARGET 'sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 setsid sh -c "flatpak run --user org.agentzero.AgentZero > $REMOTE_DIR/run.log 2>&1" </dev/null >/dev/null 2>&1 &'
  # poll http://127.0.0.1:5080/api/health for up to 240 s
  # print commit, list, health, model count, 14500, journal tail
EOF
    if [ "$WITH_SERVICES" -eq 1 ]; then
        cat <<EOF
  ssh -o BatchMode=yes -p $PORT $TARGET 'install -d -o kunweiz -g kunweiz $SERVICES_DIR $SERVICES_DIR/scripts'
  scp -P $PORT -o BatchMode=yes -r "$HERE/systemd" "$TARGET:$SERVICES_DIR/"
  scp -P $PORT -o BatchMode=yes "$HERE/scripts/install-services.sh" "$TARGET:$SERVICES_DIR/scripts/"
  ssh -o BatchMode=yes -p $PORT $TARGET 'chown -R kunweiz:kunweiz $SERVICES_DIR'
  ssh -o BatchMode=yes -p $PORT $TARGET 'sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak kill org.agentzero.AgentZero'
  # wait 30 s for 5080/11434
  ssh -o BatchMode=yes -p $PORT $TARGET 'sudo bash $SERVICES_DIR/scripts/install-services.sh kunweiz'
  ssh -o BatchMode=yes -p $PORT $TARGET 'systemctl is-enabled agent-zero agent-zero-desktop; systemctl is-active agent-zero agent-zero-desktop; systemctl show agent-zero -p ExecMainPID'
  # assert ExecMainPID != manual PID; restart once if equal
  # wait health 200; journalctl -u agent-zero -n 20 --no-pager
  # grep inference compute|library=cuda in data/agent-zero/ollama.log (read-only)
EOF
    fi
}

start_manual_app() {
    ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
        "sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 setsid sh -c 'flatpak run --user org.agentzero.AgentZero > \"$REMOTE_DIR/run.log\" 2>&1' </dev/null >/dev/null 2>&1 &"
}

wait_health() {
    i=0
    code=000
    while [ "$i" -lt 120 ]; do
        code=$(ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
            "curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:5080/api/health" 2>/dev/null || true)
        [ "$code" = 200 ] && return 0
        i=$((i + 1))
        sleep 2
    done
    say "health last=$code"
    return 1
}

wait_ports_free() {
    if ! out=$(ssh -o BatchMode=yes -p "$PORT" "$TARGET" '
i=0
while [ "$i" -lt 30 ]; do
    if ! ss -ltn 2>/dev/null | grep -qE ":(5080|11434)\b"; then
        exit 0
    fi
    i=$((i + 1))
    sleep 1
done
ss -ltnp 2>/dev/null | grep -E ":(5080|11434)\b" || true
pgrep -af "run_ui.py|models/bin/ollama" || true
exit 1
' 2>&1); then
        printf '%s\n' "$out" >&2
        return 1
    fi
    return 0
}

# 1. The reachability check runs even for --dry-run.
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$PORT" "$TARGET" 'true' 2>/dev/null; then
    say 'target unreachable; nothing changed'
    exit 2
fi

# Refuse a wrong artifact before any remote write.
check_bundle agent-zero.flatpak "$MAIN_SHA"
check_bundle agent-zero-cuda.flatpak "$CUDA_SHA"
check_bundle agent-zero-wps.flatpak "$WPS_SHA"

if [ "$DRY_RUN" -eq 1 ]; then
    print_plan
    exit 0
fi

# 2. Target capability check, one SSH round trip.
say '== target capability =='
CAP=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$PORT" "$TARGET" '
set -e
id -u kunweiz
flatpak --version
sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user list --columns=application
systemctl is-active agent-zero agent-zero-desktop 2>&1 || true
ss -ltn 2>&1 | grep -E ":(5080|11434)\b" || true
' 2>&1) || { printf '%s\n' "$CAP" >&2; fail 1 "target capability check failed"; }
printf '%s\n' "$CAP"

OLD_COMMIT=$(ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
    "sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user info org.agentzero.AgentZero 2>/dev/null | sed -n 's/^[[:space:]]*Commit:[[:space:]]*//p' | head -1" \
    2>/dev/null || true)
say "old commit: ${OLD_COMMIT:-<not installed>}"

# 3. Stage bundles where kunweiz can read them; verify the remote bytes.
say '== transfer =='
ssh -o BatchMode=yes -p "$PORT" "$TARGET" "install -d -o kunweiz -g kunweiz '$REMOTE_DIR'"
for item in "agent-zero.flatpak:$MAIN_SHA" "agent-zero-cuda.flatpak:$CUDA_SHA" "agent-zero-wps.flatpak:$WPS_SHA"; do
    name=${item%%:*}
    expected=${item#*:}
    scp -q -P "$PORT" -o BatchMode=yes "$BUNDLE_DIR/$name" "$TARGET:$REMOTE_DIR/"
    ssh -o BatchMode=yes -p "$PORT" "$TARGET" "chown kunweiz:kunweiz '$REMOTE_DIR/$name'"
    actual=$(ssh -o BatchMode=yes -p "$PORT" "$TARGET" "sha256sum '$REMOTE_DIR/$name'" | awk '{print $1}')
    [ "$actual" = "$expected" ] || fail 1 "remote sha256 mismatch for $name: expected $expected, got $actual"
    say "remote bundle ok: $name $actual"
done

# 4. Stop the old services; wait, but never force-kill.
say '== stop old services =='
ssh -o BatchMode=yes -p "$PORT" "$TARGET" 'systemctl stop agent-zero-desktop agent-zero 2>&1 || true'
wait_ports_free || fail 1 "ports 5080/11434 still occupied after 30s; not killing"
say 'ports 5080/11434 are free'

# 5. Install in dependency order.
say '== install bundles =='
INSTALL_STARTED=1
for item in "agent-zero.flatpak:main" "agent-zero-cuda.flatpak:cuda" "agent-zero-wps.flatpak:wps"; do
    name=${item%%:*}
    label=${item#*:}
    say "installing $label ($name)"
    ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
        "sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak install --user -y --noninteractive --reinstall '$REMOTE_DIR/$name'" \
        || fail 1 "flatpak install failed for $name; see rollback below"
done

# 6. Start detached and wait for health.
say '== start =='
start_manual_app || fail 1 "failed to start the application"
wait_health || fail 1 "health did not return 200 within 240s"
MANUAL_PID=$(ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
    "sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak ps | awk '\$3 == \"org.agentzero.AgentZero\" { print \$2; exit }'" \
    2>/dev/null || true)
say "manual instance PID: ${MANUAL_PID:-<unknown>}"

# 6b. Optional systemd takeover.
if [ "$WITH_SERVICES" -eq 1 ]; then
    say '== systemd units =='
    if [ -z "$MANUAL_PID" ]; then
        say 'cannot identify the manual instance PID; refusing to claim systemd takeover'
        exit 1
    fi
    ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
        "install -d -o kunweiz -g kunweiz '$SERVICES_DIR' '$SERVICES_DIR/scripts'" \
        || { say '应用已安装并运行；systemd 单元未完成，原因见上'; exit 1; }
    scp -q -r -P "$PORT" -o BatchMode=yes "$HERE/systemd" "$TARGET:$SERVICES_DIR/" \
        || { say '应用已安装并运行；systemd 单元未完成，原因见上'; exit 1; }
    scp -q -P "$PORT" -o BatchMode=yes "$HERE/scripts/install-services.sh" "$TARGET:$SERVICES_DIR/scripts/" \
        || { say '应用已安装并运行；systemd 单元未完成，原因见上'; exit 1; }
    ssh -o BatchMode=yes -p "$PORT" "$TARGET" "chown -R kunweiz:kunweiz '$SERVICES_DIR'" \
        || { say '应用已安装并运行；systemd 单元未完成，原因见上'; exit 1; }

    # Stop the manual instance before systemd starts its own.
    ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
        'sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak kill org.agentzero.AgentZero 2>/dev/null || true'
    if ! wait_ports_free; then
        start_manual_app >/dev/null 2>&1 || true
        wait_health || true
        say '应用已安装并运行；systemd 单元未完成，原因见上'
        exit 1
    fi

    if ! SERVICES_OUT=$(ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
        "sudo bash '$SERVICES_DIR/scripts/install-services.sh' kunweiz" 2>&1); then
        printf '%s\n' "$SERVICES_OUT" >&2
        start_manual_app >/dev/null 2>&1 || true
        wait_health || true
        say '应用已安装并运行；systemd 单元未完成，原因见上'
        exit 1
    fi
    printf '%s\n' "$SERVICES_OUT"

    if ! ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
        'set -e; systemctl is-enabled agent-zero agent-zero-desktop; systemctl is-active agent-zero agent-zero-desktop; systemctl show agent-zero -p ExecMainPID'; then
        say '应用已安装并运行；systemd 单元未完成，原因见上'
        exit 1
    fi

    SERVICE_PID=$(ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
        'systemctl show agent-zero -p ExecMainPID --value' 2>/dev/null || true)
    say "systemd ExecMainPID: $SERVICE_PID"
    if [ "$SERVICE_PID" = "$MANUAL_PID" ]; then
        say 'ExecMainPID still equals the manual PID; restarting agent-zero once'
        ssh -o BatchMode=yes -p "$PORT" "$TARGET" 'systemctl restart agent-zero' \
            || { say '应用已安装并运行；systemd 单元未完成，原因见上'; exit 1; }
        SERVICE_PID=$(ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
            'systemctl show agent-zero -p ExecMainPID --value' 2>/dev/null || true)
        say "systemd ExecMainPID after restart: $SERVICE_PID"
    fi
    if [ -z "$SERVICE_PID" ] || [ "$SERVICE_PID" = "$MANUAL_PID" ]; then
        say 'systemd did not take over: ExecMainPID is empty or still the manual PID'
        exit 1
    fi

    wait_health || { say '应用已安装并运行；systemd 单元未完成，原因见上'; exit 1; }
    ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
        'journalctl -u agent-zero -n 20 --no-pager 2>/dev/null || true' || true
fi

# 7. Verification summary.
say '== verification =='
ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
    "sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user info org.agentzero.AgentZero 2>&1 | grep -E 'Commit|Date|Installed Size'" \
    || fail 1 "flatpak info failed after install"

LIST=$(ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
    "sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user list --columns=application,branch,commit" 2>&1) || true
printf '%s\n' "$LIST"
case "$LIST" in
    *"Unknown column"*)
        say 'note: this flatpak has no "commit" column; retrying with active'
        ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
            "sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user list --columns=application,branch,active" 2>&1 || true
        ;;
esac

ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
    "curl -sS --max-time 10 http://127.0.0.1:5080/api/health; echo; curl -sS --max-time 10 http://127.0.0.1:11434/api/tags | jq -r '.models[].name' 2>/dev/null | wc -l" \
    || fail 1 "health/tags verification failed"

say '14500 status (may be absent until Desktop is started):'
ssh -o BatchMode=yes -p "$PORT" "$TARGET" 'ss -ltnp 2>/dev/null | grep 14500 || echo "14500 not listening"' || true
say 'journal errors (last 5):'
ssh -o BatchMode=yes -p "$PORT" "$TARGET" 'journalctl -b -p err --no-pager 2>/dev/null | tail -5 || true' || true
say 'CUDA log lines (if present):'
ssh -o BatchMode=yes -p "$PORT" "$TARGET" \
    'grep -E "inference compute|library=cuda" /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/ollama.log 2>/dev/null | tail -5 || true' || true

say 'DEPLOY OK'
say "target=$TARGET port=$PORT"
say "evidence log: $REMOTE_DIR/run.log"
exit 0
