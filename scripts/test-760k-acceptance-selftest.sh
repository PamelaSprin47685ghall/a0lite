#!/bin/sh
# Fault-injection self-test for test-760k-acceptance.sh.
#
# It prepends a temporary bin/ to PATH, so the acceptance script sees fake
# systemctl/curl/flatpak/pgrep/sudo/reboot commands. No real systemd, /etc,
# reboot, or target state is touched.
#
# Usage: scripts/test-760k-acceptance-selftest.sh
#        A0_SELFTEST_KEEP=1 ...   keep the temp tree for inspection
#
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
SCRIPT=$REPO/scripts/test-760k-acceptance.sh
BASE_PATH=$PATH
TMP=$(mktemp -d "${TMPDIR:-/tmp}/a0-selftest.XXXXXX") || {
    printf 'selftest: mktemp failed\n' >&2
    exit 2
}
BIN=$TMP/bin
TOTAL=0
PASSED=0
RC=0
SCEN=
SID=

cleanup() {
    if [ "${A0_SELFTEST_KEEP:-0}" = 1 ]; then
        printf '\nselftest: kept %s\n' "$TMP"
    else
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT HUP TERM

[ -x "$SCRIPT" ] || {
    printf 'selftest: missing %s\n' "$SCRIPT" >&2
    exit 2
}

make_fakes() {
    mkdir -p "$BIN"

    cat > "$BIN/systemctl" <<'EOF'
#!/bin/sh
[ -n "${FAKE_LOG:-}" ] && printf 'systemctl\n' >> "$FAKE_LOG"
case "$1" in
    is-enabled) exit 0 ;;
    is-active)
        if [ "${FAKE_SYSTEMCTL_ACTIVE:-active}" = active ]; then
            [ "${2:-}" = "--quiet" ] || printf 'active\n'
            exit 0
        fi
        [ "${2:-}" = "--quiet" ] || printf 'inactive\n'
        exit 3
        ;;
    show) printf '%s\n' "${FAKE_MAINPID:-1234}"; exit 0 ;;
    restart|kill) exit 0 ;;
    cat) printf 'ExecStart=/bin/true\nRestart=always\n'; exit 0 ;;
    *) exit 0 ;;
esac
EOF

    cat > "$BIN/sudo" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n|-E) shift ;;
        -u) shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
exec "$@"
EOF

    cat > "$BIN/curl" <<'EOF'
#!/bin/sh
[ -n "${FAKE_LOG:-}" ] && printf 'curl\n' >> "$FAKE_LOG"
out=/dev/null
hdr=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        -D) hdr=$2; shift 2 ;;
        -w|-c|-b|-H|-d|--max-time) shift 2 ;;
        -s|-S|-sS|-f|-L) shift ;;
        --) shift; break ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
case "$url" in
    *api/health*) printf '%s' "${FAKE_HEALTH_CODE:-200}" ;;
    *api/csrf_token*) printf '%s\n' '{"token":"csrf-selftest"}' ;;
    *desktop_session*) printf '%s\n' '{"ok":true,"desktop":{"available":true,"display":":120","url":"http://127.0.0.1:14500/"}}' ;;
    *:14500/*)
        [ "$out" = /dev/null ] || printf '%s' "${FAKE_XPRA_BODY:-}" > "$out"
        [ -z "$hdr" ] || printf '%s\n' "${FAKE_XPRA_HEADERS:-}" > "$hdr"
        printf '%s' "${FAKE_XPRA_CODE:-200}"
        ;;
    *) printf '%s' "${FAKE_HTTP_CODE:-000}" ;;
esac
exit 0
EOF

    cat > "$BIN/flatpak" <<'EOF'
#!/bin/sh
[ -n "${FAKE_LOG:-}" ] && printf 'flatpak\n' >> "$FAKE_LOG"
case "$1" in
    override) printf 'A0_AUTH_KEY=selftest-key\n'; exit 0 ;;
    list) printf 'org.agentzero.AgentZero\n'; exit 0 ;;
    run)
        cat >/dev/null
        printf '%s\n' "${FAKE_C47_LOG:-}"
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF

    cat > "$BIN/pgrep" <<'EOF'
#!/bin/sh
[ -n "${FAKE_LOG:-}" ] && printf 'pgrep\n' >> "$FAKE_LOG"
case "$1" in
    -af) printf '%s\n' "${FAKE_PGREP_OUTPUT:-}"; exit 0 ;;
    -fc) printf '1\n'; exit 0 ;;
    *) exit 1 ;;
esac
EOF

    cat > "$BIN/journalctl" <<'EOF'
#!/bin/sh
[ -n "${FAKE_LOG:-}" ] && printf 'journalctl\n' >> "$FAKE_LOG"
exit 0
EOF

    cat > "$BIN/ss" <<'EOF'
#!/bin/sh
[ -n "${FAKE_LOG:-}" ] && printf 'ss\n' >> "$FAKE_LOG"
exit 0
EOF

    cat > "$BIN/reboot" <<'EOF'
#!/bin/sh
[ -n "${FAKE_LOG:-}" ] && printf 'reboot\n' >> "$FAKE_LOG"
exit 0
EOF

    cat > "$BIN/grub-editenv" <<'EOF'
#!/bin/sh
[ -n "${FAKE_LOG:-}" ] && printf 'grub-editenv\n' >> "$FAKE_LOG"
exit 0
EOF

    cat > "$BIN/find" <<'EOF'
#!/bin/sh
[ -n "${FAKE_LOG:-}" ] && printf 'find\n' >> "$FAKE_LOG"
exec /usr/bin/find "$@"
EOF

    cat > "$BIN/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF

    chmod +x "$BIN"/*
}

begin_scenario() {
    SID=$1
    SCEN=$TMP/$SID
    mkdir -p "$SCEN/home" "$SCEN/out"
    : > "$SCEN/fake.log"
    export A0_HOME="$SCEN/home"
    export FAKE_LOG="$SCEN/fake.log"
    export PATH="$BIN:$BASE_PATH"
    export A0_APP_USER="$(id -un)"
    unset A0_APP_UID A0_AUTH_KEY A0_DATA_DIR A0_WPS_ROOT A0_OUT_ROOT OUT_DIR \
        REBOOT_CONFIRM REBOOT-CONFIRM \
        FAKE_HEALTH_CODE FAKE_XPRA_CODE FAKE_XPRA_HEADERS FAKE_XPRA_BODY \
        FAKE_PGREP_OUTPUT FAKE_C47_LOG FAKE_SYSTEMCTL_ACTIVE FAKE_MAINPID \
        FAKE_HTTP_CODE
}

run_accept() {
    ( cd "$REPO" && "$SCRIPT" "$@" --out "$SCEN/out" ) > "$SCEN/run.out" 2>&1
    RC=$?
}

status_one() {
    jq -r --arg id "$1" 'select(.id == $id) | .status' \
        "$SCEN/out/results.jsonl" 2>/dev/null | head -1
}

fake_has() {
    grep -q "$1" "$SCEN/fake.log" 2>/dev/null
}

record() {
    R_SID=$1
    R_EXPECT=$2
    R_ACTUAL=$3
    R_OK=$4
    TOTAL=$((TOTAL + 1))
    if [ "$R_OK" = yes ]; then
        PASSED=$((PASSED + 1))
        R_MARK=yes
    else
        R_MARK=no
    fi
    printf '| %s | %s | %s | %s |\n' "$R_SID" "$R_EXPECT" "$R_ACTUAL" "$R_MARK"
    if [ "$R_OK" != yes ]; then
        printf '  --- %s diagnostics ---\n' "$R_SID"
        tail -20 "$SCEN/run.out" 2>/dev/null || true
    fi
}

scenario_s1() {
    begin_scenario S1
    export FAKE_HEALTH_CODE=500
    export FAKE_SYSTEMCTL_ACTIVE=active
    run_accept --only C54 --destructive
    STATUS=$(status_one C54)
    RAW=$(grep -E 'HTTP=' "$SCEN/out/C54.log" 2>/dev/null | tail -1)
    if [ "$STATUS" = FAIL ] && [ "$RC" -eq 1 ] &&
       printf '%s' "$RAW" | grep -q 'HTTP=500'; then
        OK=yes
    else
        OK=no
    fi
    record S1 FAIL "FAIL ($RAW)" "$OK"
    printf '  S1 raw: %s\n' "$RAW"
}

scenario_s2() {
    begin_scenario S2
    export FAKE_HEALTH_CODE=200
    export FAKE_SYSTEMCTL_ACTIVE=inactive
    run_accept --only C54 --destructive
    STATUS=$(status_one C54)
    if [ "$STATUS" = FAIL ] && [ "$RC" -eq 1 ] &&
       grep -q 'agent-zero.service is not active' "$SCEN/out/C54.log" 2>/dev/null; then
        OK=yes
    else
        OK=no
    fi
    record S2 FAIL 'FAIL (inactive)' "$OK"
}

scenario_s3() {
    begin_scenario S3
    export FAKE_HEALTH_CODE=200
    export FAKE_SYSTEMCTL_ACTIVE=active
    export FAKE_MAINPID=1234
    run_accept --only C55 --destructive
    STATUS=$(status_one C55)
    if [ "$STATUS" = FAIL ] && [ "$RC" -eq 1 ] &&
       grep -q 'OLD_PID=1234' "$SCEN/out/C55.log" 2>/dev/null &&
       grep -q 'NEW_PID=1234' "$SCEN/out/C55.log" 2>/dev/null; then
        OK=yes
    else
        OK=no
    fi
    record S3 FAIL 'FAIL (PID 1234 -> 1234)' "$OK"
}

scenario_s4() {
    begin_scenario S4
    export FAKE_XPRA_CODE=200
    export FAKE_XPRA_HEADERS='Server: nginx'
    export FAKE_XPRA_BODY='xpra'
    run_accept --only C45
    STATUS=$(status_one C45)
    if [ "$STATUS" = FAIL ] && [ "$RC" -eq 1 ] &&
       grep -q 'HTTP=200' "$SCEN/out/C45.log" 2>/dev/null &&
       grep -q 'Server: nginx' "$SCEN/out/C45.log" 2>/dev/null; then
        OK=yes
    else
        OK=no
    fi
    record S4 FAIL 'FAIL (Server: nginx)' "$OK"
}

scenario_s5() {
    begin_scenario S5
    export FAKE_PGREP_OUTPUT='xpra --tcp-auth=env --mmap=no
Xvfb-for-Xpra-120
start-desktop :120'
    run_accept --only C46
    STATUS=$(status_one C46)
    if [ "$STATUS" = FAIL ] && [ "$RC" -eq 1 ] &&
       grep -q -- '--mmap=no' "$SCEN/out/C46.log" 2>/dev/null; then
        OK=yes
    else
        OK=no
    fi
    record S5 FAIL 'FAIL (--mmap=no)' "$OK"
}

scenario_s6() {
    begin_scenario S6
    export FAKE_C47_LOG='DISPLAY=None
host_display=None
BUNDLED_XVFB_exists=False
xpra_bin_exists=True'
    run_accept --only C47 --destructive
    STATUS=$(status_one C47)
    if [ "$STATUS" = FAIL ] && [ "$RC" -eq 1 ] &&
       ! grep -q 'XVFB_OK' "$SCEN/out/C47.sandbox.log" 2>/dev/null; then
        OK=yes
    else
        OK=no
    fi
    record S6 FAIL 'FAIL (no XVFB_OK)' "$OK"
}

scenario_s7() {
    begin_scenario S7
    export FAKE_SYSTEMCTL_ACTIVE=active
    run_accept --only C54,C55,C48
    if [ "$RC" -eq 3 ] &&
       jq -s -e 'length == 3 and all(.[]; .status == "SKIP")' \
           "$SCEN/out/results.jsonl" >/dev/null 2>&1 &&
       ! fake_has '^systemctl' && ! fake_has '^find'; then
        OK=yes
    else
        OK=no
    fi
    record S7 SKIP 'SKIP x3 (no systemctl/find)' "$OK"
}

scenario_s8() {
    S8_OK=yes
    S8_N=0
    for S8_VAL in unset yes 1 'REBOOT-CONFIRM '; do
        S8_N=$((S8_N + 1))
        begin_scenario "S8-$S8_N"
        export FAKE_SYSTEMCTL_ACTIVE=active
        if [ "$S8_VAL" != unset ]; then
            export REBOOT_CONFIRM="$S8_VAL"
        fi
        run_accept --only C56 --destructive
        STATUS=$(status_one C56)
        if [ "$STATUS" != SKIP ] || [ "$RC" -ne 3 ] || fake_has '^reboot'; then
            S8_OK=no
            printf '  S8 subcase %s: status=%s rc=%s\n' "$S8_VAL" "$STATUS" "$RC"
        fi
    done
    record S8 SKIP 'SKIP x4 (no reboot)' "$S8_OK"
}

scenario_s9() {
    begin_scenario S9
    export FAKE_HEALTH_CODE=200
    export FAKE_SYSTEMCTL_ACTIVE=active
    run_accept --only C54 --destructive
    STATUS=$(status_one C54)
    if [ "$STATUS" = PASS ] && [ "$RC" -eq 0 ]; then
        OK=yes
    else
        OK=no
    fi
    record S9 PASS 'PASS' "$OK"
}

scenario_s10() {
    begin_scenario S10
    export FAKE_XPRA_CODE=200
    export FAKE_XPRA_HEADERS='Server: Xpra-WebSocket-Server'
    export FAKE_XPRA_BODY='xpra'
    run_accept --only C45
    STATUS=$(status_one C45)
    if [ "$STATUS" = PASS ] && [ "$RC" -eq 0 ]; then
        OK=yes
    else
        OK=no
    fi
    record S10 PASS 'PASS' "$OK"
}

make_fakes
printf '| 场景 | 期望 | 实际 | 通过 |\n|---|---|---|---|\n'
scenario_s1
scenario_s2
scenario_s3
scenario_s4
scenario_s5
scenario_s6
scenario_s7
scenario_s8
scenario_s9
scenario_s10

if [ "$PASSED" -eq "$TOTAL" ] && [ "$TOTAL" -eq 10 ]; then
    printf '\nSELFTEST OK (10/10)\n'
    exit 0
fi
printf '\nSELFTEST FAIL (%s/%s)\n' "$PASSED" "$TOTAL"
exit 1
