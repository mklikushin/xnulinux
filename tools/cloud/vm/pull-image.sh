#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# pull-image.sh BUCKET NAME [DEST_DIR=/var/tmp/NAME]: (on the VM) fetch the object NAME.tar.zst from a Google Cloud
# Storage bucket and unpack it into DEST_DIR as mac.img (sparse), mac.conf and trustcache.bin. The access token is read
# from stdin (one line), so it is in no command line, file or log:
#   gcloud auth print-access-token | ../vm-run vm/pull-image.sh BUCKET NAME      (from your own machine)
# Streams straight into zstd and tar: no second copy on the VM's disk. Another object store: replace the curl line.
# Safe to run again (it overwrites the files in DEST_DIR).
# Exit: 0 unpacked, 1 download or unpack failed (zstd "Data corruption detected" = a wrong part went into the object),
# 2 wrong usage.
# Status: only syntax-checked in this cleaned form; the private original pulled 23-29 GB images.
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '3,/^set /{/^#/!d;s/^# \{0,1\}//;p;}' "$0"; exit 0;; esac
[ $# -ge 2 ] || { echo "usage: pull-image.sh BUCKET NAME [DEST_DIR]   (access token on stdin)" >&2; exit 2; }
read -r TOK || true; [ -n "${TOK:-}" ] || { echo "pull-image: no access token on stdin" >&2; exit 2; }
BK=$1; N=$2; D=${3:-/var/tmp/$N}
command -v zstd >/dev/null || sudo apt-get install -y zstd >/dev/null
mkdir -p "$D"; cd "$D"; t=$(date +%s)
curl -sS --fail -H @<(printf 'Authorization: Bearer %s\n' "$TOK") "https://storage.googleapis.com/storage/v1/b/$BK/o/$N.tar.zst?alt=media" | zstd -d | tar -xSf -
echo "pulled in $(( $(date +%s) - t )) s"; ls -ls "$D"; cat mac.conf; df -h "$D" | tail -1
