#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build-gpu-bundle-linux.sh: (on the Linux host) cross-build XnuCpuMetal.bundle, the CPU Metal plugin of gpu/xnu-cpu-metal,
# for macOS arm64 + arm64e without a Mac. It follows gpu/xnu-cpu-metal/scripts/*.sh step by step, with LLVM's clang instead
# of Apple's, and a Linux build of Apple's open-source linker.
#
#   build-gpu-bundle-linux.sh --out DIR [--work DIR] [--sdk DIR] [--jobs N] [STAGE...]
#
#   --out DIR    where XnuCpuMetal.bundle goes (give DIR/XnuCpuMetal.bundle to build-disk-linux.sh --gpu-bundle)
#   --work DIR   sources and build trees, about 15 GB [XNU_GPU_WORK, default OUT-work]
#   --sdk DIR    a macOS SDK (headers and .tbd stubs) [XNU_GPU_SDK, default ~/w/dvm/toolchains/sdks/MacOSX26.1.sdk, where
#                scripts/vm-xnu-build.sh leaves the one it fetches]. The SDK is Apple's; this script does not fetch it.
#   --jobs N     parallel compile jobs [XNU_GPU_JOBS, default: the number of CPUs]
#   -h, --help   this text
#
# Stages, in order; with none named, all run. A stage is skipped when its output exists.
#   preflight  the host's tools: clang, lld and llvm 21 (or newer) from the distribution, cmake, ninja, meson >= 1.5,
#              glslangValidator, python3 with mako, git, curl. Changes nothing; prints the apt line for what is missing.
#   sources    gpu/xnu-cpu-metal/scripts/fetch-sources.sh (metal2vulkan, Vulkan-Loader, LLVM, Mesa, with this repository's
#              patches) and the Vulkan headers.
#   linker     Apple's ld64 for Linux: cctools-port built with apple-libtapi. It is needed for arm64e: LLVM's ld64.lld (21
#              and 22) has no authenticated-pointer relocations, and a cctools build without TAPI cannot read the SDK.
#   loader     the Khronos Vulkan loader, both architectures.
#   bridge     libxnu_m2v.dylib: Rust (rustup, into WORK) for arm64; nightly with -Zbuild-std, the symbol renames and
#              scripts/rust-pac-rewrite.py for arm64e.
#   llvm       LLVM's static libraries, both architectures, and three native helper programs. The long stage: about 2,230
#              compile steps for each architecture (29 minutes each with 4 jobs on 4 Neoverse V2 cores).
#   lavapipe   Mesa's lavapipe against them, both architectures.
#   bundle     the plugin itself, the universal files, the bundle folder.
#
# The bundle it makes is for your own use: it is not stripped, and its files contain the paths of WORK.
# No sudo. Nothing is installed outside WORK. Exit: 0 done, 1 a stage failed (its log is WORK/logs/STAGE.log), 2 wrong
# usage or a missing input, 3 this host lacks a tool.
#
# Status: new. On Ubuntu 26.04 arm64 (clang 21.1.8, SDK 26.1) the stages preflight, linker, loader, lavapipe (arm64
# half) and bundle ran in this form, and the bundle they made booted the hosted macOS 27.2 to a desktop. The stages
# sources, bridge and llvm, and the arm64e half of lavapipe, ran as the same commands by hand, not through this
# script; the script has not been run from nothing in one go. Not tested: other hosts, other SDKs, hours of use.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
PROG=build-gpu-bundle-linux; STAGES="preflight sources linker loader bridge llvm lavapipe bundle"
say() { echo "$PROG: $*"; }
err() { echo "$PROG: $*" >&2; }
die() { err "$1"; exit "${2:-1}"; }
OUT=${XNU_GPU_OUT:-}; WORK=${XNU_GPU_WORK:-}; SDK=${XNU_GPU_SDK:-$HOME/w/dvm/toolchains/sdks/MacOSX26.1.sdk}; JOBS=${XNU_GPU_JOBS:-$(nproc)}; RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '3,/^set /{/^#/!d;s/^# \{0,1\}//;p;}' "$0"; exit 0;;
    --out) OUT=${2:?}; shift 2;;
    --work) WORK=${2:?}; shift 2;;
    --sdk) SDK=${2:?}; shift 2;;
    --jobs) JOBS=${2:?}; shift 2;;
    -*) err "unknown option $1"; exit 2;;
    *) case " $STAGES " in *" $1 "*) RUN="$RUN $1";; *) err "unknown stage '$1' (stages: $STAGES)"; exit 2;; esac; shift;;
  esac
done
[ -n "$OUT" ] || { err "--out DIR is required"; err "try: $0 --help"; exit 2; }
[ -f "$SDK/System/Library/Frameworks/Metal.framework/Metal.tbd" ] || die "$SDK is not a macOS SDK (no Metal.framework/Metal.tbd): set --sdk" 2
[ -n "$RUN" ] || RUN=$STAGES
# shellcheck disable=SC1091
. "$HERE/build-disk-linux.lock" || die "cannot read $HERE/build-disk-linux.lock" 2
mkdir -p "$OUT" || die "cannot create $OUT" 2
OUT=$(cd "$OUT" && pwd); WORK=${WORK:-$OUT-work}; mkdir -p "$WORK/logs" || die "cannot create $WORK" 2
WORK=$(cd "$WORK" && pwd); G=$WORK/xnu-cpu-metal; O=$WORK/out; P=$WORK/cross; R=$WORK/rust
L=$(dirname "$(readlink -f "$(command -v clang-21 || command -v clang || echo /nonexistent)")")
export RUSTUP_HOME=$R/rustup CARGO_HOME=$R/cargo; export PATH=$CARGO_HOME/bin:$PATH
ARCHS="arm64 arm64e"
ldflags() { if [ "$1" = arm64 ]; then echo "-fuse-ld=lld -mlinker-version=1053"; else echo "--ld-path=$P/bin/aarch64-apple-darwin-ld -mlinker-version=711"; fi; }
resign() { python3 "$HERE/macho-adhoc-resign.py" "$@" > /dev/null; }

do_preflight() {
  local t missing=""
  for t in "$L/clang" "$L/ld64.lld" "$L/llvm-ar" "$L/llvm-objcopy" "$L/llvm-lipo" "$L/llvm-install-name-tool"; do [ -x "$t" ] || missing="$missing $(basename "$t")"; done
  for t in cmake ninja meson glslangValidator git curl python3 make; do command -v $t >/dev/null || missing="$missing $t"; done
  python3 -c 'import mako' 2>/dev/null || missing="$missing python3-mako"
  [ -z "$missing" ] || { err "missing:$missing. On Ubuntu: sudo apt-get install -y clang-21 lld-21 llvm-21 cmake ninja-build meson glslang-tools python3-mako git curl build-essential"; return 3; }
  say "host ok: $("$L/clang" --version | head -1), SDK $(basename "$SDK"), $JOBS jobs"
}
do_sources() {
  mkdir -p "$G" "$O" && cp -R "$REPO/gpu/xnu-cpu-metal/." "$G/" || return 1
  bash "$G/scripts/fetch-sources.sh" || return 1
  if [ ! -e "$O/vk-headers/include/vulkan/vulkan.h" ]; then
    [ -d "$O/Vulkan-Headers/.git" ] || git clone -q --depth 1 --branch "$GPU_VULKAN_TAG" https://github.com/KhronosGroup/Vulkan-Headers.git "$O/Vulkan-Headers" || return 1
    cmake -G Ninja -S "$O/Vulkan-Headers" -B "$O/vkh-build" -DCMAKE_INSTALL_PREFIX="$O/vk-headers" >/dev/null && ninja -C "$O/vkh-build" install >/dev/null || return 1
  fi
}
check_sources() { [ -e "$O/vk-headers/include/vulkan/vulkan.h" ] && [ -d "$G/src/mesa/src" ] && [ -d "$G/src/llvm-project/llvm" ] && [ -d "$G/src/metal2vulkan/crates" ]; }
fetch_at() {	# URL COMMIT DIR
  [ "$(git -C "$3" rev-parse HEAD 2>/dev/null)" = "$2" ] && return 0
  [ -d "$3/.git" ] || { git init -q "$3" && git -C "$3" remote add origin "$1"; } || return 1
  git -C "$3" fetch -q --depth 1 origin "$2" && git -C "$3" checkout -q FETCH_HEAD
}
do_linker() {
  export CC=$L/clang CXX=$L/clang++
  fetch_at "$GPU_LIBTAPI_URL" "$GPU_LIBTAPI_COMMIT" "$WORK/apple-libtapi" || { err "could not fetch apple-libtapi"; return 1; }
  fetch_at "$GPU_CCTOOLS_URL" "$GPU_CCTOOLS_COMMIT" "$WORK/cctools-port" || { err "could not fetch cctools-port"; return 1; }
  if [ ! -e "$P/lib/libtapi.so" ]; then (cd "$WORK/apple-libtapi" && INSTALLPREFIX=$P JOBS=$JOBS ./build.sh && ./install.sh) || { err "apple-libtapi did not build"; return 1; }; fi
  rm -rf "$WORK/cctools-build" && mkdir "$WORK/cctools-build" && cd "$WORK/cctools-build" || return 1
  "$WORK/cctools-port/cctools/configure" --prefix="$P" --target=aarch64-apple-darwin --with-libtapi="$P" && make -j"$JOBS" && make install || { err "cctools did not build"; return 1; }
  unset CC CXX
}
check_linker() { case "$("$P/bin/aarch64-apple-darwin-ld" -v 2>&1 || true)" in *arm64e*) return 0;; esac; return 1; }	# ld -v exits 1
toolchain_file() {	# ARCH: a CMake toolchain file for macOS ARCH
  cat > "$O/darwin-$1.cmake" <<T
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_SYSROOT $SDK)
set(CMAKE_OSX_ARCHITECTURES $1)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
set(CMAKE_C_COMPILER $L/clang)
set(CMAKE_CXX_COMPILER $L/clang++)
set(CMAKE_ASM_COMPILER $L/clang)
set(CMAKE_C_COMPILER_TARGET $1-apple-macos14.0)
set(CMAKE_CXX_COMPILER_TARGET $1-apple-macos14.0)
set(CMAKE_ASM_COMPILER_TARGET $1-apple-macos14.0)
set(CMAKE_AR $L/llvm-ar)
set(CMAKE_RANLIB $L/llvm-ranlib)
set(CMAKE_INSTALL_NAME_TOOL $L/llvm-install-name-tool)
set(CMAKE_EXE_LINKER_FLAGS_INIT "$(ldflags "$1")")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "$(ldflags "$1")")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "$(ldflags "$1")")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
T
}
do_loader() {
  local a
  for a in $ARCHS; do
    toolchain_file "$a"; rm -rf "$O/vkl-$a"
    cmake -G Ninja -S "$G/src/Vulkan-Loader" -B "$O/vkl-$a" -DCMAKE_TOOLCHAIN_FILE="$O/darwin-$a.cmake" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$O/vkl-$a-install" \
      -DSYSCONFDIR=/Library/GPUBundles/XnuCpuMetal.bundle/Contents/Resources -DVULKAN_HEADERS_INSTALL_DIR="$O/vk-headers" -DBUILD_TESTS=OFF && ninja -C "$O/vkl-$a" -j"$JOBS" install || return 1
  done
}
check_loader() { [ -s "$O/vkl-arm64-install/lib/libvulkan.1.dylib" ] && [ -s "$O/vkl-arm64e-install/lib/libvulkan.1.dylib" ]; }
cc_wrapper() {	# ARCH: a compiler driver for cargo and for C files
  printf '#!/bin/sh\nexec %s --target=%s-apple-macos11.0 -isysroot %s %s "$@"\n' "$L/clang" "$1" "$SDK" "$(ldflags "$1")" > "$O/cc-$1"; chmod +x "$O/cc-$1"
}
do_bridge() {
  local W=$O/m2v-arm64e A o
  if [ ! -x "$CARGO_HOME/bin/cargo" ]; then
    curl -fsSL https://sh.rustup.rs -o "$O/rustup-init.sh" && sh "$O/rustup-init.sh" -y --no-modify-path --profile minimal --default-toolchain "$GPU_RUST_STABLE" || { err "rustup failed"; return 1; }
  fi
  rustup target add aarch64-apple-darwin --toolchain "$GPU_RUST_STABLE" && rustup toolchain install "$GPU_RUST_NIGHTLY" --profile minimal --component rust-src || return 1
  cc_wrapper arm64; cc_wrapper arm64e
  export SDKROOT=$SDK MACOSX_DEPLOYMENT_TARGET=11.0
  cd "$G/src/xnu-m2v-bridge" || return 1
  CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER=$O/cc-arm64 CC_aarch64_apple_darwin=$O/cc-arm64 AR_aarch64_apple_darwin=$L/llvm-ar \
    cargo "+$GPU_RUST_STABLE" build --release --target aarch64-apple-darwin -j "$JOBS" || { err "the arm64 bridge did not build"; return 1; }
  CARGO_TARGET_ARM64E_APPLE_DARWIN_LINKER=$O/cc-arm64e CC_arm64e_apple_darwin=$O/cc-arm64e AR_arm64e_apple_darwin=$L/llvm-ar \
    cargo "+$GPU_RUST_NIGHTLY" build -Zbuild-std=std,panic_unwind --target arm64e-apple-darwin --release -j "$JOBS"
  A=target/arm64e-apple-darwin/release/libxnu_m2v.a
  [ -s "$A" ] || { err "the arm64e bridge library did not build"; return 1; }
  # from here: scripts/build-m2v-arm64e.sh steps 2 to 6
  rm -rf "$W" && mkdir -p "$W/objs" "$W/bin" || return 1
  "$O/cc-arm64e" -O2 -I"$O/vk-headers/include" -c "$G/src/AdrenoMetal/bridge/RustPacBoundary.c" -o "$W/RustPacBoundary.o" || return 1
  (cd "$W/objs" && "$L/llvm-ar" x "$G/src/xnu-m2v-bridge/$A") || return 1
  for o in "$W"/objs/*.o; do
    "$L/llvm-objcopy" --redefine-sym _pthread_create=_nmb_pac_pthread_create --redefine-sym __tlv_atexit=_nmb_pac_tlv_atexit --redefine-sym _atexit=_nmb_pac_atexit \
      --redefine-sym ___cxa_atexit=_nmb_pac_cxa_atexit --redefine-sym __dyld_register_func_for_add_image=_nmb_pac_dyld_register_func_for_add_image \
      --redefine-sym __Unwind_Backtrace=_nmb_pac_Unwind_Backtrace --redefine-sym _dlsym=_nmb_pac_dlsym "$o" "$o.tmp" && mv "$o.tmp" "$o" || return 1
  done
  "$L/llvm-ar" rcs "$W/libxnu_m2v_pac.a" "$W"/objs/*.o || return 1
  "$O/cc-arm64e" -dynamiclib -Wl,-force_load,"$W/libxnu_m2v_pac.a" "$W/RustPacBoundary.o" -liconv -lSystem -install_name @rpath/libxnu_m2v.dylib -o "$W/libxnu_m2v.dylib" || { err "the arm64e bridge did not link"; return 1; }
  ln -sf "$P/bin/aarch64-apple-darwin-nm" "$W/bin/nm"	# rust-pac-rewrite.py calls plain `nm`
  PATH=$W/bin:$PATH python3 "$G/scripts/rust-pac-rewrite.py" "$W/libxnu_m2v.dylib" || { err "the pointer-authentication rewrite failed"; return 1; }
  resign "$W/libxnu_m2v.dylib"
}
check_bridge() { [ -s "$G/src/xnu-m2v-bridge/target/aarch64-apple-darwin/release/libxnu_m2v.dylib" ] && [ -s "$O/m2v-arm64e/libxnu_m2v.dylib" ]; }
do_llvm() {
  local a NB=$O/llvm-native I
  # Native helper programs first, from the same source: tblgen for the cross builds, and an llvm-config that this host can
  # run (a cross build makes none, and Mesa's build has to ask one for the libraries).
  if [ ! -x "$NB/bin/llvm-config" ] || [ ! -x "$NB/bin/llvm-tblgen" ]; then
    cmake -G Ninja -S "$G/src/llvm-project/llvm" -B "$NB" -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$L/clang" -DCMAKE_CXX_COMPILER="$L/clang++" \
      -DLLVM_TARGETS_TO_BUILD=AArch64 -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF -DLLVM_ENABLE_ZSTD=OFF \
      -DLLVM_ENABLE_ZLIB=ON -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_RTTI=ON -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
      && ninja -C "$NB" -j"$JOBS" llvm-config llvm-tblgen llvm-min-tblgen || { err "LLVM's native helper programs did not build"; return 1; }
  fi
  for a in $ARCHS; do
    I=$O/llvm-$a-install
    if [ ! -e "$I/lib/libLLVMCore.a" ]; then
      toolchain_file "$a"
      cmake -G Ninja -S "$G/src/llvm-project/llvm" -B "$O/llvm-$a" -DCMAKE_TOOLCHAIN_FILE="$O/darwin-$a.cmake" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$I" \
        -DLLVM_TARGETS_TO_BUILD=AArch64 -DLLVM_DEFAULT_TARGET_TRIPLE="$a-apple-darwin" -DLLVM_HOST_TRIPLE="$a-apple-darwin" -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF -DLLVM_BUILD_UTILS=OFF -DLLVM_BUILD_TOOLS=OFF -DLLVM_TOOL_LLVM_CONFIG_BUILD=ON -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_ZLIB=ON -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_RTTI=ON -DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
        -DLLVM_NATIVE_TOOL_DIR="$NB/bin" && ninja -C "$O/llvm-$a" -j"$JOBS" install || { err "LLVM for $a did not build"; return 1; }
    fi
    # the native llvm-config, placed in the cross install so that it reports that tree, minus the system libraries that only
    # exist on Linux
    mkdir -p "$I/bin" && cp -f "$NB/bin/llvm-config" "$I/bin/llvm-config.real" || return 1
    printf '#!/bin/sh\n"%s/bin/llvm-config.real" "$@" | sed "s/ -lrt//g; s/-lrt //g; s/ -ldl//g; s/-ldl //g; s/ -lpthread//g; s/-lpthread //g"\n' "$I" > "$I/bin/llvm-config"
    chmod +x "$I/bin/llvm-config"
  done
}
check_llvm() { "$O/llvm-arm64-install/bin/llvm-config" --version >/dev/null 2>&1 && "$O/llvm-arm64e-install/bin/llvm-config" --version >/dev/null 2>&1 && [ -e "$O/llvm-arm64e-install/lib/libLLVMCore.a" ]; }
do_lavapipe() {
  local a c
  mkdir -p "$O/empty-pc"
  for a in $ARCHS; do
    [ -s "$O/lavapipe-$a/lib/libvulkan_lvp.dylib" ] && continue
    # The compilers are wrapper scripts that carry the linker choice: meson finds the linker with a bare `-Wl,--version`, and
    # without it clang on Linux reaches for the host's ld. -Qunused-arguments, because meson's configure checks compile with
    # -Werror and "argument unused during compilation: -fuse-ld=lld" would make every check fail.
    for c in clang clang++; do
      printf '#!/bin/sh\nexec %s/%s --target=%s-apple-macos14.0 -isysroot %s %s -Qunused-arguments "$@"\n' "$L" "$c" "$a" "$SDK" "$(ldflags "$a")" > "$O/m$c-$a"; chmod +x "$O/m$c-$a"
    done
    cat > "$O/meson-$a.ini" <<M
[binaries]
c = '$O/mclang-$a'
cpp = '$O/mclang++-$a'
objc = '$O/mclang-$a'
objcpp = '$O/mclang++-$a'
ar = '$L/llvm-ar'
strip = '$L/llvm-strip'
llvm-config = '$O/llvm-$a-install/bin/llvm-config'
pkg-config = 'pkg-config'
[properties]
pkg_config_libdir = '$O/empty-pc'
needs_exe_wrapper = true
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
M
    rm -rf "$O/mesa-$a"
    meson setup "$O/mesa-$a" "$G/src/mesa" --cross-file "$O/meson-$a.ini" --prefix="$O/lavapipe-$a" --buildtype=release -Dplatforms= -Dgallium-drivers=llvmpipe \
      -Dvulkan-drivers=swrast -Dglx=disabled -Degl=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dllvm=enabled -Dshared-llvm=disabled -Dzstd=disabled \
      -Dxmlconfig=disabled -Dshader-cache=enabled -Dshader-cache-max-size=256M -Dvideo-codecs= -Dvalgrind=disabled -Dlibunwind=disabled -Dbuild-tests=false \
      && ninja -C "$O/mesa-$a" -j"$JOBS" install || { err "lavapipe for $a did not build"; return 1; }
  done
}
check_lavapipe() { [ -s "$O/lavapipe-arm64/lib/libvulkan_lvp.dylib" ] && [ -s "$O/lavapipe-arm64e/lib/libvulkan_lvp.dylib" ]; }
do_bundle() {
  local B=$OUT/XnuCpuMetal.bundle T=$O/bundle-tmp a n
  rm -rf "$B" "$T"; mkdir -p "$B/Contents/MacOS" "$B/Contents/Frameworks" "$B/Contents/Resources/vulkan/icd.d" "$T" || return 1
  cp "$G/src/xnu-cpu-metal-bundle/Info.plist" "$B/Contents/Info.plist"
  thin() { cp -L "$2" "$T/$1" && chmod u+w "$T/$1" && "$L/llvm-install-name-tool" -id "@rpath/${1%.arm64*}" "$T/$1" && resign "$T/$1"; }
  thin libxnu_m2v.dylib.arm64 "$G/src/xnu-m2v-bridge/target/aarch64-apple-darwin/release/libxnu_m2v.dylib" && thin libxnu_m2v.dylib.arm64e "$O/m2v-arm64e/libxnu_m2v.dylib" &&
    thin libvulkan.1.dylib.arm64 "$O/vkl-arm64-install/lib/libvulkan.1.dylib" && thin libvulkan.1.dylib.arm64e "$O/vkl-arm64e-install/lib/libvulkan.1.dylib" &&
    thin libvulkan_lvp.dylib.arm64 "$O/lavapipe-arm64/lib/libvulkan_lvp.dylib" && thin libvulkan_lvp.dylib.arm64e "$O/lavapipe-arm64e/lib/libvulkan_lvp.dylib" || return 1
  for n in libxnu_m2v.dylib libvulkan.1.dylib libvulkan_lvp.dylib; do "$L/llvm-lipo" -create "$T/$n.arm64" "$T/$n.arm64e" -output "$B/Contents/Frameworks/$n" || return 1; done
  for a in $ARCHS; do
    # shellcheck disable=SC2046
    "$L/clang++" --target="$a-apple-macos14.0" -isysroot "$SDK" $(ldflags "$a") -bundle -O2 -std=c++20 -fobjc-arc -F"$SDK/System/Library/PrivateFrameworks" \
      -I"$G/src/xnu-m2v-bridge/include" -I"$G/src/xnu-cpu-metal-bundle" "$G/src/xnu-cpu-metal-bundle/XnuCpuMetalPlugin.mm" -L"$B/Contents/Frameworks" -lxnu_m2v \
      -Wl,-rpath,@loader_path/../Frameworks -framework Foundation -framework Metal -framework IOKit -framework IOSurface -framework IOGPU -o "$T/XnuCpuMetal.$a" || return 1
  done
  "$L/llvm-lipo" -create "$T/XnuCpuMetal.arm64" "$T/XnuCpuMetal.arm64e" -output "$B/Contents/MacOS/XnuCpuMetal" || return 1
  icd() { printf '{\n    "ICD": {\n        "api_version": "1.4.363",\n        "library_arch": "64",\n        "library_path": "%s"\n    },\n    "file_format_version": "1.0.1"\n}\n' "$1"; }
  icd ../Frameworks/libvulkan_lvp.dylib > "$B/Contents/Resources/lvp_icd.aarch64.json"
  icd ../../../Frameworks/libvulkan_lvp.dylib > "$B/Contents/Resources/vulkan/icd.d/lvp_icd.aarch64.json"
  rm -rf "$T"
}
check_bundle() {
  local f
  for f in MacOS/XnuCpuMetal Frameworks/libxnu_m2v.dylib Frameworks/libvulkan.1.dylib Frameworks/libvulkan_lvp.dylib; do
    case "$("$L/llvm-lipo" -archs "$OUT/XnuCpuMetal.bundle/Contents/$f" 2>/dev/null)" in "arm64 arm64e"*) ;; *) return 1;; esac
  done
}
check_preflight() { return 1; }

for s in $STAGES; do
  case " $RUN " in *" $s "*) ;; *) continue;; esac
  if "check_$s" 2>/dev/null; then say "$s: already done, skipped"; continue; fi
  say "$s: start"; t0=$(date +%s)
  if [ "$s" = preflight ]; then do_preflight; rc=$?; else "do_$s" > "$WORK/logs/$s.log" 2>&1; rc=$?; fi
  [ $rc = 0 ] || { err "stage $s failed (status $rc); see $WORK/logs/$s.log. Fix the cause and run the same command again."; exit $rc; }
  [ "$s" = preflight ] || "check_$s" || { err "stage $s ran but its output is not there; see $WORK/logs/$s.log"; exit 1; }
  say "$s: done in $(( $(date +%s) - t0 )) s"
done
if check_bundle; then say "bundle ready: $OUT/XnuCpuMetal.bundle"; du -sh "$OUT/XnuCpuMetal.bundle"; fi
