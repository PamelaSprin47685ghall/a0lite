#!/bin/sh
# Self-test for verify-security-fix.sh. No real flatpak, curl, or target app is
# touched: a temporary bin/ supplies fake commands selected by FAKE_CURL_MODE.
#
# V1: all fixed  -> 12/12 PASS, exit 0
# V2: check 8 returns 200 -> exactly one FAIL, exit 1
# V3: --expect old + vulnerable values -> 12/12, unfixed as expected, exit 0
#
set -u

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
VERIFY=$REPO/scripts/verify-security-fix.sh
BASE_PATH=$PATH
TMP=$(mktemp -d "${TMPDIR:-/tmp}/a0-secverify-test.XXXXXX") || {
    printf 'selftest: mktemp failed\n' >&2
    exit 2
}
BIN=$TMP/bin
TOTAL=0
PASSED=0
V_RC=0
V_OUT=

cleanup() {
    if [ "${A0_SELFTEST_KEEP:-0}" = 1 ]; then
        printf '\nselftest: kept %s\n' "$TMP"
    else
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT HUP TERM

[ -x "$VERIFY" ] || {
    printf 'selftest: missing %s\n' "$VERIFY" >&2
    exit 2
}

make_fakes() {
    mkdir -p "$BIN"

    cat > "$BIN/flatpak" <<'EOF'
#!/bin/sh
case "$1" in
    info)
        case "$2" in
            --show-location)
                printf '%s\n' "${FAKE_LOCATION:-}"
                ;;
            --show-permissions)
                printf '%s\n' "${FAKE_PERMS:-}"
                ;;
            *)
                printf '%s\n' "${FAKE_PERMS:-}"
                ;;
        esac
        exit 0
        ;;
    run)
        script=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -c) script=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        case "$script" in
            *SSH_KEY_READABLE*)
                printf '%s\n' "${FAKE_SSH_KEY:-SSH_KEY_BLOCKED}"
                ;;
            *SSH_DIR_EMPTY*)
                printf '%s\n' "${FAKE_SSH_DIR:-SSH_DIR_EMPTY}"
                ;;
            *GPG_DIR_EMPTY*)
                printf '%s\n' "${FAKE_GPG_DIR:-GPG_DIR_EMPTY}"
                ;;
            *SENSITIVE_DIRS_EMPTY*)
                printf '%s\n' "${FAKE_DIRS:-SENSITIVE_DIRS_EMPTY}"
                ;;
            *NORMAL_DIR_NONEMPTY*)
                printf '%s\n' "${FAKE_NORMAL:-NORMAL_DIR_NONEMPTY}"
                ;;
            *A0_DIR_NONEMPTY*)
                printf '%s\n' "${FAKE_A0:-A0_DIR_NONEMPTY}"
                ;;
            *ln\ -sfn*)
                exit 0
                ;;
            *rm\ -f\ /a0/a0v-sec-link*)
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF

    cat > "$BIN/curl" <<'EOF'
#!/bin/sh
out=/dev/null
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        -w|-c|-b|-H|-d|--max-time) shift 2 ;;
        -s|-S|-sS|-f|-L) shift ;;
        --) shift; break ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done

mode=${FAKE_CURL_MODE:-good}
version=${FAKE_VERSION:-new-ok}
key='-----BEGIN OPENSSH PRIVATE KEY-----
fake
-----END OPENSSH PRIVATE KEY-----'
marker='{"ok":false,"error":"SENSITIVE_PATH_BLOCKED","message":"blocked"}'
normal='{"ok":true,"data":[]}'
health="{\"gitinfo\":{\"branch\":\"x\",\"version\":\"$version\"}}"

case "$url" in
    *api/health*)
        code=200
        body=$health
        ;;
    *get_work_dir_files*)
        case "$url" in
            *a0v-sec-link*)
                if [ "$mode" = old ]; then code=200; body=$key; else code=403; body=$marker; fi
                ;;
            *.ssh*)
                if [ "$mode" = old ]; then
                    code=200; body=$key
                elif [ "$mode" = bad8 ]; then
                    code=200; body=$normal
                else
                    code=403; body=$marker
                fi
                ;;
            *)
                code=200; body=$normal
                ;;
        esac
        ;;
    *download_work_dir_file*)
        if [ "$mode" = old ]; then code=200; body=$key; else code=403; body=$marker; fi
        ;;
    *)
        code=200; body=$normal
        ;;
esac

[ "$out" = /dev/null ] || printf '%s' "$body" > "$out"
printf '%s' "$code"
exit 0
EOF

    chmod +x "$BIN"/*
}

check_fake_coverage() {
    verify_cmds=$(grep -o 'flatpak [a-z-]*' "$VERIFY" |
        awk '{print $2}' | grep -Ev '^(|not|found|flatpak)$' |
        sort -u | tr '\n' ' ')
    fake_cmds=$(grep -oE '^[[:space:]]*[a-z][a-z-]*\)' "$BIN/flatpak" |
        tr -d ' )' | tr '\n' ' ')
    missing=
    if [ -z "$verify_cmds" ]; then
        missing=' no-flatpak-subcommand-found'
    else
        for vc in $verify_cmds; do
            case " $fake_cmds " in
                *" $vc "*) ;;
                *) missing="$missing flatpak-$vc" ;;
            esac
        done
    fi
    verify_info_opts=$(grep -o 'flatpak info --[a-z-]*' "$VERIFY" |
        awk '{print $3}' | sort -u | tr '\n' ' ')
    fake_info_opts=$(grep -o -- '--show-[a-z-]*' "$BIN/flatpak" |
        sort -u | tr '\n' ' ')
    for vo in $verify_info_opts; do
        case " $fake_info_opts " in
            *" $vo "*) ;;
            *) missing="$missing info-$vo" ;;
        esac
    done
    if [ -n "$missing" ]; then
        printf 'SELFTEST FAIL: fake flatpak coverage missing:%s\n' "$missing"
        exit 1
    fi
    printf 'coverage: flatpak [%s]; info [%s]\n' "$fake_cmds" "$fake_info_opts"
}

run_v() {
    V_NAME=$1
    V_EXPECT=$2
    V_OUT=$TMP/$V_NAME.out
    V_LOC=$TMP/location-$V_NAME
    mkdir -p "$V_LOC"
    printf '%s\n' "$FAKE_METADATA" > "$V_LOC/metadata"
    ( cd "$REPO" || exit 1
      unset A0_AUTH_KEY
      PATH="$BIN:$BASE_PATH" \
      FAKE_PERMS="$FAKE_PERMS" \
      FAKE_LOCATION="$V_LOC" \
      FAKE_SSH_KEY="$FAKE_SSH_KEY" \
      FAKE_SSH_DIR="$FAKE_SSH_DIR" \
      FAKE_GPG_DIR="$FAKE_GPG_DIR" \
      FAKE_DIRS="$FAKE_DIRS" \
      FAKE_NORMAL="$FAKE_NORMAL" \
      FAKE_A0="$FAKE_A0" \
      FAKE_CURL_MODE="$FAKE_CURL_MODE" \
      FAKE_VERSION="$FAKE_VERSION" \
      "$VERIFY" --expect "$V_EXPECT" ) > "$V_OUT" 2>&1
    V_RC=$?
}

record() {
    R_NAME=$1
    R_EXPECT=$2
    R_ACTUAL=$3
    R_OK=$4
    TOTAL=$((TOTAL + 1))
    if [ "$R_OK" = yes ]; then
        PASSED=$((PASSED + 1))
        R_MARK=yes
    else
        R_MARK=no
        printf '  --- %s verifier output tail ---\n' "$R_NAME"
        tail -25 "$V_OUT" 2>/dev/null || true
    fi
    printf '| %s | %s | %s | %s |\n' "$R_NAME" "$R_EXPECT" "$R_ACTUAL" "$R_MARK"
}

make_fakes
check_fake_coverage
printf '| 场景 | 期望 | 实际 | 通过 |\n|---|---|---|---|\n'

# V1: all fixed.
FAKE_PERMS='[Context]
filesystems=host;!~/.ssh;!~/.gnupg;!~/.pki;!~/.local/share/keyrings;!~/.config/gh;!~/.aws;!~/.docker;!~/.kube;'
FAKE_METADATA='[Context]
filesystems=host;!~/.ssh;!~/.gnupg;!~/.pki;!~/.local/share/keyrings;!~/.config/gh;!~/.aws;!~/.docker;!~/.kube;'
FAKE_SSH_KEY=SSH_KEY_BLOCKED
FAKE_SSH_DIR=SSH_DIR_EMPTY
FAKE_GPG_DIR=GPG_DIR_EMPTY
FAKE_DIRS=SENSITIVE_DIRS_EMPTY
FAKE_NORMAL=NORMAL_DIR_NONEMPTY
FAKE_A0=A0_DIR_NONEMPTY
FAKE_CURL_MODE=good
FAKE_VERSION=new-ok
run_v V1 new
V1_SUMMARY=$(grep '^SUMMARY' "$V_OUT" 2>/dev/null | tail -1)
V1_FAILS=$(grep -c '^FAIL  ' "$V_OUT" 2>/dev/null || true)
if [ "$V_RC" -eq 0 ] && [ "${V1_FAILS:-0}" -eq 0 ] &&
   printf '%s' "$V1_SUMMARY" | grep -q '^SUMMARY: 12/12 PASS, 0 FAIL'; then
    V1_OK=yes
else
    V1_OK=no
fi
record V1 '12/12 PASS, exit 0' "$V1_SUMMARY (exit $V_RC)" "$V1_OK"

# V2: only check 8 is broken (returns 200).
FAKE_CURL_MODE=bad8
run_v V2 new
V2_SUMMARY=$(grep '^SUMMARY' "$V_OUT" 2>/dev/null | tail -1)
V2_FAILS=$(grep -c '^FAIL  ' "$V_OUT" 2>/dev/null || true)
if [ "$V_RC" -eq 1 ] && [ "${V2_FAILS:-0}" -eq 1 ] &&
   grep -q '^FAIL  8' "$V_OUT" 2>/dev/null &&
   printf '%s' "$V2_SUMMARY" | grep -q '^SUMMARY: 11/12 PASS, 1 FAIL'; then
    V2_OK=yes
else
    V2_OK=no
fi
record V2 '11/12, 1 FAIL (check 8), exit 1' "$V2_SUMMARY (exit $V_RC)" "$V2_OK"

# V3: old bundle; every fix check must observe unfixed behaviour.
FAKE_PERMS='[Context]
filesystems=host;'
FAKE_METADATA='[Context]
filesystems=host;'
FAKE_SSH_KEY=SSH_KEY_READABLE
FAKE_SSH_DIR=SSH_DIR_NONEMPTY
FAKE_GPG_DIR=GPG_DIR_NONEMPTY
FAKE_DIRS=SENSITIVE_DIRS_NONEMPTY
FAKE_NORMAL=NORMAL_DIR_NONEMPTY
FAKE_A0=A0_DIR_NONEMPTY
FAKE_CURL_MODE=old
FAKE_VERSION=old-ok
run_v V3 old
V3_SUMMARY=$(grep '^SUMMARY' "$V_OUT" 2>/dev/null | tail -1)
V3_FAILS=$(grep -c '^FAIL  ' "$V_OUT" 2>/dev/null || true)
V3_UNFIXED=$(grep -c 'unfixed as expected' "$V_OUT" 2>/dev/null || true)
if [ "$V_RC" -eq 0 ] && [ "${V3_FAILS:-0}" -eq 0 ] &&
   [ "${V3_UNFIXED:-0}" -ge 8 ] &&
   grep -q '\[old\]' "$V_OUT" 2>/dev/null &&
   printf '%s' "$V3_SUMMARY" | grep -q '^SUMMARY: 12/12 PASS, 0 FAIL'; then
    V3_OK=yes
else
    V3_OK=no
fi
record V3 'old 12/12, unfixed as expected, exit 0' "$V3_SUMMARY (exit $V_RC)" "$V3_OK"

if [ "$PASSED" -eq "$TOTAL" ] && [ "$TOTAL" -eq 3 ]; then
    printf '\nSELFTEST OK (3/3)\n'
    exit 0
fi
printf '\nSELFTEST FAIL (%s/%s)\n' "$PASSED" "$TOTAL"
exit 1
