#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# a new macOS install for xnulinux with vmapple-cli: mac-restore.sh RESTORE.ipsw
# The vmapple stack's pieces come from the environment: VMAPPLE_DEPS (the prefix its libraries were installed to),
# VMAPPLE_QEMU, VMAPPLE_ROM; vmapple-cli is on PATH.
: "${VMAPPLE_DEPS:?} ${VMAPPLE_QEMU:?} ${VMAPPLE_ROM:?}"
export LD_LIBRARY_PATH=$VMAPPLE_DEPS/lib PATH=$VMAPPLE_DEPS/bin:$PATH
export VMAPPLE_QEMU VMAPPLE_ROM
mkdir -p ~/xnuvm/mac; cd ~/xnuvm/mac
[ -f xnu272/vm.json ] || vmapple-cli create xnu272
exec vmapple-cli restore xnu272 "${1:?the restore IPSW}"
