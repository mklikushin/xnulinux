#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# boot the pristine target single-user (its own keys open its Data volume) with a raw payload disk for a tar of Data
# The vmapple stack's pieces come from the environment: VMAPPLE_DEPS (the prefix its libraries were installed to),
# VMAPPLE_QEMU, VMAPPLE_ROM; vmapple-cli is on PATH.
: "${VMAPPLE_DEPS:?} ${VMAPPLE_QEMU:?} ${VMAPPLE_ROM:?}"
export LD_LIBRARY_PATH=$VMAPPLE_DEPS/lib PATH=$VMAPPLE_DEPS/bin:$PATH
export VMAPPLE_ROM VMAPPLE_QEMU=${SIP_QEMU:-$HOME/xnuvm/qemu-sip/build/qemu-system-aarch64} QEMU_VMAPPLE_LP_SIP0=${LP_SIP0:-0x86f}
M=$HOME/xnuvm/mac
export VMAPPLE_QEMU_ARGS="-drive if=none,format=raw,file.filename=$M/payload.img,file.locking=off,id=x2 -device virtio-blk-pci,drive=x2"
cd $M; exec vmapple-cli boot xnu272 --boot-args="-s -v serial=11 debug=0x14c" --cpus 4 --memory 8
