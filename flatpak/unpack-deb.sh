#!/bin/sh
# Extract a Debian package without dpkg.
#
# The Flatpak SDK ships `ar`, `tar` and the compressors, but not `dpkg-deb`.
# A .deb is an `ar` archive whose `data.tar.*` member holds the payload, so
# unpacking it means reading that member and handing it to tar with the
# matching decompression flag.
#
# Usage: unpack-deb.sh PACKAGE.deb DESTDIR

set -eu

deb="$1"
dest="$2"

member=$(ar t "$deb" | grep '^data\.tar' | head -n 1)
if [ -z "$member" ]; then
    echo "unpack-deb: no data member in $deb" >&2
    exit 1
fi

case "$member" in
    *.xz) flag=-J ;;
    *.gz) flag=-z ;;
    *.zst) flag=--zstd ;;
    *.bz2) flag=-j ;;
    *) flag= ;;
esac

mkdir -p "$dest"
ar p "$deb" "$member" | tar $flag -x -C "$dest" --no-same-owner
