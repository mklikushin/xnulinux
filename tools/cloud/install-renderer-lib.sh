#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# install-renderer-lib.sh LIB.gz [MD5]: (on your own machine) put a rebuilt CPU renderer (a gzip of the universal
# libvulkan_lvp.dylib from gpu/xnu-cpu-metal) into the running hosted macOS's GPU bundle, without rebuilding the disk.
# The file goes through the VM to the guest, is unpacked, compared with MD5 (of the unpacked library) when given, and
# moved into /Library/GPUBundles/XnuCpuMetal.bundle/Contents/Frameworks as root. The first original is kept beside
# it as libvulkan_lvp.dylib.orig. New processes load the new library; the window server at its next start (reboot the
# hosted system). To go back: copy the .orig over it the same way.
# Root in the guest: the password is read from GUEST_PASSWORD_FILE and sent to sudo over ssh's stdin, never shown.
# Safe to run again with the same file.
# Exit: 0 installed (prints the installed MD5), 1 failed or MD5 mismatch (nothing replaced), 2 wrong usage.
# Status: only syntax-checked in this cleaned form; the private original (which fetched the file from the build Mac
# itself) installed the fixed renderer.
. "$(dirname "$0")/lib.sh"
set -euo pipefail
[ "${1:-}" = --help ] || [ "${1:-}" = -h ] && { show_help; exit 0; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage_error "usage: install-renderer-lib.sh LIB.gz [MD5]"
[ -r "$1" ] || usage_error "cannot read $1"
case "${2:-}" in *[!0-9a-f]*) usage_error "MD5 must be lower-case hex";; esac
need GUEST_PASSWORD_FILE; need_file "$GUEST_PASSWORD_FILE" "the guest user's password, one line"
h=$(vm_host); g=$(guest_ip); mkdir -p "$CLOUD_STATE"
scp -q -i "$GUEST_KEY" "${SSH_OPTS[@]}" -o "ProxyCommand=ssh -i $VM_KEY ${SSH_OPTS[*]} -W %h:%p $VM_USER@$h" \
  "$1" "$GUEST_USER@$g:/var/tmp/xnu-lvp.gz" || die "could not copy $1 into the guest"
guest_ssh "cd /var/tmp && gunzip -c xnu-lvp.gz > libvulkan_lvp.dylib && { [ -z '${2:-}' ] || [ \$(md5 -q libvulkan_lvp.dylib) = '${2:-}' ] || { echo 'MD5 mismatch: nothing replaced' >&2; exit 1; }; } && sudo -S -p '' sh -c 'F=/Library/GPUBundles/XnuCpuMetal.bundle/Contents/Frameworks; [ -f \$F/libvulkan_lvp.dylib.orig ] || cp -p \$F/libvulkan_lvp.dylib \$F/libvulkan_lvp.dylib.orig; cp /var/tmp/libvulkan_lvp.dylib \$F/n.tmp && chown root:wheel \$F/n.tmp && chmod 755 \$F/n.tmp && mv \$F/n.tmp \$F/libvulkan_lvp.dylib && md5 -q \$F/libvulkan_lvp.dylib'" < "$GUEST_PASSWORD_FILE" \
  || die "not installed"
echo "installed"
