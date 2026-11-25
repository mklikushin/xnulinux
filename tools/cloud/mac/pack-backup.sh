#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# pack-backup.sh NAME PATH...: (on the Mac) back up PATHs (relative to your home) into ~/xnubuild/up/NAME/part.* (zstd
# tar, 1 GiB pieces; OUT_DIR overrides ~/xnubuild/up). For what only a Mac can rebuild: the installed guests, the GPU
# bundle, build logs. Also writes OUT_DIR/NAME.sha256 (SHA-256 of every regular file packed) and OUT_DIR/NAME.list (the
# tar listing read back from the parts, which proves they decompress and untar to the end). Sockets are skipped.
# Removes an earlier OUT_DIR/NAME first. Guests and bundles contain Apple's files: private storage only.
# Exit: 0 packed and read back, 1 failed, 2 wrong usage.
# Status: only syntax-checked in this cleaned form; the private original packed 43 GB of guests in 40 s.
set -euo pipefail; export PATH=/opt/homebrew/bin:$PATH
case "${1:-}" in -h|--help) sed -n '3,/^set /{/^#/!d;s/^# \{0,1\}//;p;}' "$0"; exit 0;; esac
[ $# -ge 2 ] || { echo "usage: pack-backup.sh NAME PATH..." >&2; exit 2; }
N=$1; shift; O=${OUT_DIR:-$HOME/xnubuild/up}; U=$O/$N; rm -rf "$U"; mkdir -p "$U"; cd "$HOME"; t=$(date +%s)
tar -cf - --exclude '*.sock' "$@" | zstd -T0 -3 -q | split -b 1g -a 2 - "$U/part."
echo "packed in $(( $(date +%s) - t )) s: $(find "$U" -name 'part.*' | wc -l | tr -d ' ') parts, $(du -sh "$U" | cut -f1)"
find "$@" -type f ! -name '*.sock' -print0 | xargs -0 -P 4 -n 1 shasum -a 256 | sort -k2 > "$O/$N.sha256"
cat "$U"/part.* | zstd -d -q | tar -tvf - > "$O/$N.list"
echo "read back: $(wc -l < "$O/$N.list" | tr -d ' ') entries, $(wc -l < "$O/$N.sha256" | tr -d ' ') file hashes; total $(( $(date +%s) - t )) s"
