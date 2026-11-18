#!/bin/sh
# Verify the credential-masking / sensitive-path fix after the bundle is built.
#
# This script is read-only against the running app: it lists sandbox paths,
# calls the file API, and removes its own test symlink. It never installs,
# restarts, or writes to /etc.
#
# Usage:
#   verify-security-fix.sh [--dest HOST:PORT] [--expect new|old]
#
# --expect new  (default) expects the new bundle: masking + API 403.
# --expect old            expects an old bundle: every fix check must observe
#                         the vulnerable behaviour, proving the verifier can
#                         tell the two apart instead of false-PASSing.
#
# Run it only after the new bundle has been built and installed.

set -u

APP_ID=org.agentzero.AgentZero
DEST=127.0.0.1:5080
EXPECT=new
PASS=0
FAIL=0
SKIP=0
TMP=
COOKIE=
BODY=
TOKEN=
LINK_CREATED=0

usage() {
    cat <<'EOF'
usage: verify-security-fix.sh [--dest HOST:PORT] [--expect new|old]

  --dest HOST:PORT  app address (default 127.0.0.1:5080)
  --expect new       new bundle: masking and 403 expected (default)
  --expect old       old bundle: vulnerable behaviour expected; proves the
                     verifier distinguishes old from new
  --help             this text

After a new build, run:
  scripts/verify-security-fix.sh --expect new
EOF
}

die_usage() {
    printf 'verify-security-fix: %s\n' "$*" >&2
    usage >&2
    exit 2
}

pass() {
    PASS=$((PASS + 1))
    printf 'PASS  %s  %s\n' "$1" "$2"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s  %s\n' "$1" "$2"
}

skip() {
    SKIP=$((SKIP + 1))
    printf 'SKIP  %s  %s\n' "$1" "$2"
}

run_flatpak() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        "$@"
    fi
}

flatpak_run() {
    run_flatpak flatpak run --user --command=sh "$APP_ID" -c "$1" 2>/dev/null
}

api_get() {
    if [ -n "${TOKEN:-}" ]; then
        code=$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 10 \
            -c "$COOKIE" -b "$COOKIE" -H "X-CSRF-Token: $TOKEN" \
            "http://$DEST$1" 2>/dev/null) || code=000
    else
        code=$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 10 \
            -c "$COOKIE" -b "$COOKIE" "http://$DEST$1" 2>/dev/null) || code=000
    fi
}

urlencode_path() {
    printf '%s' "$1" | sed 's|/|%2F|g'
}

cleanup() {
    if [ "${LINK_CREATED:-0}" = 1 ]; then
        rm -f "${A0_DATA:-$HOME/.var/app/$APP_ID/data/agent-zero}/a0v-sec-link" 2>/dev/null || true
    fi
    if [ -n "${TMP:-}" ]; then
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dest)
            [ "$#" -ge 2 ] || die_usage "--dest needs a value"
            DEST=$2
            shift 2
            ;;
        --expect)
            [ "$#" -ge 2 ] || die_usage "--expect needs a value"
            EXPECT=$2
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

[ -n "$DEST" ] || die_usage "--dest must not be empty"
DEST=${DEST%/}
case "$EXPECT" in
    new|old) ;;
    *) die_usage "--expect must be new or old" ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/a0-secverify.XXXXXX") || {
    printf 'verify-security-fix: mktemp failed\n' >&2
    exit 2
}
COOKIE=$TMP/cookies
BODY=$TMP/body
csrf=$(curl -sS -c "$COOKIE" -b "$COOKIE" -H "Origin: http://$DEST" \
    --max-time 10 "http://$DEST/api/csrf_token" 2>/dev/null) || csrf=
if command -v jq >/dev/null 2>&1; then
    TOKEN=$(printf '%s' "$csrf" | jq -r '.token // empty' 2>/dev/null)
else
    TOKEN=$(printf '%s' "$csrf" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

verdict_fix() {
    vf_id=$1
    vf_desc=$2
    vf_fixed=$3
    case "$EXPECT:$vf_fixed" in
        new:yes) pass "$vf_id" "$vf_desc" ;;
        new:no) fail "$vf_id" "$vf_desc (still vulnerable)" ;;
        old:no) pass "$vf_id" "[old] $vf_desc: unfixed as expected (未修复)" ;;
        old:yes) fail "$vf_id" "[old] $vf_desc: fixed unexpectedly" ;;
        *) skip "$vf_id" "$vf_desc: cannot observe" ;;
    esac
}

verdict_normal() {
    vn_id=$1
    vn_desc=$2
    vn_ok=$3
    case "$vn_ok" in
        yes) pass "$vn_id" "$vn_desc" ;;
        no) fail "$vn_id" "$vn_desc (regression)" ;;
        *) skip "$vn_id" "$vn_desc: cannot observe" ;;
    esac
}

verdict_health() {
    vh_id=$1
    vh_desc=$2
    vh_ok=$3
    if [ "$vh_ok" = yes ]; then
        pass "$vh_id" "$vh_desc"
    else
        fail "$vh_id" "$vh_desc"
    fi
}

# 1. The installed metadata carries all eight negative filesystem entries.
# ``flatpak info --show-permissions`` filters the ``!`` entries out, so read the
# deployment metadata that the runtime actually consumes.
if ! command -v flatpak >/dev/null 2>&1; then
    skip 1 "flatpak not found"
else
    location=$(flatpak info --show-location "$APP_ID" 2>/dev/null)
    perms=
    [ -n "$location" ] && [ -r "$location/metadata" ] && perms=$(cat "$location/metadata" 2>/dev/null)
    if [ -z "$perms" ]; then
        skip 1 "installed metadata not readable"
    else
        missing=
        for key in .ssh .gnupg .pki .local/share/keyrings .config/gh .aws .docker .kube; do
            printf '%s' "$perms" | grep -Fq "!~/$key" || missing="$missing $key"
        done
        if [ -z "$missing" ]; then
            fixed=yes
        else
            fixed=no
        fi
        verdict_fix 1 "eight credential directories in installed metadata" "$fixed"
    fi
fi

# 2. A private key is not readable inside the sandbox.
if ! command -v flatpak >/dev/null 2>&1; then
    skip 2 "flatpak not found"
else
    script='if [ -r "$HOME/.ssh/id_ed25519" ]; then echo SSH_KEY_READABLE; else echo SSH_KEY_BLOCKED; fi'
    if ! out=$(flatpak_run "$script"); then
        skip 2 "sandbox command failed"
    else
        case "$out" in
            *SSH_KEY_BLOCKED*) fixed=yes ;;
            *SSH_KEY_READABLE*) fixed=no ;;
            *) fixed=unknown ;;
        esac
        verdict_fix 2 "sandbox readability of ~/.ssh/id_ed25519" "$fixed"
    fi
fi

# 3. ~/.ssh has no entries (the directory may still exist as a mount point).
if ! command -v flatpak >/dev/null 2>&1; then
    skip 3 "flatpak not found"
else
    script='if [ -d "$HOME/.ssh" ] && [ "$(ls -A "$HOME/.ssh" 2>/dev/null | wc -l)" -gt 0 ]; then echo SSH_DIR_NONEMPTY; else echo SSH_DIR_EMPTY; fi'
    if ! out=$(flatpak_run "$script"); then
        skip 3 "sandbox command failed"
    else
        case "$out" in
            *SSH_DIR_EMPTY*) fixed=yes ;;
            *SSH_DIR_NONEMPTY*) fixed=no ;;
            *) fixed=unknown ;;
        esac
        verdict_fix 3 "sandbox content of ~/.ssh" "$fixed"
    fi
fi

# 4. ~/.gnupg has no entries.
if ! command -v flatpak >/dev/null 2>&1; then
    skip 4 "flatpak not found"
else
    script='if [ -d "$HOME/.gnupg" ] && [ "$(ls -A "$HOME/.gnupg" 2>/dev/null | wc -l)" -gt 0 ]; then echo GPG_DIR_NONEMPTY; else echo GPG_DIR_EMPTY; fi'
    if ! out=$(flatpak_run "$script"); then
        skip 4 "sandbox command failed"
    else
        case "$out" in
            *GPG_DIR_EMPTY*) fixed=yes ;;
            *GPG_DIR_NONEMPTY*) fixed=no ;;
            *) fixed=unknown ;;
        esac
        verdict_fix 4 "sandbox content of ~/.gnupg" "$fixed"
    fi
fi

# 5. Cloud/CLI credential directories have no entries.
if ! command -v flatpak >/dev/null 2>&1; then
    skip 5 "flatpak not found"
else
    script='bad=0; for d in "$HOME/.aws" "$HOME/.docker" "$HOME/.kube" "$HOME/.config/gh"; do [ -d "$d" ] || continue; [ "$(ls -A "$d" 2>/dev/null | wc -l)" -eq 0 ] || bad=1; done; if [ "$bad" -eq 0 ]; then echo SENSITIVE_DIRS_EMPTY; else echo SENSITIVE_DIRS_NONEMPTY; fi'
    if ! out=$(flatpak_run "$script"); then
        skip 5 "sandbox command failed"
    else
        case "$out" in
            *SENSITIVE_DIRS_EMPTY*) fixed=yes ;;
            *SENSITIVE_DIRS_NONEMPTY*) fixed=no ;;
            *) fixed=unknown ;;
        esac
        verdict_fix 5 "sandbox content of ~/.aws ~/.docker ~/.kube ~/.config/gh" "$fixed"
    fi
fi

# 6. Normal home content is still visible (masking did not hide everything).
if ! command -v flatpak >/dev/null 2>&1; then
    skip 6 "flatpak not found"
else
    script='if [ -d "$HOME/Documents" ] && [ "$(ls -A "$HOME/Documents" 2>/dev/null | wc -l)" -gt 0 ]; then echo NORMAL_DIR_NONEMPTY; elif [ "$(ls -A "$HOME" 2>/dev/null | wc -l)" -gt 0 ]; then echo NORMAL_DIR_NONEMPTY; else echo NORMAL_DIR_EMPTY; fi'
    if ! out=$(flatpak_run "$script"); then
        skip 6 "sandbox command failed"
    else
        case "$out" in
            *NORMAL_DIR_NONEMPTY*) normal=yes ;;
            *NORMAL_DIR_EMPTY*) normal=no ;;
            *) normal=unknown ;;
        esac
        verdict_normal 6 "normal home/Documents content remains visible" "$normal"
    fi
fi

# 7. The running app's /a0 link still points at the writable tree.
# A separate `flatpak run --command=sh` has its own sandbox root, so /a0 is
# created by the launcher only inside the app process; inspect that process.
if ! command -v flatpak >/dev/null 2>&1; then
    skip 7 "flatpak not found"
else
    app_pid=$(pgrep -f 'run_ui.py.*--port' 2>/dev/null | head -1)
    if [ -z "$app_pid" ] || [ ! -d "/proc/$app_pid/root/a0" ]; then
        normal=no
    elif [ "$(ls -A "/proc/$app_pid/root/a0" 2>/dev/null | wc -l)" -gt 0 ]; then
        normal=yes
    else
        normal=no
    fi
    verdict_normal 7 "/a0 work directory remains visible in the app process" "$normal"
fi

# 8. Listing ~/.ssh through the file API is 403 with the marker.
if ! command -v curl >/dev/null 2>&1; then
    skip 8 "curl not found"
else
    enc=$(urlencode_path "$HOME/.ssh")
    api_get "/api/get_work_dir_files?path=$enc"
    if [ "$code" = 000 ]; then
        skip 8 "file API unreachable"
    elif [ "$code" = 403 ] && grep -Fq SENSITIVE_PATH_BLOCKED "$BODY" 2>/dev/null; then
        fixed=yes
    elif [ "$code" = 403 ]; then
        fixed=unknown
    else
        fixed=no
    fi
    verdict_fix 8 "GET get_work_dir_files on ~/.ssh" "$fixed"
fi

# 9. The normal /a0 path is still 200.
if ! command -v curl >/dev/null 2>&1; then
    skip 9 "curl not found"
else
    api_get "/api/get_work_dir_files?path=%2Fa0"
    if [ "$code" = 000 ]; then
        normal=unknown
    elif [ "$code" = 200 ]; then
        normal=yes
    else
        normal=no
    fi
    verdict_normal 9 "GET get_work_dir_files on /a0 returns 200" "$normal"
fi

# 10. Downloading the private key is refused and does not leak key material.
if ! command -v curl >/dev/null 2>&1; then
    skip 10 "curl not found"
else
    enc=$(urlencode_path "$HOME/.ssh/id_ed25519")
    api_get "/api/download_work_dir_file?path=$enc"
    leak=no
    if [ -s "$BODY" ] && tr -d '\000' < "$BODY" | grep -Eq 'BEGIN [A-Z ]*PRIVATE KEY|OPENSSH PRIVATE KEY'; then
        leak=yes
    fi
    if [ "$code" = 000 ]; then
        fixed=unknown
    elif [ "$code" = 403 ] || [ "$code" = 400 ]; then
        if [ "$leak" = no ]; then fixed=yes; else fixed=no; fi
    elif [ "$leak" = yes ]; then
        fixed=no
    else
        fixed=no
    fi
    verdict_fix 10 "download of ~/.ssh/id_ed25519" "$fixed"
fi

# 11. A symlink under /a0 cannot bypass the guard; remove the link afterwards.
if ! command -v curl >/dev/null 2>&1 || ! command -v flatpak >/dev/null 2>&1; then
    skip 11 "curl or flatpak not found"
else
    data_dir=${A0_DATA:-$HOME/.var/app/$APP_ID/data/agent-zero}
    LINK_CREATED=1
    if ! ln -sfn "$HOME/.ssh" "$data_dir/a0v-sec-link" 2>/dev/null; then
        skip 11 "could not create the test symlink"
    else
        api_get "/api/get_work_dir_files?path=%2Fa0%2Fa0v-sec-link%2Fid_ed25519"
        if [ "$code" = 000 ]; then
            fixed=unknown
        elif [ "$code" = 403 ] && grep -Fq SENSITIVE_PATH_BLOCKED "$BODY" 2>/dev/null; then
            fixed=yes
        elif [ "$code" = 403 ]; then
            fixed=unknown
        else
            fixed=no
        fi
        removed=yes
        if ! rm -f "$data_dir/a0v-sec-link" 2>/dev/null; then
            removed=no
        else
            LINK_CREATED=0
        fi
        if [ "$removed" = no ]; then
            fail 11 "test symlink could not be removed"
        else
            verdict_fix 11 "symlink /a0/a0v-sec-link -> ~/.ssh" "$fixed"
        fi
    fi
fi

# 12. The instance is healthy and reports a real version.
if ! command -v curl >/dev/null 2>&1; then
    skip 12 "curl not found"
else
    api_get "/api/health"
    version=
    if [ -s "$BODY" ]; then
        version=$(tr -d '\n' < "$BODY" | sed -n 's/.*"gitinfo".*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
    if [ "$code" = 200 ] && [ -n "$version" ] && [ "$version" != unknown ]; then
        verdict_health 12 "api/health returns 200 and gitinfo.version=$version" yes
    else
        verdict_health 12 "api/health returns 200 and a real gitinfo.version (got ${version:-none}, HTTP $code)" no
    fi
fi

printf '\nSUMMARY: %s/12 PASS, %s FAIL, %s SKIP\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
