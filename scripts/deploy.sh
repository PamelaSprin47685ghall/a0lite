#!/bin/sh
# Install the bundles on a target machine and start the runtime.
#
# Usage: deploy.sh user@host [bundle-dir]
#
# The bundles are copied, installed per user, and the application is started
# detached so it survives the ssh session. Nothing is built here.

set -eu

TARGET=${1:?usage: deploy.sh user@host [bundle-dir]}
DIR=${2:-$(cd "$(dirname "$0")/.." && pwd)/bundles}

SSH="ssh -o BatchMode=yes $TARGET"

for bundle in agent-zero.flatpak agent-zero-cuda.flatpak agent-zero-wps.flatpak; do
    [ -f "$DIR/$bundle" ] || { echo "deploy: $bundle missing in $DIR" >&2; exit 1; }
    scp -q -o BatchMode=yes "$DIR/$bundle" "$TARGET:/tmp/"
    $SSH "flatpak install --user -y --noninteractive --reinstall /tmp/$bundle"
done

# Models ship as an uncompressed repository; see package-models.sh. The archive
# is expected to contain a top-level directory named models-repo.
if [ -f "$DIR/models-repo.tar" ]; then
    scp -q -o BatchMode=yes "$DIR/models-repo.tar" "$TARGET:/tmp/"
    $SSH "tar -xf /tmp/models-repo.tar -C \$HOME &&
          flatpak remote-add --user --if-not-exists --no-gpg-verify \
              models-local file://\$HOME/models-repo &&
          flatpak install --user -y --noninteractive models-local \
              org.agentzero.AgentZero.Models"
fi

# Kill and start in separate invocations, and escape the dot: the remote shell
# command line contains the application id, so an unescaped `pkill -f` pattern
# matches the shell itself and takes the session down.
$SSH 'pgrep -f "org[.]agentzero" | xargs -r kill -9; true'
$SSH 'setsid sh -c "flatpak run --user org.agentzero.AgentZero >/tmp/agent-zero.log 2>&1" \
      </dev/null >/dev/null 2>&1 & sleep 2; echo started'

echo "waiting for the UI"
$SSH 'for i in $(seq 1 24); do
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:5080/)
        [ "$code" = 200 ] && break
        sleep 5
      done
      echo "UI $code"
      curl -s --max-time 5 http://127.0.0.1:11434/api/tags |
          grep -o "\"name\":\"[^\"]*\"" || echo "ollama: no models"'
