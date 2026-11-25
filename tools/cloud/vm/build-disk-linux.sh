#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# build-disk-linux.sh: (on the Linux host) build the hosted macOS's system disk without a Mac. From nothing to a folder
# with mac.img, mac.conf and trustcache.bin that boot-image.sh boots. macOS comes from Apple's own update server, onto this
# host only. Run it from this repository's checkout on the host (it uses tools/hosted/gui-user.py and its own helpers).
#
#   build-disk-linux.sh --out DIR --gpu-bundle DIR --password-file FILE [options] [STAGE...]
#
# Required:
#   --out DIR             where the disk goes (mac.img is sparse: about 24 GB on disk whatever its size)
#   --gpu-bundle DIR      a built XnuCpuMetal.bundle (the CPU Metal plugin; see docs/cloud-arm.md for where to get one)
#   --password-file FILE  the hosted user's password on its first line. It must be readable only by its owner or by
#                         root. It is read by a root process; it is never printed and never on a command line.
# Options (each also as the environment variable in brackets):
#   --work DIR            downloads and tools, about 17 GB kept, 28 GB at the peak [XNU_DISK_WORK, default OUT-work, beside OUT]
#   --size-gib N          size of the main container, 32 to 480 [XNU_DISK_SIZE_GIB, default 64]
#   --user NAME           the hosted administrator's short name [XNU_DISK_USER, default xnu]
#   --ssh-key FILE        an ssh public key to authorise for that user [XNU_DISK_SSH_KEY]
#   --ssh on|off          Remote Login in the hosted system [XNU_DISK_SSH, default on with --ssh-key, else off]
#   --screen-sharing on|off  Screen Sharing in the hosted system [XNU_DISK_SCREEN_SHARING, default off]
#   --autologin on|off    log the user in at boot; off shows the login window [XNU_DISK_AUTOLOGIN, default on]
#   --tuning on|off       the settings for CPU rendering of docs/cloud-arm.md section 12 [XNU_DISK_TUNING, default on]
#   --macos NAME          the macOS build, a profile of macOS-DroidVM [XNU_DISK_MACOS, default in build-disk-linux.lock].
#                         It must be the build your kernel collection was made from. Only 27.2-26B123 was tested.
#   --repo DIR            this repository on the host [default: the checkout this script is in]
#   --install-deps        let the preflight stage install missing Ubuntu packages with sudo apt-get
#   --force STAGE         run STAGE again even if it is done (repeatable). --force image rebuilds mac.img from the inputs.
#   -h, --help            this text
#
# Stages, in order; with none named, all run. Each is skipped when it is done and its check still passes, so a run that
# stopped can simply be started again with the same options.
#   preflight  looks at the host and the three required inputs. Changes nothing (without --install-deps).
#   deps       fetches macOS-DroidVM, the Linux APFS driver, its tools and ipsw at the revisions in build-disk-linux.lock,
#              builds mkapfs and apfs.ko for the running kernel.
#   inputs     fetches six members of Apple's restore image by HTTP ranges (13.8 GB of 25.6 GB), checks them against
#              Apple's manifest, decrypts the two encrypted ones.
#   image      makes mac.img: a GPT disk with two APFS containers, Apple's System volume with the OS cryptex merged in,
#              Data from the system's own template, Preboot with the App cryptex. Not resumable inside: a rerun starts
#              the image again.
#   stage      prepares the Data volume: the user, the GPU bundle, the console shell, launchd's disabled lists and the
#              options above. Safe to repeat with other options (for example --autologin off, then on).
#   finish     corrects the block counters the Linux driver leaves wrong, writes mac.conf and trustcache.bin, and
#              checks the result. Always runs.
#
# sudo is needed, without a password prompt (sudo -n), for: loading apfs.ko, loop devices, mounting, mkapfs, and every
# write into the mounted volumes; and for apt-get with --install-deps. Nothing else runs as root.
#
# Exit: 0 done, 1 a stage or its check failed, 2 wrong usage or a missing or unreadable input, 3 this host cannot do it.
# Errors go to stderr and say what to fix. Each stage's full output is in WORK/logs/STAGE.log.
#
# Status: run end to end on Ubuntu 26.04 arm64 (kernel 7.0, 4 KB pages) for macOS 27.2 (26B123) with --size-gib 120,
# and the result booted. Not exercised: --install-deps actually installing something (the host had every package),
# other sizes (an earlier form of the same steps built 48 GiB), other macOS builds, other hosts.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROG=build-disk-linux
STAGES="preflight deps inputs image stage finish"

show_help() { sed -n '3,/^set /{/^#/!d;s/^# \{0,1\}//;p;}' "$0"; }
say() { echo "$PROG: $*"; }
err() { echo "$PROG: $*" >&2; }
die() { err "$1"; exit "${2:-1}"; }
usage_error() { err "$*"; err "try: $0 --help"; exit 2; }
onoff() { case "$2" in on|off) ;; *) usage_error "$1 takes on or off, not '$2'";; esac; }

OUT=${XNU_DISK_OUT:-}; WORK=${XNU_DISK_WORK:-}; BUNDLE=${XNU_DISK_GPU_BUNDLE:-}; PWFILE=${XNU_DISK_PASSWORD_FILE:-}
SIZE=${XNU_DISK_SIZE_GIB:-64}; GUEST_USER=${XNU_DISK_USER:-xnu}; SSH_KEY=${XNU_DISK_SSH_KEY:-}; SSH=${XNU_DISK_SSH:-}
SCREEN=${XNU_DISK_SCREEN_SHARING:-off}; AUTOLOGIN=${XNU_DISK_AUTOLOGIN:-on}; TUNING=${XNU_DISK_TUNING:-on}
MACOS=${XNU_DISK_MACOS:-}; REPO=$(cd "$HERE/../../.." && pwd); INSTALL_DEPS=0; FORCE=" "; RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) show_help; exit 0;;
    --out) OUT=${2:?}; shift 2;;
    --work) WORK=${2:?}; shift 2;;
    --gpu-bundle) BUNDLE=${2:?}; shift 2;;
    --password-file) PWFILE=${2:?}; shift 2;;
    --size-gib) SIZE=${2:?}; shift 2;;
    --user) GUEST_USER=${2:?}; shift 2;;
    --ssh-key) SSH_KEY=${2:?}; shift 2;;
    --ssh) SSH=${2:?}; shift 2;;
    --screen-sharing) SCREEN=${2:?}; shift 2;;
    --autologin) AUTOLOGIN=${2:?}; shift 2;;
    --tuning) TUNING=${2:?}; shift 2;;
    --macos) MACOS=${2:?}; shift 2;;
    --repo) REPO=${2:?}; shift 2;;
    --install-deps) INSTALL_DEPS=1; shift;;
    --force) FORCE="$FORCE${2:?} "; shift 2;;
    -*) usage_error "unknown option $1";;
    *) case " $STAGES " in *" $1 "*) RUN="$RUN $1";; *) usage_error "unknown stage '$1' (stages: $STAGES)";; esac; shift;;
  esac
done
[ -n "$OUT" ] || usage_error "--out DIR is required"
[ -n "$SSH" ] || { [ -n "$SSH_KEY" ] && SSH=on || SSH=off; }
onoff --ssh "$SSH"; onoff --screen-sharing "$SCREEN"; onoff --autologin "$AUTOLOGIN"; onoff --tuning "$TUNING"
case "$SIZE" in ''|*[!0-9]*) usage_error "--size-gib takes a whole number";; esac
{ [ "$SIZE" -ge 32 ] && [ "$SIZE" -le 480 ]; } || usage_error "--size-gib must be between 32 and 480"
case "$GUEST_USER" in ''|*[!a-z0-9_]*|[0-9]*) usage_error "--user must be lower-case letters, digits or _, not starting with a digit";; esac
for f in $FORCE; do case " $STAGES " in *" $f "*) ;; *) usage_error "--force: unknown stage '$f'";; esac; done
[ -n "$RUN" ] || RUN=$STAGES
# shellcheck disable=SC1091
. "$HERE/build-disk-linux.lock" || die "cannot read $HERE/build-disk-linux.lock" 2
MACOS=${MACOS:-$MACOS_PROFILE}
mkdir -p "$OUT" || die "cannot create $OUT" 2
OUT=$(cd "$OUT" && pwd); WORK=${WORK:-$OUT-work}
mkdir -p "$WORK/logs" "$OUT/.build-state" || die "cannot create $WORK" 2
WORK=$(cd "$WORK" && pwd); STATE=$OUT/.build-state; DVM=$WORK/macOS-DroidVM
ART=$DVM/artifacts/xnulinux-$MACOS	# macOS-DroidVM's tools only take paths inside their own tree
PY="python3 $HERE/disk_linux.py"

exec 9> "$OUT/.build-lock"
flock -n 9 || die "another build-disk-linux.sh is working on $OUT" 1

# --- what each stage must leave behind -----------------------------------------------------------------------------------
check_preflight() { [ -e "$STATE/preflight.done" ]; }
check_deps() {
  [ "$(git -C "$DVM" rev-parse HEAD 2>/dev/null)" = "$DROIDVM_COMMIT" ] && [ -x "$DVM/sources/apfsprogs/mkapfs/mkapfs" ] &&
    [ -x "$DVM/toolchains/ipsw/ipsw" ] && [ -e "$DVM/sources/linux-apfs-rw/apfs.ko" ] &&
    modinfo "$DVM/sources/linux-apfs-rw/apfs.ko" 2>/dev/null | grep -q "^vermagic: *$(uname -r) "
}
member() { awk -F'\t' -v c="$1" '$1==c{print $2}' "$ART/members.tsv" 2>/dev/null; }
check_inputs() {
  local n
  [ -s "$ART/members.tsv" ] && [ -s "$ART/os.raw" ] || return 1
  [ -s "$ART/$(member StaticTrustCache)" ] && [ -s "$ART/$(member Cryptex1,SystemTrustCache)" ] || return 1
  [ -s "$ART/app-cryptex/$(member Cryptex1,AppTrustCache)" ] && [ -s "$ART/app-cryptex/$(member Cryptex1,AppOS)" ] || return 1
  n=$(member Cryptex1,SystemOS); [ -s "$ART/dec/${n%.aea}" ]
}
image_fingerprint() { echo "size=$SIZE macos=$MACOS"; }
check_image() { [ -s "$OUT/mac.img" ] && [ "$(cat "$STATE/image.done" 2>/dev/null)" = "$(image_fingerprint)" ] && sgdisk -p "$OUT/mac.img" 2>/dev/null | grep -q iBootSystemContainer; }
stage_fingerprint() {
  echo "user=$GUEST_USER autologin=$AUTOLOGIN ssh=$SSH screen=$SCREEN tuning=$TUNING"
  echo "key=$( [ -n "$SSH_KEY" ] && sha256sum < "$SSH_KEY" | cut -c1-16 )"
  echo "bundle=$(cd "$BUNDLE" 2>/dev/null && find . -type f -exec sha256sum {} + | sort -k2 | sha256sum | cut -c1-16)"
  echo "image=$(stat -c %Y "$STATE/image.done" 2>/dev/null)"
}
check_stage() { [ "$(cat "$STATE/stage.done" 2>/dev/null)" = "$(stage_fingerprint)" ]; }
check_finish() {
  grep -q '^ROOT_UUID=[0-9A-F-]\{36\}$' "$OUT/mac.conf" 2>/dev/null && grep -q '^BOOT_UUID=[0-9A-F-]\{36\}$' "$OUT/mac.conf" &&
    grep -q '^MACOS=' "$OUT/mac.conf" && [ -s "$OUT/trustcache.bin" ] && [ -s "$OUT/mac.img" ]
}

# --- the stages ----------------------------------------------------------------------------------------------------------
need_inputs() {	# the three required inputs, checked before anything long runs
  [ -n "$BUNDLE" ] || usage_error "--gpu-bundle DIR is required"
  [ -n "$PWFILE" ] || usage_error "--password-file FILE is required"
  [ -f "$BUNDLE/Contents/Info.plist" ] && [ -f "$BUNDLE/Contents/MacOS/XnuCpuMetal" ] ||
    die "$BUNDLE is not an XnuCpuMetal.bundle (no Contents/MacOS/XnuCpuMetal): give the bundle's own folder" 2
  ls "$BUNDLE"/Contents/Frameworks/libvulkan_lvp*.dylib >/dev/null 2>&1 ||
    die "$BUNDLE has no Contents/Frameworks/libvulkan_lvp.dylib: without the CPU renderer the desktop does not start" 2
  sudo -n true 2>/dev/null || die "sudo asks for a password: this script needs sudo without a prompt (see --help for what runs as root)" 3
  sudo -n test -f "$PWFILE" || die "cannot find the password file $PWFILE" 2
  case "$(sudo -n stat -c %a "$PWFILE")" in *00) ;; *) die "$PWFILE can be read by other users: chmod 600 it" 2;; esac
  [ "$(sudo -n head -c 1 "$PWFILE" | wc -c)" = 1 ] || die "the password file $PWFILE is empty" 2
  if [ -n "$SSH_KEY" ]; then
    [ -r "$SSH_KEY" ] || die "cannot read the ssh public key $SSH_KEY" 2
    grep -qE '^(ssh-|ecdsa-|sk-)' "$SSH_KEY" || die "$SSH_KEY does not look like an ssh PUBLIC key (the .pub file)" 2
    ! grep -q -- '-----BEGIN' "$SSH_KEY" || die "$SSH_KEY is a private key: give the .pub file" 2
  elif [ "$SSH" = on ]; then
    err "note: --ssh on without --ssh-key: logging in over ssh will need the password"
  fi
  [ -f "$REPO/tools/hosted/gui-user.py" ] || die "$REPO is not this repository (no tools/hosted/gui-user.py): set --repo" 2
}
do_preflight() {
  local missing="" pkgs="" t free
  [ "$(uname -m)" = aarch64 ] || { err "this host is $(uname -m): an arm64 Linux host is needed"; return 3; }
  sudo -n true 2>/dev/null || { err "sudo asks for a password: this script needs sudo without a prompt (see --help for what runs as root)"; return 3; }
  for t in git:git python3:python3 curl:curl rsync:rsync sgdisk:gdisk make:build-essential gcc:build-essential flock:util-linux losetup:mount; do
    command -v "${t%%:*}" >/dev/null || { missing="$missing ${t%%:*}"; pkgs="$pkgs ${t##*:}"; }
  done
  [ -d "/lib/modules/$(uname -r)/build" ] || { missing="$missing kernel-headers"; pkgs="$pkgs linux-headers-$(uname -r)"; }
  if [ -n "$missing" ]; then
    if [ "$INSTALL_DEPS" = 1 ]; then
      say "installing:$pkgs"
      # shellcheck disable=SC2086
      sudo -n apt-get update -q && sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -q $pkgs || { err "apt-get failed"; return 1; }
    else
      err "missing:$missing. Install with: sudo apt-get install -y$pkgs   (or run again with --install-deps)"; return 3
    fi
  fi
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || { err "python3 is older than 3.10"; return 3; }
  free=$(df -BG --output=avail "$WORK" | tail -1 | tr -dc 0-9)
  check_inputs || [ "$free" -ge 30 ] || { err "$WORK has ${free} GB free: the downloads need about 28 GB at their peak"; return 3; }
  free=$(df -BG --output=avail "$OUT" | tail -1 | tr -dc 0-9)
  check_image || [ "$free" -ge 30 ] || { err "$OUT has ${free} GB free: the image needs about 24 GB (30 GB wanted)"; return 3; }
  say "host ok: $(uname -r), $(nproc) CPUs, sudo without a prompt, ${free} GB free in $OUT"
  touch "$STATE/preflight.done"
}
fetch_git() {	# URL COMMIT DIR
  if [ "$(git -C "$3" rev-parse HEAD 2>/dev/null)" != "$2" ]; then
    if [ ! -d "$3/.git" ]; then git init -q "$3" && git -C "$3" remote add origin "$1" || return 1; fi
    git -C "$3" fetch -q --depth 1 origin "$2" 2>/dev/null || git -C "$3" fetch -q origin || return 1
    git -C "$3" checkout -q "$2" || return 1
  fi
  [ "$(git -C "$3" rev-parse HEAD)" = "$2" ]
}
do_deps() {
  local pin n
  fetch_git "$DROIDVM_URL" "$DROIDVM_COMMIT" "$DVM" || { err "could not fetch macOS-DroidVM at $DROIDVM_COMMIT from $DROIDVM_URL"; return 1; }
  [ -f "$DVM/configs/macos-$MACOS.json" ] || { err "macOS-DroidVM has no profile configs/macos-$MACOS.json (see its configs/ for the names)"; return 2; }
  for n in linux-apfs-rw:$APFS_RW_COMMIT apfsprogs:$APFSPROGS_COMMIT; do
    pin=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sources'][sys.argv[2]]['commit'])" "$DVM/configs/sources.lock.json" "${n%%:*}")
    [ "$pin" = "${n##*:}" ] || { err "${n%%:*}: build-disk-linux.lock pins ${n##*:}, macOS-DroidVM pins $pin: update the lock file"; return 1; }
  done
  mkdir -p "$DVM/sources" "$DVM/toolchains/ipsw"
  fetch_git "$APFS_RW_URL" "$APFS_RW_COMMIT" "$DVM/sources/linux-apfs-rw" || { err "could not fetch linux-apfs-rw"; return 1; }
  fetch_git "$APFSPROGS_URL" "$APFSPROGS_COMMIT" "$DVM/sources/apfsprogs" || { err "could not fetch apfsprogs"; return 1; }
  if [ ! -x "$DVM/toolchains/ipsw/ipsw" ]; then
    curl -fsSL --retry 3 -o "$WORK/ipsw.tgz" "$IPSW_URL" || { err "could not download $IPSW_URL"; return 1; }
    echo "$IPSW_SHA256  $WORK/ipsw.tgz" | sha256sum -c --quiet - || { err "ipsw archive: wrong SHA-256 (expected $IPSW_SHA256)"; return 1; }
    tar -C "$DVM/toolchains/ipsw" -xzf "$WORK/ipsw.tgz" && rm -f "$WORK/ipsw.tgz" || return 1
  fi
  make -s -C "$DVM/sources/apfsprogs/mkapfs" -j"$(nproc)" || { err "mkapfs did not build"; return 1; }
  make -s -C "$DVM/sources/linux-apfs-rw" -j"$(nproc)" || { err "apfs.ko did not build for kernel $(uname -r) (are its headers installed?)"; return 1; }
  say "tools: macOS-DroidVM ${DROIDVM_COMMIT:0:7}, linux-apfs-rw ${APFS_RW_COMMIT:0:7}, apfsprogs ${APFSPROGS_COMMIT:0:7}, ipsw $IPSW_VERSION"
}
fetch_member() {	# COMPONENT DIR: Apple's server resets connections now and then and the fetcher's directory read has no retry
  local try
  for try in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if (cd "$DVM" && python3 scripts/macos-fetch-member.py "$1" --profile "configs/macos-$MACOS.json" --inventory "${ART#"$DVM"/}/inventory/identities.json" \
        --identity vma2macosap --output-dir "${2#"$DVM"/}" --jobs 8) > "$WORK/logs/fetch.out" 2>&1; then
      tr '\r' '\n' < "$WORK/logs/fetch.out" | grep -v '%' | grep -v '^retry' | tail -2; return 0
    fi
    echo "fetch $1: try $try failed: $(tr '\r' '\n' < "$WORK/logs/fetch.out" | tail -1)"; sleep 10
  done
  err "could not fetch $1 from Apple's server in 12 tries (last output: $WORK/logs/fetch.out)"; return 1
}
decrypt() {	# ENCRYPTED TARGET: the key for the member comes from Apple's key server (no account)
  local key tmp ipsw=$DVM/toolchains/ipsw/ipsw
  tmp=$(mktemp -d -p "$(dirname "$2")") || return 1
  key=$("$ipsw" fw aea --key "$1" 2>/dev/null | awk '{print $NF}' | tail -1)
  [ -n "$key" ] || { err "no decryption key from Apple's key server for $(basename "$1")"; rmdir "$tmp"; return 1; }
  "$ipsw" fw aea -b "$key" -o "$tmp" "$1" >/dev/null 2>&1 && [ "$(find "$tmp" -type f | wc -l)" = 1 ] || { err "could not decrypt $(basename "$1")"; rm -rf "$tmp"; return 1; }
  mv "$tmp"/* "$2" && rmdir "$tmp" && rm -f "$1"
}
do_inputs() {
  local c n t0; t0=$(date +%s)
  mkdir -p "$ART/app-cryptex" "$ART/dec"
  if [ ! -s "$ART/inventory/identities.json" ]; then
    for c in 1 2 3 4 5 6 7 8; do	# Apple's server resets connections now and then; the inventory tool has no retry
      rm -rf "$ART/inventory"	# ... and refuses a folder that exists
      (cd "$DVM" && python3 scripts/macos-inputs.py --profile "configs/macos-$MACOS.json" --output "${ART#"$DVM"/}/inventory") > "$WORK/logs/inventory.out" 2>&1 && break
      echo "inventory: try $c failed: $(tail -1 "$WORK/logs/inventory.out")"; sleep 10
    done
    [ -s "$ART/inventory/identities.json" ] || { err "could not read the restore image's manifest from Apple's server (last output: $WORK/logs/inventory.out)"; return 1; }
  fi
  $PY names --dvm "$DVM" --inventory "$ART/inventory/identities.json" > "$ART/members.tsv.new" && mv "$ART/members.tsv.new" "$ART/members.tsv" || return 1
  for c in StaticTrustCache Cryptex1,SystemTrustCache; do [ -s "$ART/$(member $c)" ] || fetch_member "$c" "$ART" || return 1; done
  for c in Cryptex1,AppTrustCache Cryptex1,AppOS; do [ -s "$ART/app-cryptex/$(member $c)" ] || fetch_member "$c" "$ART/app-cryptex" || return 1; done
  n=$(member Cryptex1,SystemOS)
  if [ ! -s "$ART/dec/${n%.aea}" ]; then
    [ -s "$ART/dec/$n" ] || fetch_member Cryptex1,SystemOS "$ART/dec" || return 1
    decrypt "$ART/dec/$n" "$ART/dec/${n%.aea}" || return 1
  fi
  n=$(member OS)
  if [ ! -s "$ART/os.raw" ]; then
    [ -s "$ART/$n" ] || fetch_member OS "$ART" || return 1
    decrypt "$ART/$n" "$ART/os.raw" || return 1
  fi
  say "inputs: $(du -sh "$ART" | cut -f1) in $ART, $(( $(date +%s) - t0 )) s"
}
do_image() {
  if [ -e "$OUT/mac.img" ] && [ -e "$STATE/image.done" ] && [ "$(cat "$STATE/image.done")" != "$(image_fingerprint)" ] && [ "${FORCE#* image }" = "$FORCE" ]; then
    err "$OUT/mac.img was built with '$(cat "$STATE/image.done")', now '$(image_fingerprint)' is asked for."
    err "Use another --out, or add --force image to build it again (the old image is deleted)."; return 2
  fi
  rm -f "$STATE/image.done" "$STATE/stage.done"
  $PY image --dvm "$DVM" --artifacts "$ART" --out "$OUT" --size-gib "$SIZE" || return 1
  image_fingerprint > "$STATE/image.done"
}
do_stage() {
  rm -f "$STATE/stage.done"
  # shellcheck disable=SC2046
  $PY stage --dvm "$DVM" --artifacts "$ART" --out "$OUT" --repo "$REPO" --gpu-bundle "$BUNDLE" --password-file "$PWFILE" --user "$GUEST_USER" \
    $( [ -n "$SSH_KEY" ] && printf -- '--ssh-key\n%s\n' "$SSH_KEY" ) --ssh "$SSH" --screen-sharing "$SCREEN" --autologin "$AUTOLOGIN" --tuning "$TUNING" || return 1
  stage_fingerprint > "$STATE/stage.done"
}
do_finish() {
  local off
  for off in $((1 << 20)) $((501 << 20)); do
    python3 "$HERE/apfs-alloc-count.py" --fix --offset "$off" "$OUT/mac.img" || { err "the block counters could not be corrected"; return 1; }
    python3 "$HERE/apfs-alloc-count.py" --offset "$off" "$OUT/mac.img" > /dev/null || { err "the block counters still disagree after the correction"; return 1; }
  done
  $PY finish --dvm "$DVM" --artifacts "$ART" --out "$OUT" --trustcache "$ART/$(member StaticTrustCache)" || return 1
  $PY verify --dvm "$DVM" --artifacts "$ART" --out "$OUT" --user "$GUEST_USER" || { err "the finished image lacks files a boot needs (lines marked MISSING above)"; return 1; }
  rmdir "$OUT/scratch/volume" "$OUT/scratch/source" "$OUT/scratch" 2>/dev/null; rm -rf "$OUT/shim"
  # the Linux apfs driver is only needed while the disk is built
  if lsmod | grep -q '^apfs ' && ! grep -q ' apfs ' /proc/mounts; then sudo -n rmmod apfs 2>/dev/null || true; fi
}

in_use() {	# is a running hosted system using this image? (xnu.ko's disk= parameter)
  local d; d=$(sudo -n cat /sys/module/xnu/parameters/disk 2>/dev/null) || return 1
  [ -n "$d" ] && [ "$(readlink -f "$d")" = "$(readlink -f "$OUT/mac.img")" ]
}
need_inputs
for s in $STAGES; do
  case " $RUN " in *" $s "*) ;; *) continue;; esac
  if [ "$s" != finish ] && [ "${FORCE#* $s }" = "$FORCE" ] && "check_$s"; then say "$s: already done, skipped"; continue; fi
  if [ "$s" != preflight ] && [ "$s" != deps ] && ! check_deps; then die "stage $s needs the tools: run the deps stage first" 1; fi
  case "$s" in image|stage|finish) check_inputs || die "stage $s needs Apple's inputs: run the inputs stage first" 1;; esac
  case "$s" in stage|finish) [ -s "$OUT/mac.img" ] || die "stage $s needs $OUT/mac.img: run the image stage first" 1;; esac
  case "$s" in image|stage|finish) ! in_use || die "the running hosted system is using $OUT/mac.img: stop it first (sync in the guest, then scripts/xnulinux-boot.sh stop)" 1;; esac
  say "$s: start"; t0=$(date +%s)
  "do_$s" > >(tee "$WORK/logs/$s.log") 2>&1; rc=$?
  [ $rc = 0 ] || { err "stage $s failed (status $rc). Its output is in $WORK/logs/$s.log. Fix the cause and run the same command again."; exit $rc; }
  "check_$s" || { err "stage $s ran but its check does not pass; see $WORK/logs/$s.log"; exit 1; }
  say "$s: done in $(( $(date +%s) - t0 )) s"
done
if check_finish && check_stage; then
  say "disk ready in $OUT:"
  ls -ls "$OUT/mac.img" "$OUT/mac.conf" "$OUT/trustcache.bin"
  say "boot it with: bash $HERE/boot-image.sh $OUT 100"
fi
