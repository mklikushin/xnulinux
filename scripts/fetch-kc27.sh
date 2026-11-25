#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# On the arm64 Linux host, after scripts/vm-xnu-build.sh: the kernel collection's input, out/kc/kc27.bin in the DroidVM tree
# (~/w/dvm). It is the kernelcache of Apple's virtual Mac (kernelcache.release.vma2) from the macOS 27.2 (26B123) restore
# image, whose kexts scripts/vm-xnu-rebuild.sh links with the source-built kernel. Only that member is downloaded (HTTP
# ranges of the 25 GB image, about 23 MB) with DroidVM's own scripts, which check it against Apple's manifest; blacktop's
# ipsw unwraps it. Apple's file stays on this machine: it is never in the repository.
set -euo pipefail
cd "${DVM:-$HOME/w/dvm}"
if [ -s out/kc/kc27.bin ]; then ls -la out/kc/kc27.bin; exit 0; fi
case $(uname -m) in aarch64 | arm64) A=arm64 ;; x86_64) A=x86_64 ;; *) echo "fetch-kc27: no ipsw build for $(uname -m)" >&2; exit 1 ;; esac
V=${IPSW_VERSION:-3.1.749}
mkdir -p toolchains/ipsw out/kc
# DroidVM's lock names the x86_64 build: take the one this machine runs
toolchains/ipsw/ipsw version >/dev/null 2>&1 ||
  curl -fsSL "https://github.com/blacktop/ipsw/releases/download/v$V/ipsw_${V}_linux_$A.tar.gz" | tar -C toolchains/ipsw -xz ipsw
P=configs/macos-27.2-26B123.json; O=artifacts/27.2
try() {	# Apple's CDN now and then cuts a range short ("incorrect range length"): the scripts keep what they have
  local i
  for i in 1 2 3 4 5; do "$@" >/dev/null && return 0; echo "fetch-kc27: attempt $i failed, trying again" >&2; sleep 3; done
  return 1
}
[ -s $O/inventory-26B123/identities.json ] || try python3 scripts/macos-inputs.py --profile $P --output $O/inventory-26B123
[ -s $O/kernelcache.release.vma2 ] ||
  try python3 scripts/macos-fetch-member.py KernelCache --profile $P --inventory $O/inventory-26B123/identities.json \
    --identity vma2macosap --output-dir $O --jobs 8
toolchains/ipsw/ipsw img4 im4p extract -o out/kc/kc27.bin $O/kernelcache.release.vma2 >/dev/null
ls -la out/kc/kc27.bin
