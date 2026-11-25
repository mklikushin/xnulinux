#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# push-parts.sh DIR: (on the Mac) upload DIR/part.* to the upload URLs listed in DIR/urls ("part.xx URL" per line), eight
# at a time, and print each part's HTTP status. The URLs are resumable-session URLs somebody with bucket access made
# (../relay-mac-to-bucket.sh does), so the Mac needs no cloud credentials. A status other than 200 is only reported:
# the caller compares checksums afterwards. Safe to run again.
# Exit: 0 all transfers ran, 1 curl failed for one, 2 wrong usage.
# Status: only syntax-checked in this cleaned form; the private original sent 23 GB in 206 s.
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '3,/^set /{/^#/!d;s/^# \{0,1\}//;p;}' "$0"; exit 0;; esac
[ $# -eq 1 ] && [ -r "$1/urls" ] || { echo "usage: push-parts.sh DIR   (DIR/urls must exist)" >&2; exit 2; }
cd "$1"; t=$(date +%s)
xargs -P 8 -L 1 sh -c 'c=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/octet-stream" -T "$0" "$1"); echo "$0 $c"' < urls
echo "pushed in $(( $(date +%s) - t )) s"
