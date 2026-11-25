#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# pack-image.sh DIR NAME [OUT_DIR=~/xnubuild/up]: (on the Mac) pack DIR's mac.img, mac.conf and trustcache.bin into
# OUT_DIR/NAME/part.* (one zstd-compressed tar cut into 1 GiB pieces). bsdtar records the holes of the sparse image;
# GNU tar -S on the VM writes them back as holes. Pieces let a transfer run in parallel and resend only what failed.
# Removes an earlier OUT_DIR/NAME first. THE OUTPUT CONTAINS APPLE'S FILES: private storage only.
# Exit: 0 packed, 1 failed, 2 wrong usage.
# Status: only syntax-checked in this cleaned form; the private original packed a 28 GB image in 40 s.
set -euo pipefail; export PATH=/opt/homebrew/bin:$PATH
case "${1:-}" in -h|--help) sed -n '3,/^set /{/^#/!d;s/^# \{0,1\}//;p;}' "$0"; exit 0;; esac
[ $# -ge 2 ] || { echo "usage: pack-image.sh DIR NAME [OUT_DIR]" >&2; exit 2; }
D=$1; N=$2; U=${3:-$HOME/xnubuild/up}/$N
for f in mac.img mac.conf trustcache.bin; do [ -e "$D/$f" ] || { echo "pack-image: no $D/$f" >&2; exit 2; }; done
rm -rf "$U"; mkdir -p "$U"; cd "$D"
t=$(date +%s); tar -cf - mac.img mac.conf trustcache.bin | zstd -T0 -3 -q | split -b 1g -a 2 - "$U/part."
echo "packed in $(( $(date +%s) - t )) s: $(find "$U" -name 'part.*' | wc -l | tr -d ' ') parts, $(du -sh "$U" | cut -f1)"; ls "$U"
