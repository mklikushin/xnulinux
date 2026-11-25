#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build-disk.sh STAGE: (on an Apple silicon Mac, macOS 27 host) make the hosted system's disk for a cloud ARM VM with no
# GPU: ~/xnubuild/macvm/{mac.img,mac.conf,trustcache.bin}. It drives the repository's own scripts (gpu/xnu-cpu-metal,
# scripts/mk-macvm-disk.sh) and adds what a rented, headless Mac needs. See docs/cloud-arm.md.
#
#   build-disk.sh preflight          facts about this Mac; changes nothing
#   build-disk.sh sudoers            passwordless sudo for this user (asks the password once; mk-macvm-disk.sh uses sudo -n)
#   build-disk.sh deps               Homebrew, tart, build tools, Rust, this repository
#   build-disk.sh vm                 tart VM "xnumac" from the macOS restore image, one headless first boot, stopped
#   build-disk.sh gpu                gpu/xnu-cpu-metal -> dist/XnuCpuMetal.bundle (the CPU Metal plugin)
#   build-disk.sh disk               scripts/mk-macvm-disk.sh without its copy into a local Linux VM
#   build-disk.sh upload USER@HOST [DIR=/var/tmp/macimg]   the three files to a Linux host over ssh (slow over long
#                                    distances: 3 MB/s was measured between continents; see pack-image.sh for the other way)
#   build-disk.sh all                deps, then vm and gpu in parallel, then disk
# Every stage can be run again; each logs to ~/xnubuild/logs/<stage>.log. Long stages (vm, gpu, all): run them inside
# tmux or with nohup, and read the log.
#
# Environment:
#   IPSW       REQUIRED for vm: the macOS restore image for Apple silicon from Apple, as a local path or Apple's own URL.
#              It must be the build your kernel collection is made for (the guide used macOS 27.2, build 26B123).
#              "latest" lets tart pick the newest one; the kernel side must then match that build.
#   REPO_URL, REPO_REF   where deps clones this repository from (default: upstream's main; set them to the fork and
#              branch you are reading when you need its fixes in the GPU bundle)
#   VM_CPUS=4 VM_MEM_MB=8192 VM_DISK_GB=50   the tart VM (mac.img is VM_DISK_GB, sparse)
#   FIRST_BOOT_SECS=240   how long the installed VM runs once before it is stopped
#   GPU_STUB=1            disk: go on with an empty XnuCpuMetal.bundle (console shell works, no desktop)
#   EXTRAS=1              disk: the guest user gets the password in GUEST_PASSWORD_FILE (a file you name, one line, never
#                         printed; it is passed to tools/hosted/gui-user.py as an argument, so it is visible in the Mac's
#                         process list for a moment) and disk-extras.sh runs (Remote Login, Screen Sharing, your ssh
#                         public key from GUEST_PUBKEY_FILE)
#   APPS=DIR              disk: every *.app in DIR is copied to the image's /Applications (mk-macvm-disk.sh does this)
#   VM=xnumac W=~/xnubuild/macvm   tart VM name and output directory (a second image: VM=xnumac2 W=~/xnubuild/macvm2)
#   UPLOAD_KEY            upload: private key for USER@HOST (default: your ssh agent or default key)
# Exit: 0 the stage finished, 1 it failed (the log says where), 2 unknown stage.
# Status: only syntax-checked in this cleaned form. The private original ran every stage except "upload" on a rented
# Mac (whole build 8 minutes once the guest was installed); "upload" and the SPIRV-Tools step inside "gpu" are rewritten
# here from what was done by hand and have not run as written.
set -euo pipefail
B=${B:-$HOME/xnubuild}; REPO=$B/xnulinux; LOGS=$B/logs; W=${W:-$B/macvm}
IPSW=${IPSW:-}; REPO_URL=${REPO_URL:-https://github.com/AFK-surf/xnulinux.git}; REPO_REF=${REPO_REF:-main}
HERE=$(cd "$(dirname "$0")" && pwd)
VM=${VM:-xnumac}
export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.cargo/bin:$PATH
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 NONINTERACTIVE=1
case "${1:-}" in -h|--help) sed -n '3,/^set /{/^#/!d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;; esac
mkdir -p "$LOGS" "$W"
say() { printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
need_sudo() { sudo -n true 2>/dev/null || { echo "sudo needs a password: run '$0 sudoers' first" >&2; exit 1; }; }

preflight() {
  say "host: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM, $(sysctl -n hw.ncpu) CPUs"
  say "arch: $(uname -m); user: $(id -un) (groups: $(id -Gn | tr ' ' ','))"
  say "free on /: $(df -g / | awk 'NR==2{print $4}') GB (need about 80)"
  say "virtualization: kern.hv_support=$(sysctl -n kern.hv_support 2>/dev/null || echo ?), hv_vmm_present=$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo ?) (1 here = this Mac is itself a VM: tart will not work)"
  say "developer tools: $(xcodebuild -version 2>&1 | tr '\n' ' ')"
  say "developer dir: $(xcode-select -p 2>&1); sdk: $(xcrun --show-sdk-path 2>&1)"
  say "clang: $(/usr/bin/clang --version 2>&1 | head -1)"
  say "brew: $(command -v brew || echo none); tart: $(tart --version 2>/dev/null || echo none); rustup: $(rustup --version 2>/dev/null | head -1 || echo none)"
  say "sudo without password: $(sudo -n true 2>/dev/null && echo yes || echo no)"
  say "SIP: $(csrutil status 2>&1 | head -1)"
  say "sleep settings: $(pmset -g | awk '/ sleep |disksleep|displaysleep/{printf "%s=%s ", $1, $2}')"
  tart list 2>/dev/null || true
}

sudoers() {
  u=$(id -un); f=/etc/sudoers.d/xnulinux
  echo "$u ALL=(ALL) NOPASSWD: ALL" | sudo tee "$f" >/dev/null   # asks the password here
  sudo chmod 440 "$f"; sudo visudo -cf "$f"
  sudo pmset -a sleep 0 disksleep 0 displaysleep 0 >/dev/null 2>&1 || true   # no sleep during the build
  say "passwordless sudo for $u; sleep off"
}

deps() {
  need_sudo
  if ! command -v brew >/dev/null; then
    say "installing Homebrew (also installs the Command Line Tools when missing)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  # tart moved from cirruslabs/cli to openai/tools (the old tap's tap_migrations.json says so)
  brew untap cirruslabs/cli 2>/dev/null || true
  brew tap openai/tools; brew trust openai/tools   # Homebrew ignores a third-party tap until it is trusted (tart needs its softnet)
  command -v tart >/dev/null || brew install openai/tools/tart || true   # brew exits 1 on a harmless 'fix install linkage' chmod error; checked below
  for f in zstd cmake ninja meson pkg-config llvm@22 python@3.13 bison flex glslang; do brew list "$f" >/dev/null 2>&1 || brew install "$f" || echo "brew: $f failed"; done
  command -v tart >/dev/null || { echo "tart did not install" >&2; exit 1; }
  brew list --versions tart zstd cmake ninja meson llvm@22 glslang || true
  if ! command -v rustup >/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
  fi
  rustup toolchain install 1.100.0 --profile minimal --target aarch64-apple-darwin
  rustup toolchain install nightly-aarch64-apple-darwin --profile minimal --component rust-src
  [ -d "$REPO/.git" ] || git clone --branch "$REPO_REF" "$REPO_URL" "$REPO"
  git -C "$REPO" log -1 --format='xnulinux %h %cd'
}

vm() {
  command -v tart >/dev/null || { echo "tart missing: run deps" >&2; exit 1; }
  [ -n "$IPSW" ] || { echo "IPSW is not set: the macOS restore image (path or Apple's URL) for the build your kernel collection matches, or 'latest'" >&2; exit 1; }
  # Virtualization.framework starts a macOS guest only when this user has a desktop session (automatic login on a rented Mac:
  # autologin.py + reboot). Without one: "The virtual machine failed to start".
  launchctl print "gui/$(id -u)" >/dev/null 2>&1 || { echo "no desktop session for $(id -un): log in at the screen or set automatic login and reboot" >&2; exit 1; }
  D=$HOME/.tart/vms/$VM
  if [ ! -e "$D/disk.img" ]; then
    say "tart create $VM from $IPSW (download about 25 GB, then Apple's installer: 20-40 min)"
    tart create "$VM" --from-ipsw "$IPSW" --disk-size "${VM_DISK_GB:-50}"
  else
    say "tart VM $VM exists: not reinstalled (tart delete $VM to start over)"
  fi
  tart set "$VM" --cpu "${VM_CPUS:-4}" --memory "${VM_MEM_MB:-8192}"
  if [ ! -e "$D/.xnu-first-boot" ]; then
    # mk-macvm-disk.sh expects a disk that has booted once (first-boot data migration, keybag, Preboot cryptexes).
    # gui-user.py later makes the user and marks Setup Assistant done, so nobody has to click through it.
    say "first boot, headless, ${FIRST_BOOT_SECS:-240} s"
    nohup tart run "$VM" --no-graphics > "$LOGS/tart-run.log" 2>&1 &
    sleep "${FIRST_BOOT_SECS:-240}"
    tart list
    tart stop "$VM" --timeout 60 || true
    sleep 5; pgrep -fl "tart run $VM" && pkill -f "tart run $VM" || true
    touch "$D/.xnu-first-boot"
  fi
  ls -la "$D"; du -sh "$D/disk.img"
  say "vm stage done"
}

gpu() {
  # gpu/xnu-cpu-metal's scripts expect build/pyvenv and build/vk-deps (Vulkan headers and loader 1.4.363.0,
  # glslangValidator) to exist; they are made here, from the paths those scripts use.
  G=$REPO/gpu/xnu-cpu-metal; cd "$G"
  # Homebrew's spirv-tools comes in with glslang. When pkg-config sees it, Mesa compiles SPIRV-Tools calls into lavapipe
  # but links without the library, and the driver fails to load in the hosted system ("symbol not found in flat
  # namespace '_spvBinaryToText'"; the window server then aborts). Hide it and drop builds made with it visible.
  if pkg-config --exists SPIRV-Tools 2>/dev/null; then
    brew unlink spirv-tools >/dev/null 2>&1 || true
    pkg-config --exists SPIRV-Tools 2>/dev/null && { echo "SPIRV-Tools is still visible to pkg-config: remove it from PKG_CONFIG_PATH" >&2; exit 1; }
    rm -rf build/mesa-lvp build/mesa-lvp-arm64e dist/lavapipe dist/lavapipe-arm64e
  fi
  xcrun --show-sdk-path >/dev/null
  # Mesa needs Python >= 3.10; the system python3 is 3.9, so the venv comes from Homebrew's
  build/pyvenv/bin/python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null || rm -rf build/pyvenv build/mesa-lvp build/mesa-lvp-arm64e
  [ -x build/pyvenv/bin/meson ] || { /opt/homebrew/bin/python3.13 -m venv build/pyvenv; build/pyvenv/bin/pip -q install meson mako pyyaml packaging ninja; }
  bash scripts/fetch-sources.sh
  V=1.4.363.0; K=$G/build/vk-deps
  if [ ! -e "$K/vulkan-headers/$V/include/vulkan/vulkan.h" ]; then
    rm -rf build/Vulkan-Headers; git clone -q --depth 1 --branch vulkan-sdk-$V https://github.com/KhronosGroup/Vulkan-Headers.git build/Vulkan-Headers
    cmake -G Ninja -S build/Vulkan-Headers -B build/vkh -DCMAKE_INSTALL_PREFIX="$K/vulkan-headers/$V" >/dev/null
    ninja -C build/vkh install >/dev/null
  fi
  if [ ! -e "$K/vulkan-loader/$V/lib/libvulkan.1.4.363.dylib" ]; then
    cmake -G Ninja -S src/Vulkan-Loader -B build/vkl-host -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_INSTALL_PREFIX="$K/vulkan-loader/$V" -DVULKAN_HEADERS_INSTALL_DIR="$K/vulkan-headers/$V" -DBUILD_TESTS=OFF >/dev/null
    ninja -C build/vkl-host install >/dev/null
  fi
  mkdir -p "$K/bin"; [ -e "$K/bin/glslangValidator" ] || ln -sf "$(command -v glslangValidator || command -v glslang)" "$K/bin/glslangValidator"
  [ -x build/llvm-arm64e-install/bin/llvm-config ] || { say "llvm arm64e (the long one)"; bash scripts/build-llvm-arm64e.sh; }
  say lavapipe;        bash scripts/build-lavapipe.sh
  say lavapipe-arm64e; bash scripts/build-lavapipe-arm64e.sh
  say m2v;             bash scripts/build-m2v.sh
  say m2v-arm64e;      bash scripts/build-m2v-arm64e.sh
  say vkloader;        bash scripts/build-vkloader-arm64e.sh
  say bundle;          bash scripts/build-bundle-universal.sh
  ls -la dist/XnuCpuMetal.bundle/Contents/MacOS dist/XnuCpuMetal.bundle/Contents/Frameworks
  for d in dist/XnuCpuMetal.bundle/Contents/Frameworks/*.dylib; do
    n=$(nm -arch arm64 -u "$d" 2>/dev/null | grep -ci _spv || true); [ "$n" = 0 ] || { echo "$(basename "$d") has $n undefined SPIRV-Tools symbols: it will not load" >&2; exit 1; }
  done
  lipo -info dist/XnuCpuMetal.bundle/Contents/MacOS/XnuCpuMetal
  say "gpu stage done"
}

disk() {
  need_sudo
  SRC=$HOME/.tart/vms/$VM/disk.img; [ -e "$SRC" ] || { echo "no $SRC: run vm" >&2; exit 1; }
  tart list | awk -v v="$VM" '$2==v && /running/{f=1} END{exit f}' || { echo "$VM is running: tart stop $VM" >&2; exit 1; }
  GPUB=$REPO/gpu/xnu-cpu-metal/dist/XnuCpuMetal.bundle
  if [ ! -d "$GPUB" ]; then
    [ "${GPU_STUB:-0}" = 1 ] || { echo "no $GPUB: run gpu, or GPU_STUB=1 for a disk without the Metal plugin" >&2; exit 1; }
    GPUB=$B/stub/XnuCpuMetal.bundle; mkdir -p "$GPUB/Contents"; say "GPU_STUB: empty bundle (console shell only, no desktop)"
  fi
  # the repository's script ends by sending the files to a Linux VM on the same Mac (scripts/vm.sh): cut that part
  cd "$REPO"
  awk '/^t0=\$\(date \+%s\)$/{exit} {print}' scripts/mk-macvm-disk.sh > scripts/.mk-macvm-disk-noupload.sh
  grep -q 'cleanup; trap - EXIT' scripts/.mk-macvm-disk-noupload.sh || { echo "mk-macvm-disk.sh changed: check the cut" >&2; exit 1; }
  if [ "${EXTRAS:-0}" = 1 ]; then
    # own password for the guest user, and disk-extras.sh (Remote Login, Screen Sharing, ssh key) run while the Data volume is mounted
    [ -s "${GUEST_PASSWORD_FILE:-}" ] || { echo "EXTRAS=1 needs GUEST_PASSWORD_FILE: a file with the guest user's password on one line" >&2; exit 1; }
    python3 - scripts/.mk-macvm-disk-noupload.sh <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
a = 'sudo -n python3 tools/hosted/gui-user.py "$D" "$W/sys/System/Library/User Template"\n'
b = 'sudo -n python3 scripts/extract-trustcache.py'
assert a in s and b in s, "mk-macvm-disk.sh changed"
s = s.replace(a, a[:-1] + ' xnu "$(cat "$XNU_PASS_FILE")"\n')
s = s.replace(b, '. "$EXTRA_HOOK"\n' + b, 1)
open(p, "w").write(s)
PY
    export XNU_PASS_FILE=$GUEST_PASSWORD_FILE EXTRA_HOOK=$HERE/disk-extras.sh GUEST_PUBKEY_FILE=${GUEST_PUBKEY_FILE:-}
  fi
  SRC=$SRC W=$W GPU=$GPUB bash scripts/.mk-macvm-disk-noupload.sh
  ls -la "$W"/mac.img "$W"/mac.conf "$W"/trustcache.bin; du -sh "$W/mac.img"; cat "$W/mac.conf"
  say "disk stage done"
}

upload() {
  T=${1:?usage: upload USER@HOST [DIR]}; DEST=${2:-/var/tmp/macimg}
  S=(ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30); [ -z "${UPLOAD_KEY:-}" ] || S+=(-i "$UPLOAD_KEY")
  "${S[@]}" "$T" "mkdir -p '$DEST'; df -h '$DEST' | tail -1; command -v zstd >/dev/null || sudo apt-get install -y zstd >/dev/null"
  cd "$W"; t0=$(date +%s)
  # bsdtar records the holes of a sparse file by itself; GNU tar -S on the Linux side writes them back as holes
  tar -cf - mac.img mac.conf trustcache.bin | zstd -T0 -3 | "${S[@]}" "$T" "cd '$DEST' && rm -f mac.img && zstd -d | tar -xSf - && ls -ls && cat mac.conf && sync"
  say "sent in $(( $(date +%s) - t0 )) s; local sha256 of mac.conf: $(shasum -a 256 mac.conf | cut -c1-16)"
}

run() { s=$1; shift; say "== $s"; ( "$s" "$@" ) 2>&1 | tee "$LOGS/$s.log"; return "${PIPESTATUS[0]}"; }
case "${1:-}" in
  preflight|sudoers|deps|vm|gpu|disk|upload) run "$@" ;;
  all)
    run deps
    ( run vm ) & v=$!; ( run gpu ) & g=$!
    wait $v || { echo "vm stage failed: $LOGS/vm.log" >&2; exit 1; }
    wait $g || { echo "gpu stage failed ($LOGS/gpu.log): disk goes on with GPU_STUB=1"; export GPU_STUB=1; }
    run disk ;;
  *) echo "build-disk.sh: unknown stage '${1:-}' (try --help)" >&2; exit 2 ;;
esac
