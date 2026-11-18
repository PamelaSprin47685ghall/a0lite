#!/bin/sh
# Install the three a0lite bundles on the 760K from a USB rescue kit.
#
# Must run on the 760K as root. It never updates the OS, never edits GRUB,
# and never runs `flatpak uninstall --unused` (that would drop the rollback
# commit). Installation order is main -> Cuda -> Wps; Cuda's runtime is main.
#
# usage: 03-deploy.sh [--bundle-dir DIR] [--with-services] [--dry-run]

set -eu

A0_USER=kunweiz
RUNTIME_DIR=/run/user/1000
OLD_COMMIT=b15bc3875ed0fbbb6c842e863259d19ac0dd7a3f3b72fc7019f6b620b190ad1d

MAIN_BUNDLE=agent-zero.flatpak
CUDA_BUNDLE=agent-zero-cuda.flatpak
WPS_BUNDLE=agent-zero-wps.flatpak
MAIN_SHA=97615832fa8ee5b80a8962ffc3840dca94a7e76b4a8734f4b3036a2a12412bc7
CUDA_SHA=1a5196a4d3e025fb132e8976c891ba603c31abb171e28ed4162bbd582a499f5f
WPS_SHA=3ddbd3504f8b72aad84c1fa8f74830835722a5897253dd59125bc9bcdb768772

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUNDLE_DIR=$SCRIPT_DIR
WITH_SERVICES=0
DRY_RUN=0
INSTALL_STARTED=0

usage() {
    cat <<'EOF'
usage: 03-deploy.sh [--bundle-dir DIR] [--with-services] [--dry-run]
  --bundle-dir DIR  where the three .flatpak files live (default: this script's directory)
  --with-services   install the systemd units to /etc and enable both at boot
  --dry-run         print every step; change nothing
EOF
}

die_usage() {
    printf '03-deploy: %s\n' "$*" >&2
    usage >&2
    exit 2
}

die() {
    printf '03-deploy: %s\n' "$*" >&2
    exit 1
}

say() {
    printf '%s\n' "$*"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    if [ "$INSTALL_STARTED" -eq 1 ]; then
        cat >&2 <<EOF

ROLLBACK (copy/paste on the 760K, as root):
  sudo -u $A0_USER env XDG_RUNTIME_DIR=$RUNTIME_DIR flatpak update --user --commit=$OLD_COMMIT org.agentzero.AgentZero
  # If that cannot find the old commit, reinstall an old bundle you kept:
  # sudo -u $A0_USER env XDG_RUNTIME_DIR=$RUNTIME_DIR flatpak install --user -y --noninteractive --reinstall /path/to/old-agent-zero.flatpak
  # If --with-services ran, hand control back:
  systemctl disable --now agent-zero-desktop.service agent-zero.service 2>/dev/null || true
  rm -rf /etc/a0lite
  # Never delete ~/.var/app/org.agentzero.AgentZero or /root/a0lite-deploy-backup.
EOF
    fi
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --bundle-dir)
            [ "$#" -ge 2 ] || die_usage "--bundle-dir needs a value"
            BUNDLE_DIR=$2
            shift 2
            ;;
        --bundle-dir=*)
            BUNDLE_DIR=${1#--bundle-dir=}
            shift
            ;;
        --with-services)
            WITH_SERVICES=1
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

if [ "$DRY_RUN" -eq 1 ]; then
    cat <<EOF
[dry-run] no sha256sum, systemctl, flatpak, cp, or install command runs.
bundle dir: $BUNDLE_DIR
runtime dir: $RUNTIME_DIR (user $A0_USER)
with services: $WITH_SERVICES

preflight: require $MAIN_BUNDLE / $CUDA_BUNDLE / $WPS_BUNDLE, then sha256sum each:
  $MAIN_SHA  $MAIN_BUNDLE
  $CUDA_SHA  $CUDA_BUNDLE
  $WPS_SHA  $WPS_BUNDLE

would run:
  systemctl cat agent-zero-desktop.service agent-zero.service   # only installed units
  systemctl stop agent-zero-desktop.service agent-zero.service
  # wait up to 30 s for 5080/11434; print holders and exit 1 if still busy
  sudo -u $A0_USER env XDG_RUNTIME_DIR=$RUNTIME_DIR flatpak install --user -y --noninteractive --reinstall "$BUNDLE_DIR/$MAIN_BUNDLE"
  sudo -u $A0_USER env XDG_RUNTIME_DIR=$RUNTIME_DIR flatpak install --user -y --noninteractive --reinstall "$BUNDLE_DIR/$CUDA_BUNDLE"
  sudo -u $A0_USER env XDG_RUNTIME_DIR=$RUNTIME_DIR flatpak install --user -y --noninteractive --reinstall "$BUNDLE_DIR/$WPS_BUNDLE"
EOF
    if [ "$WITH_SERVICES" -eq 1 ]; then
        cat <<EOF
  install -d /etc/a0lite
  cp -a "$SCRIPT_DIR/systemd" /etc/a0lite/
  install -Dm755 "$SCRIPT_DIR/scripts/install-services.sh" /etc/a0lite/scripts/install-services.sh
  bash /etc/a0lite/scripts/install-services.sh $A0_USER
  systemctl enable --now agent-zero.service agent-zero-desktop.service
  systemctl is-enabled / is-active both units; poll health 120 s
EOF
    else
        cat <<EOF
  sudo -u $A0_USER env XDG_RUNTIME_DIR=$RUNTIME_DIR setsid flatpak run --user org.agentzero.AgentZero
  # poll http://127.0.0.1:5080/api/health for 240 s
EOF
    fi
    cat <<EOF

A real run verifies the bundle bytes; this dry run does not read them.
EOF
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    printf 'run with sudo\n' >&2
    exit 1
fi

require() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for cmd in sha256sum systemctl ss curl sudo flatpak setsid mktemp; do
    require "$cmd"
done
id -u "$A0_USER" >/dev/null 2>&1 || die "no such user: $A0_USER"

check_bundle() {
    name=$1
    expected=$2
    path=$BUNDLE_DIR/$name
    [ -f "$path" ] || die "missing bundle: $path (copy the three .flatpak next to this script, or pass --bundle-dir)"
    sudo -u "$A0_USER" test -r "$path" || \
        die "user $A0_USER cannot read $path (check the USB mount options)"
    actual=$(sha256sum -- "$path" | awk '{print $1}')
    [ "$actual" = "$expected" ] || die "sha256 mismatch for $name: expected $expected, got $actual"
    bytes=$(wc -c < "$path" | tr -d ' ')
    say "bundle ok: $name ($bytes bytes, sha256 $actual)"
}

ports_busy() {
    ss -ltn 2>/dev/null | grep -qE ':(5080|11434)([[:space:]]|$)'
}

wait_ports_free() {
    i=0
    while [ "$i" -lt 30 ]; do
        ports_busy || return 0
        i=$((i + 1))
        sleep 1
    done
    return 1
}

wait_health() {
    limit=$1
    deadline=$(( $(date +%s) + limit ))
    code=000
    while [ "$(date +%s)" -lt "$deadline" ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:5080/api/health 2>/dev/null || true)
        if [ "$code" = 200 ]; then
            say 'health 200'
            return 0
        fi
        sleep 1
    done
    printf 'health last=%s\n' "$code" >&2
    return 1
}

say '== preflight =='
check_bundle "$MAIN_BUNDLE" "$MAIN_SHA"
check_bundle "$CUDA_BUNDLE" "$CUDA_SHA"
check_bundle "$WPS_BUNDLE" "$WPS_SHA"

say '== stop old services =='
UNITS=
for unit in agent-zero-desktop.service agent-zero.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
        UNITS="$UNITS $unit"
    else
        say "not installed: $unit (skip)"
    fi
done
if [ -n "$UNITS" ]; then
    # shellcheck disable=SC2086
    say "stopping:$UNITS"
    # shellcheck disable=SC2086
    systemctl stop $UNITS || fail "systemctl stop failed"
else
    say 'no agent-zero services installed; nothing to stop'
fi

if ! wait_ports_free; then
    printf 'ports 5080/11434 are still occupied after 30 s; not killing anything:\n' >&2
    ss -ltnp 2>/dev/null | grep -E ':(5080|11434)([[:space:]]|$)' >&2 || true
    pgrep -af 'run_ui.py|models/bin/ollama' >&2 || true
    sudo -u "$A0_USER" env XDG_RUNTIME_DIR="$RUNTIME_DIR" flatpak ps >&2 2>/dev/null || true
    exit 1
fi
say 'ports 5080/11434 are free'

say '== install bundles =='
INSTALL_STARTED=1
for name in "$MAIN_BUNDLE" "$CUDA_BUNDLE" "$WPS_BUNDLE"; do
    say "installing $name"
    sudo -u "$A0_USER" env XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        flatpak install --user -y --noninteractive --reinstall "$BUNDLE_DIR/$name" \
        || fail "flatpak install failed: $name"
done

if [ "$WITH_SERVICES" -eq 1 ]; then
    say '== install systemd units =='
    [ -f "$SCRIPT_DIR/systemd/agent-zero.service" ] || \
        fail "missing $SCRIPT_DIR/systemd/agent-zero.service; --with-services needs the systemd/ and scripts/ trees from the kit tar"
    [ -f "$SCRIPT_DIR/scripts/install-services.sh" ] || \
        fail "missing $SCRIPT_DIR/scripts/install-services.sh; --with-services needs the systemd/ and scripts/ trees from the kit tar"

    install -d /etc/a0lite
    cp -a "$SCRIPT_DIR/systemd" /etc/a0lite/
    install -Dm755 "$SCRIPT_DIR/scripts/install-services.sh" /etc/a0lite/scripts/install-services.sh
    bash /etc/a0lite/scripts/install-services.sh "$A0_USER" \
        || fail "install-services.sh failed"

    systemctl enable --now agent-zero.service agent-zero-desktop.service \
        || fail "systemctl enable --now failed"
    for unit in agent-zero.service agent-zero-desktop.service; do
        enabled=$(systemctl is-enabled "$unit" 2>&1 || true)
        active=$(systemctl is-active "$unit" 2>&1 || true)
        say "$unit: is-enabled=$enabled is-active=$active"
        [ "$enabled" = enabled ] || fail "$unit is not enabled"
        [ "$active" = active ] || fail "$unit is not active"
    done
    wait_health 120 || fail "UI health is not 200 within 120 s after systemd start"
else
    say '== start =='
    LOG=$(mktemp "${TMPDIR:-/tmp}/a0lite-flatpak-run.XXXXXX") || fail "mktemp failed"
    say "log: $LOG"
    sudo -u "$A0_USER" env XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        setsid flatpak run --user org.agentzero.AgentZero >"$LOG" 2>&1 </dev/null &
    if ! wait_health 240; then
        printf '%s\n' '--- last 40 log lines ---' >&2
        tail -n 40 "$LOG" >&2 || true
        fail "health did not return 200 within 240 s"
    fi
fi

say '== verification =='
sudo -u "$A0_USER" env XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    flatpak --user info org.agentzero.AgentZero 2>/dev/null | grep -E 'Commit|Date' || true
wait_health 30 || fail "final health check failed"
say 'DEPLOY OK'
