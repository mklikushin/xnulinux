#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# save-image.sh IMAGE_DIR NAME [OUT_DIR=/var/tmp/up]: (on the VM, hosted system stopped) pack the disk image and the
# kernel side into 1 GiB pieces, ready for ../relay-vm-to-bucket.sh or any other copy.
#   OUT_DIR/NAME/part.*    tar of IMAGE_DIR's mac.img (sparse), mac.conf, trustcache.bin and keystore.bin when there, zstd
#   OUT_DIR/NAMEk/part.*   kernel side: /lib/firmware/xnu, the repository (XNU_REPO, default ~/w/poc) with its built modules,
#                          the kernelcache input (~/w/dvm/out/kc/kc27.bin), /etc/xnulinux.conf, the grub drop-in, and
#                          the host kernel version and command line
# Each folder gets WANT ("part md5-base64 size" per line) and the image is read back from the parts to the end of the tar.
# Restore: cat the parts in name order | zstd -d | tar -xSf -   (kernel side: sudo, with -C /).
# BOTH OUTPUTS CONTAIN APPLE'S FILES: keep them in storage only you can read; never publish them.
# The modules inside are built for the host kernel that was running. Needs free space of about the image's used size.
# Exit: 0 packed and read back, 1 failed (also: hosted system still running), 2 wrong usage.
# Status: only syntax-checked in this cleaned form; the private original saved a 29 GB image in 226 s.
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '3,/^set /{/^#/!d;s/^# \{0,1\}//;p;}' "$0"; exit 0;; esac
[ $# -ge 2 ] || { echo "usage: save-image.sh IMAGE_DIR NAME [OUT_DIR]" >&2; exit 2; }
I=$1; N=$2; U=${3:-/var/tmp/up}; R=${XNU_REPO:-$HOME/w/poc}; t=$(date +%s)
[ -e "$I/mac.img" ] || { echo "save-image: no $I/mac.img" >&2; exit 2; }
lsmod | grep -q '^xnu ' && { echo "save-image: the hosted system is running: stop it first (scripts/xnulinux-boot.sh stop)" >&2; exit 1; }
rm -rf "${U:?}/$N" "${U:?}/${N}k"; mkdir -p "$U/$N" "$U/${N}k"
{ uname -r; cat /proc/cmdline; } > /var/tmp/host-kernel.txt
K="lib/firmware/xnu etc/xnulinux.conf var/tmp/host-kernel.txt ${R#/}"
for f in etc/default/grub.d/99-xnulinux.cfg "${HOME#/}/w/dvm/out/kc/kc27.bin"; do [ -e "/$f" ] && K="$K $f"; done
# shellcheck disable=SC2086
sudo tar -cf - -C / $K | zstd -T0 -3 -q | split -b 1G -a 2 - "$U/${N}k/part."
echo "kernel side packed: $(du -sh "$U/${N}k" | cut -f1) at $(( $(date +%s) - t )) s"
F="mac.img mac.conf trustcache.bin"; [ -e "$I/keystore.bin" ] && F="$F keystore.bin"
# shellcheck disable=SC2086
tar -cSf - -C "$I" $F | zstd -T0 -3 -q | split -b 1G -a 2 - "$U/$N/part."
echo "image packed: $(find "$U/$N" -name 'part.*' | wc -l) parts, $(du -sh "$U/$N" | cut -f1) at $(( $(date +%s) - t )) s"
for d in "$N" "${N}k"; do (cd "$U/$d"; for p in part.*; do echo "$p $(openssl md5 -binary "$p" | base64) $(stat -c %s "$p")"; done > WANT); done
cat "$U/$N"/part.* | zstd -d -q | tar -tvf - > "$U/$N.list"
cat "$U/${N}k"/part.* | zstd -d -q | tar -tf - | wc -l > "$U/${N}k.count"
echo "READBACK-OK $N: $(wc -l < "$U/$N.list") entries; ${N}k: $(cat "$U/${N}k.count") entries; total $(( $(date +%s) - t )) s"
df -h "$U" | tail -1
