# SPDX-License-Identifier: GPL-2.0-only
# Build a copy of the vmapple QEMU with qemu-vmapple-lp-sip0.patch: SRC=<its checkout (deps/reims-vgpu, deps/metal2vulkan)> build.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd); : "${SRC:?}"; W=${W:-$HOME/xnuvm/qemu-sip}; mkdir -p "$W"; cd "$W"
[ -d reims-vgpu ] || cp -a "$SRC/deps/reims-vgpu" reims-vgpu
[ -d metal2vulkan ] || cp -a "$SRC/deps/metal2vulkan" metal2vulkan
grep -q QEMU_VMAPPLE_LP_SIP0 reims-vgpu/vendor/qemu/target/arm/kvm.c || patch -d reims-vgpu/vendor/qemu -p1 < "$HERE/qemu-vmapple-lp-sip0.patch"
mkdir -p build && cd build
export PATH=$SRC/.venv/bin:$HOME/.cargo/bin:/usr/lib/llvm-20/bin:$PATH
[ -f build.ninja ] || ../reims-vgpu/vendor/qemu/configure --target-list=aarch64-softmmu --enable-kvm --enable-tcg --enable-slirp --enable-fdt --disable-docs --disable-werror --disable-gtk --disable-sdl --disable-vnc --disable-capstone --disable-rust --enable-download --python=$SRC/.venv/bin/python3 -Dreims_vgpu_backend=vulkan
ninja qemu-system-aarch64
