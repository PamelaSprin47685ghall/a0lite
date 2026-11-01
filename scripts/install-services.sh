#!/bin/sh
# Install the system units that keep Agent Zero running across reboots.
#
# The units live in /etc/systemd/system and run as the desktop user, so they
# are ordinary system services: they start at boot from graphical.target and
# stop with the machine. Nothing here uses a user unit or lingering.
#
# Usage: sudo install-services.sh [user]
#
# Requires: a graphical target with a display manager, a per-user Flatpak
# installation of org.agentzero.AgentZero, and A0_AUTH_KEY already set through
# `flatpak override --user --env=A0_AUTH_KEY=...`.

set -eu

USER_NAME=${1:?usage: install-services.sh <user>}
HERE=$(cd "$(dirname "$0")/.." && pwd)
UID_N=$(id -u "$USER_NAME")
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)

install -Dm755 "$HERE/systemd/a0-desktop-start" /usr/local/bin/a0-desktop-start

for unit in agent-zero.service agent-zero-desktop.service; do
    sed -e "s|^User=kunweiz$|User=$USER_NAME|" \
        -e "s|^Group=kunweiz$|Group=$USER_NAME|" \
        -e "s|/run/user/1000|/run/user/$UID_N|g" \
        -e "s|/home/kunweiz|$HOME_DIR|g" \
        "$HERE/systemd/$unit" > "/etc/systemd/system/$unit"
done

systemctl daemon-reload
systemctl enable agent-zero.service agent-zero-desktop.service
systemctl restart agent-zero.service
systemctl restart agent-zero-desktop.service

echo "waiting for the UI"
for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:5080/api/health || true)
    [ "$code" = 200 ] && break
    sleep 2
done
echo "UI health $code"
