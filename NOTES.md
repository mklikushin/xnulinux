# NOTES

## 2026-11-23: trying to run xnulinux on `ssh dgx` (bare-metal DGX Spark)

### Host facts (probed over ssh)
- NVIDIA GB10 (10x Cortex-X925 + 10x Cortex-A725), aarch64, bare metal, Ubuntu 24.04.5, kernel `7.0.0-1025-nvidia`.
- 4K pages, 48-bit VA, `paca pacg` present, `/dev/kvm`, `/dev/dri/renderD128` (NVIDIA).
- Kernel config: `ARM64_PTR_AUTH_KERNEL=y`, `SHADOW_CALL_STACK=y`, `RANDOMIZE_BASE=y`, `KALLSYMS_ALL=y`, `KPROBES=y`,
  `CMA=y` but `CmaTotal: 0`, `SECURITY_LOCKDOWN_LSM=y`.
- **Secure Boot enabled, lockdown = integrity** (`/sys/kernel/security/lockdown`: `none [integrity] confidentiality`).
- 121 GiB RAM, ~7 GiB available: two long-running GPU services (an LLM server container, 61 GB of GPU memory, and a
  TTS server, 43 GB) hold the rest.
- `sudo` needs a password (no passwordless sudo over ssh).

### What was done
- `rsync` of the repo (without `.git`, `docs/images`) to `dgx:~/xnulinux`.
- `fki.ko` and `xnu.ko` **build cleanly** against `7.0.0-1025-nvidia` headers with gcc 13.3 (one
  "non-compatible type" warning at `xnu-ko/xnu_main.c:308`). Unsigned; not loaded.

### Blockers before anything can be loaded (all need the user)
1. sudo password: insmod, apt (llvm-21/clang-21/lld-21, meson, unifdef, tcsh, pax, libbsd-dev, libmd-dev, 7zip are missing
   for `scripts/vm-xnu-build.sh`), `/lib/firmware/xnu`.
2. Secure Boot + lockdown=integrity: unsigned modules are refused, and lockdown blocks kprobes, which `fki_mod.c` needs
   (`kallsyms_lookup_name` lookup, `__do_kernel_fault` hook). MOK signing alone is not enough; Secure Boot has to be off
   (firmware setup) or lockdown lifted.
3. DRAM for XNU: no CMA area, so it needs the carve-out (`mem=` + `nokaslr` on the kernel command line, reboot), with
   `carve_base` chosen from this machine's memory map (`/proc/iomem` is zeroed without root). The reboot stops the two
   GPU services; 8 GB less for Linux.
4. Never tested on bare metal / this kernel: only on krunkit/tart VMs on Apple Silicon. A fault in `xnu.ko` here takes the
   whole machine down (the services with it).

### Ingredients already on dgx
- the macOS 27.2 (26B123) restore IPSW (kernelcache for the kernel collection's Apple kexts).
- installed macOS 27.2 VM disks from the user's own macOS-on-KVM stack
  (`mk-macvm-disk.sh` expects to run on a Mac with the disk attached; would need the disk copied to the Mac or the
  script's steps redone on Linux).

### Decision (user, 2026-11-23): run it in a KVM guest on dgx, not on the bare metal

Memory survey (`dgx:~/xnulinux/mem.txt`): 117.7 GiB used of 121.7, 6.9 GiB available, swap 1.2 of 16 GiB.
- Process RSS sums to only ~11 GiB; the rest is GPU memory, which on GB10 is system RAM (unified):
  - the LLM server (a docker container, restart `unless-stopped`): 60.9 GiB GPU + ~7 GiB RSS.
  - the TTS server (a plain process started from an ssh session, no supervisor): 42.9 GiB GPU + 2.6 GiB RSS.
- Everything else is small. Page cache 5 GiB. No VM running.
- A 16 GiB guest does not fit until one of the two is stopped.

KVM tooling: no `qemu-system-aarch64`, `qemu-img`, AAVMF or libvirt installed (and no sudo). The user is in `kvm` and
`docker`, so QEMU can run from a container with `--device /dev/kvm`. `/boot/vmlinuz-*` is root-only.

SSH: one-shot `ssh dgx` calls were unreliable from the Mac; a persistent tmux session `dgx` was used instead.

### KVM guest on dgx (2026-11-23, after the user said to stop both services)
- Both GPU services stopped (the container with `docker stop`; the other's start command saved for the user). 117 GiB available after.
- Channel: new `ssh dgx` connections can hang; everything goes through the Mac's tmux session `dgx`
  (helper used this session: paste a script through a heredoc, run it, read the output file).
- `dgx:~/xnuvm/`: `Dockerfile` (image `xnuvm-qemu`: ubuntu 24.04 + qemu-system-arm, AAVMF, cloud-image-utils),
  `run-vm.sh` (container `xnuvm`, `--device /dev/kvm`, pinned to the X925 cores 5-9,15-19, `-cpu host`, 10 vCPUs, 24 GiB,
  raw 300G `disk.img`, user net with ssh on 127.0.0.1:2222, serial in `console.log`), `vm.sh` (run a command in the guest
  as `admin`, key `vmkey`), `stage2.sh`.
- cloud-init gotcha: user `admin` fails to create because the image already has a group `admin`; fixed with
  `primary_group: admin`.
- **Works:** guest boots; **KVM on GB10 exposes PAC** (`paca pacg` in the guest), 4K pages, RAM
  `0x40000000-0x640000000` (24 GiB: carve-out per `vm-install-fki-service.sh`'s 24 GB note: `LINUX_MEM=15G
  CARVE_BASE=0x400000000`). HWE kernel candidate `7.0.0-38.38~24.04.4` (same series the README shows).
- In progress: `stage2.sh` installs `linux-generic-hwe-24.04`, reboots, rsyncs the repo to guest `~/w/poc`, starts
  `scripts/vm-xnu-build.sh` (log: guest `~/w/xnu-build.log`).

### Result so far (2026-11-23): the XNU kernel boots inside xnu.ko in the KVM guest on GB10
- Guest on `7.0.0-43-generic` (HWE). `scripts/vm-xnu-build.sh` failed on a fresh checkout: it patched cctools' foreign
  headers before the toolchain step had fetched them (`set -e` stopped it). The toolchain itself builds on arm64 as it
  is; the kernel's host tools (`installhdrs`: "architecture not supported" in `foreign/mach/machine/boolean.h`) need the
  patch. **Fixed in the repo (uncommitted):** `patch_cctools` runs after `setup-env.py toolchain`. With it the k27 kernel
  built in ~3 min on 10 X925 cores.
- `kc27.bin`: `unzip -j <IPSW> kernelcache.release.vma2`, then blacktop `ipsw`
  (v3.1.749 **linux_arm64**; DroidVM's lock names the x86_64 one) `img4 im4p extract -o kc27.bin` → guest
  `~/w/dvm/out/kc/kc27.bin` (what DroidVM's `product.py inputs` does, without its 10s of GB of other members). Kept in
  `dgx:~/xnuvm/kc/`.
- `scripts/vm-xnu-rebuild.sh` (needs `sudo mkdir -p /lib/firmware/xnu` first): patches applied, all 8 kexts built,
  collection linked (`kc-k27.bin` 0x55a8000 bytes), AMFI platform patched 27 -> 26 (default `AMFI_PLATFORM=26`; a 27.2
  disk may want 27), `/lib/firmware/xnu/{kc.bin,kernel.macho}` installed.
- Carve-out: `LINUX_MEM=15G CARVE_BASE=0x400000000 bash scripts/vm-install-fki-service.sh`, reboot: `mem=15G nokaslr`,
  kernel image at `0x633a00000` (above the carve-out), `fki: 8156 MiB at 0x400000000`, `xnu0` present.
- Smoke test with an empty 1 GiB disk and fake UUIDs, no trust cache, `cpus=1`, by hand (the insmod line of
  `xnulinux-boot.sh` without `trustcache=`): `Darwin Kernel Version 25.5.0 ... DEVELOPMENT_ARM64_BCM2837`, APFS kext
  loaded, XnuDisk/XnuDisplay (1280x800)/XnuEthernet started, then `Waiting on ... IOMedia UUID` (no root: expected) and
  idle. `xnulinux-boot.sh stop` ended it cleanly. No fault, no panic.

### Metal plugin on GitHub CI (2026-11-23, user asked for it)
- Branch `ci/metal-plugin` (pushed; main untouched): `.github/workflows/metal-plugin.yml`, macOS runner, artifact
  `XnuCpuMetal.bundle` (tar.gz), lavapipe only (no Venus). Run: https://github.com/AFK-surf/xnulinux/actions/runs/45150248426
- The build scripts assume things the README does not list; the workflow recreates them: `build/pyvenv` (mako, pyyaml,
  packaging), `build/vk-deps/vulkan-headers/1.4.363.0` (Vulkan-Headers `vulkan-sdk-1.4.363.0`),
  `build/vk-deps/vulkan-loader/1.4.363.0/lib/libvulkan.1.4.363.dylib` (copied from `build-vkloader-arm64e.sh`'s arm64
  output), Homebrew `llvm@22` (symlinked to `llvm` when there is no such formula), glslang, bison, flex, zstd, Rust
  1.100.0 and nightly with rust-src. `build-vkloader-arm64e.sh` must run before `build-m2v.sh`.
- First run: host, tools, sources, loader, lavapipe arm64 and the arm64 bridge passed; the arm64e LLVM build (cached
  afterwards) was still running when last checked. arm64e lavapipe, arm64e bridge and the bundle step: not yet reached.

### A new system disk on dgx (2026-11-23)
- `dgx:~/xnuvm/mac-restore.sh`: the user's `vmapple-cli create` + `restore` from
  the macOS 27.2 (26B123) restore IPSW → `~/xnuvm/mac/xnu272/{disk.img,aux.img,vm.json}`, macOS 27.2 (26B123),
  26 GiB allocated. First attempt hit the known "timed out waiting for the restore OS" USB flake; the second finished.
- Layout (own GPT/APSB scan): p2 main container: `Macintosh HD` (System), `Preboot`, `Data` (fs flags `0x100`, not the
  UNENCRYPTED bit), `Recovery`, `Update`; volume group `478C06EB-C8E8-4234-B386-23433F2A8433`.
- Making it a hosted disk (what `mk-macvm-disk.sh` does) from a helper macOS guest on dgx: **does not work so far.**
  - `~/xnuvm/mac/hboot.sh`: copy of a pristine install of the same build as `helper`, booted single-user (`--boot-args="-s ..."`; the
    `=` is needed) with the new disk as an extra `virtio-blk-pci` through `VMAPPLE_QEMU_ARGS`; `sershell.py` types
    commands on `helper/serial.sock`. The helper sees the target container (`apfs.util -p` names its volumes; disk
    numbers change between boots) and has the cryptexes grafted at `/System/Cryptexes/{OS,App}`. No python3 in the guest.
  - `apfs_boot_util 1` (the helper's own Data, as `vmapple-cli account` does) with the second disk attached: kernel
    panic `"unencrypted data volume is not allowed" @apfs_vfsops.c:2399`. Which Data volume it was about: not determined.
  - Without it there is no writable directory; mounting the target's volumes on existing directories (`/Volumes`,
    `/System/Volumes/{VM,Update}`), read-write or read-only, and `mount_tmpfs`: `Operation not permitted`. SIP is
    enabled in the guest (`csrutil status`).
  - So from a SIP-on RELEASE guest neither Preboot/Cryptexes nor the sealed System volume of another disk can be
    written. Open: SIP off in the user's vmapple stack (LocalPolicy / OpenAVB), or the Mac host with sudo and the image
    served from dgx (SMB), or the target's own single-user boot for the Data-only parts.

### SIP off in the vmapple guests, and a hosted disk made entirely on dgx (2026-11-23, user: "go disable SIP")
- **SIP off:** XNU takes its CSR configuration from `/chosen/asmb` `lp-sip0` (8 bytes) in the device tree; iBoot writes it
  only when the LocalPolicy says so (the node has `lp-nsih lp-spih lp-stng lp-lpnh lp-rpnh lp-hrlp`, no `lp-sip*`).
  The user's QEMU already edits the tree at the kernel handoff (`target/arm/kvm.c: vmapple_handoff_apply`), so a
  **separate patched copy** (`dgx:~/xnuvm/qemu-sip/`, source copied from that stack's QEMU tree,
  patch script `qpatch.py` + `fix.py`, `build.sh`; the user's trees and build are untouched) adds the property when
  `QEMU_VMAPPLE_LP_SIP0=<flags>` is set. The tree's `tree_len` (0x8c000) is its allocation; the tree ends at 0x8a150,
  so the 44-byte entry is inserted in place. Used with `0x86f`. `csrutil status` still prints "enabled", but the
  restrictions are gone: other disks' volumes mount read-write, datavault directories list.
- **Hosted trial boots** (`/etc/xnulinux.conf` in the guest: `DISK=/dev/disk/by-id/virtio-macimg GPU=off CPUS=4`;
  `dgx:~/xnuvm/mac.img` is a copy of the restored disk attached to the Linux guest as a second virtio disk;
  `/var/tmp/mac.conf`: `ROOT_UUID=C0513755-8E91-4456-8BD8-71475A0F7370` (apfs.util -k of "Macintosh HD"),
  `BOOT_UUID=478C06EB-C8E8-4234-B386-23433F2A8433`; collection rebuilt with `AMFI_PLATFORM=27`; trust cache from the
  IPSW: BuildManifest `StaticTrustCache` of `vma2macosap` → `ipsw img4 im4p extract`, 1 file, `dgx:~/xnuvm/trial/tc.py`):
  1. unmodified disk: root mounts, launchd: `Library not loaded: /usr/lib/libSystem.B.dylib` (no cryptex) → panic. Expected.
  2. after the cryptex step: launchd runs, `apfs_boot_util` (mount-phase-2) aborts: `failed to unwrap volume key`
     for the Data volume. **A vmapple restore encrypts Data with that VM's keys** (fs flags 0x100, incompat 0x41);
     only the installed system itself opens it (its own single-user boot does).
  3. after the Data volume was made again: **macOS 27.2 (26B123) userspace runs on the hosted kernel**: Data mounts,
     root shell `xnulinux#` on the console, `sw_vers`/`uname` answer, 4 CPUs, 8 GB, 168 processes.
- **XnuDisk** (`kexts/XnuDisk/XnuDisk.cpp`, uncommitted): detects a 4096-byte-LBA GPT ("EFI PART" at byte 4096 and not
  at 512). This disk turned out to have a GPT readable at 512 as well (the kext logged 512-byte blocks and Linux listed
  the partitions), so the detection was not exercised.
- **Disk preparation without a Mac** (replaces `mk-macvm-disk.sh` here; all in `dgx:~/xnuvm/mac/`):
  - `hboot.sh`: helper macOS guest (copy of a pristine install of the same build) single-user, SIP off, `mac.img` and `payload.img`
    as extra `virtio-blk-pci` disks; `sershell.py SOCK FILE [--wait-boot]` types a command file on the serial shell
    (`@SECONDS ` prefix = timeout). Target volumes found by name with `apfs.util -p` (disk numbers change every boot).
    No python, `man`, `strings`, `diskutil` (diskarbitrationd exits 70) in single-user; mount points must be existing
    directories (`/Volumes`, `/System/Volumes/{VM,Update}`). Do not run `apfs_boot_util` in the helper with the
    target attached (kernel panic "unencrypted data volume is not allowed", seen once, before any of this).
  - Cryptexes: the helper is the same build, so its own grafted `/System/Cryptexes/{OS,App}` are the source: `ditto`
    to the target Preboot's `Cryptexes/{OS,App}` (2.6 GB + 40 MB) and the script's `cp -Rpn` merge into the target
    System volume.
  - Data: `tboot.sh` boots the restored install itself (`xnu272`, never booted before) single-user with SIP off,
    `apfs_boot_util 1; 2`, then `tar -cf - <top-level names> | dd of=/dev/rdiskN ibs=65536 obs=1048576 conv=osync`
    onto the raw payload disk (37289 members, 2.4 GB, no errors). Gotchas: `tar .` fails ("Couldn't visit
    directory"), with SIP on TCC and other datavaults are unreadable, `dd bs=1m conv=sync` pads every short pipe read.
    In the helper: `newfs_apfs -A -v Data <container>` (unencrypted; no role or group option that I know), untar,
    then the overlay.
  - Overlay (`dgx:~/xnuvm/overlay.py`, run as root in the `xnuvm-qemu` container): `tools/hosted/gui-user.py` and the
    inline Python of `mk-macvm-disk.sh` against a staging tree seeded with the archive's `admin`/`staff` group
    plists, plus the CI bundle in `Library/GPUBundles`; files only (existing directories keep their modes), written
    at 4 GiB into `payload.img`, untarred over the new volume, then `chown -R 501:20 Users/xnu`. The System volume's
    `User Template` is an empty directory from there, so the home has only what gui-user.py writes.
  - `dgx:~/xnuvm/apsb.py IMAGE NEW_UUID --apply`: sets the new volume's role (0x40) and volume group in every APSB
    copy (Fletcher-64 recomputed, 11 blocks) and clears both on the old Data volume (1 block), which stays in the
    container, unused. New Data volume UUID `8588A37C-4CC5-4993-B3EA-D55D38325A47`.
- **WindowServer** aborts in `__WSSystemCanCompositeWithMetal_block_invoke` every 30 s: the plugin loads but
  `dlopen(libvulkan_lvp.dylib)`: `symbol not found in flat namespace '_spvBinaryToText'`. The CI runner's Homebrew
  glslang brought SPIRV-Tools; Mesa found it, linked Homebrew's dylib into the arm64 slice and left the arm64e slice
  with undefined `spv*` symbols (the runner's render test passed because the dylib was there). Fixed in the workflow
  (`brew unlink spirv-tools` + a self-containment check on the bundle); run 45165136403 in progress when written.
- **Desktop reached (2026-11-23):** CI run 45165136403 passed; its bundle (no `spv*` undefined symbols, no Homebrew
  dependency) installed from the hosted console (`curl http://192.168.77.1:8099/b.tgz | tar` into `/Library/GPUBundles`;
  the hosted system reaches the Linux guest and the internet, `https://www.apple.com` 200). After a clean restart:
  automatic login, WindowServer on lavapipe, Finder menu bar, wallpaper, widgets, a notification, 1280x800
  (screenshot: `../xnulinux-dgx-desktop.png` on the Mac, outside the repo). The Dock was not on screen ~2 min after
  boot; not checked further. `dgx:~/xnuvm/overlay.py` still packs the first (broken) bundle unless rerun: the fixed
  one is `dgx:~/xnuvm/XnuCpuMetal.bundle.tar.gz` now.
- **Intermittent boot failure (1 of 3 boots on the finished disk):** `apfs_boot_util` took the root device for
  `/dev/disk3s5` (the old encrypted Data volume, left in the container with no role) instead of `disk3s1`:
  "root device /dev/disk3s5 is not in a volume group", "No DATA volume present", Data not mounted, `tzinit` exits 2,
  launchd panics. The next boot, nothing changed on disk, was fine. Removing the old volume (or giving the new one
  the group's UUID) may avoid it; not tried. That boot also followed an unclean stop of the run before it.
- **VNC:** macOS Screen Sharing in the hosted system works. From the hosted console: `kickstart -activate -configure
  -access -on -privs -all -restart -agent`, `launchctl enable/bootstrap system/com.apple.screensharing`, legacy VNC
  password (`kickstart -configure -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw <password>`: without it only
  Apple's auth types 30/33/35/36 are offered and third-party clients fail with "key length too large"), and two rows in
  `/Library/Application Support/com.apple.TCC/TCC.db` (`kTCCServiceScreenCapture`, `kTCCServicePostEvent` for
  `com.apple.screensharing.agent`, auth_value 2, auth_reason 4; without them: "Screen Sharing is not permitted").
  Path: Mac `ssh -L 5901:127.0.0.1:5901 dgx` → dgx `ssh -L 127.0.0.1:5901:192.168.77.37:5900` into the Linux guest
  (a background ssh on dgx; hosted en0 got 192.168.77.37 on every boot so far). The user confirmed the UI shows.
- **Console output channel:** dmesg is unusable while a process floods it; `guest:~/hcmd.sh [TIMEOUT] < commands`
  serves the commands over `http://192.168.77.1:8099/cmd.sh`, the hosted console shell runs them and pipes the
  output to `nc 192.168.77.1 8100`. A `ps ax` on the console can hang for a long time; avoid it in scripts.
- **No Dock, blank icons (open, 2026-11-23):** Dock runs; the user's `iconservicesagent` (gui/501) dies ~3 s after
  each start (SIGSEGV, 19+ runs), so Dock and System Settings get no icons (`NSCocoaErrorDomain 4097`).
  - Stack: IconServices → IconRendering → RenderBox (`RB::TextureCache::prepare_from_iosurface`, `render_image`) →
    XnuCpuMetal → lavapipe; the crash is in a JIT-compiled fragment shader called from `lp_rast_triangle_32_5`:
    `ldr x8,[x8,x0,lsl #3]; add x0,x22,#0xc0; ldr x8,[x8]` ← faults; `blr x8` follows. The table entry read was 0x22
    in one crash and 0 in another: llvmpipe's per-texture sample-function row for the sampler index is not there.
  - Deterministic, not a race: same instruction with `LP_NUM_THREADS=0` (then on the queue thread, via
    `llvmpipe_flush`). Not the sandbox (no denials; neither binary has JIT entitlements). The arm64e JIT patch is
    applied in the CI build. CPUS=1 was not a usable test (no login session after 5.5 min).
  - Separate, intermittent: one agent instance looped on "Data/Stack execution not permitted ... protections were
    read-write" at one address (1.1 M kernel log lines in 18 s) instead of dying. Not explained.
  - Guess, unverified: RenderBox's shaders use constexpr samplers; metal2vulkan lowers those to Vulkan immutable
    samplers, and the texture or sampler never gets its row in llvmpipe's matrix on this path (e.g. a texture view
    not registered as sampled). WindowServer composites fine with the same bundle. The README's screenshots show a
    Dock with icons, so the author's build or system differs somewhere; unknown where.
  - Next: a lavapipe debug build (asserts, symbols) in CI and/or logging in the plugin around
    `xcmDev_newTextureIOSurface`; ask upstream whether this is known.
- **Workaround for the icon agent (2026-11-23, works):** `launchctl disable gui/501/com.apple.iconservices.iconservicesagent`
  (+ `bootout`; persists) from a root shell in the hosted system. Clients then fail at once instead of queueing behind
  a service that crashes and respawns: the Dock comes up (about half of its icons drawn, the rest blank), Terminal
  opens a window with a shell. Before it, Terminal's main thread sat in `+[ISIconManager sharedInstance]` →
  `xpc_connection_send_message_with_reply_sync` while loading its nib. Undo: `launchctl enable ...`. The crash itself
  is still open (above).
- **SSH into the hosted system:** enabled (`launchctl enable system/com.openssh.sshd` + bootstrap `ssh.plist`), the
  Linux guest's key (`~/hkey`, same as `dgx:~/xnuvm/vmkey`) in root's and xnu's `authorized_keys`:
  `ssh -i ~/hkey root@192.168.77.37` from the guest. Use this, not the console, for anything that can block.
  TCC rows added for `com.apple.Terminal` (full disk access, accessibility, developer tool).
- Also seen, not looked into: `cryptexd` crashes every 10 s; `com.apple.DriverKit-IOUserDockChannelSerial` crashed;
  `AppleVPKeyStore ... unexpected session uid: -1` for bluetoothd/ReportCrash.

### Still missing for a boot (as of the first KVM session; superseded by the section above)
- `out/kc/kc27.bin` (macOS 27.2 kernelcache for the collection's Apple kexts): dgx has
  the macOS 27.2 (26B123) restore IPSW; how DroidVM turns it into kc27.bin: to read in the dvm tree.
- The system disk (`mk-macvm-disk.sh`): written for a Mac with tart, passwordless sudo and the built Metal bundle.
  The Mac at hand had none of that prepared and little free disk. dgx has installed macOS 27.2 disks from the user's own macOS-on-KVM stack
  (its disks and its QEMU), but Linux has no
  read-write APFS. Options: (a) serve the image from dgx to the Mac (SMB from a container) and run the script's steps
  there with sudo; (b) do the steps inside a macOS guest on dgx with the disk attached as a second drive.
- `XnuCpuMetal.bundle` (WindowServer needs a Metal device): Mac build with LLVM arm64e + Mesa: too large for the Mac at hand.
  Without it the target is launchd + the console root shell, not the desktop.

### Open questions
- (resolved: both stopped) Which service to stop to free 16+ GiB for the guest (user's call).
- Does KVM on GB10 expose PAC (`paca`/`pacg`) to guests? To check with the first guest boot.
- Does the user accept a reboot of dgx with Secure Boot off and `mem=`/`nokaslr`, with the running services stopped?
- Alternative with no risk to the host: run it inside a KVM guest on dgx (arm64 Ubuntu VM, 16 GB, as on the Mac). KVM on
  GB10 exposes PAC to guests? Not checked. Needs ~16 GB free RAM, which the host does not have while both services run.
- `SHADOW_CALL_STACK=y` (x18 is Linux's shadow stack pointer) vs XNU code running on Linux kthreads: not checked whether
  the Ubuntu generic kernels the project was tested on also have it.

## 2026-11-23 (late): moving to the dgx bare metal (user decision)
- User turned Secure Boot off in the firmware (Security → Secure Boot); after the reboot: `SecureBoot disabled`,
  lockdown `[none]`. The reboot ended the KVM guest and the hosted system; the two GPU services stay stopped.
- Prepared without root, in `dgx:~/xnuhost/`: `poc/` (the guest's `~/w/poc`, with `fki.ko`/`xnu.ko` built for
  `7.0.0-1025-nvidia`), `fw/{kc.bin,kernel.macho,trustcache-mac.bin}` (the guest's `/lib/firmware/xnu`), `mac.conf`.
  The finished disk is `dgx:~/xnuvm/mac.img`. The guest was powered off and its container removed
  (`~/xnuvm/run-vm.sh` starts it again; it attaches the same `mac.img`: never run both on it).
- Plan (needs sudo, not yet given): read `/proc/iomem`, pick `mem=`/`carve_base` for an 8156 MiB carve-out, add
  `kvm-arm.mode=nvhe mem=... nokaslr log_buf_len=128M` in `/etc/default/grub.d/99-xnulinux.cfg`, `update-grub`,
  reboot, check dmesg says nVHE, install firmware to `/lib/firmware/xnu`, `insmod fki.ko carve_base=... carve_mb=8156`,
  then `xnulinux-boot.sh` with `GPU=off`, few CPUs.
- Unverified risks: XNU machine layer at EL2 if nVHE cannot be forced on GB10; `SHADOW_CALL_STACK=y` (x18) in the
  NVIDIA kernel; a fault in kernel mode takes dgx down.
- **Bare metal works (2026-11-23 late):** sudo given by the user (temporary `/etc/sudoers.d/99-xnulinux-tmp`, to remove).
  - `/etc/default/grub.d/99-xnulinux.cfg`: `kvm-arm.mode=nvhe mem=112G nokaslr log_buf_len=128M`. After reboot:
    "Hyp nVHE mode initialized successfully", System RAM ends at `0x1c97c1f000`, kernel image at `0x206ce00000`
    (nokaslr puts it near the top), carve-out `carve_base=0x1E00000000 carve_mb=8156` accepted by fki.
  - Run 1 (`CPUS=2`, XNU on Linux CPUs 0,1): reached the console shell and login, then "XNU CPU 0 made no host call
    for 2 s (interrupts masked)", XNU panic `wait_while_equals32 ... timeout @locks.c:959` at 341 s. Cause: the NVMe
    has 15 I/O queues for 20 CPUs; `nvme0q8` serves CPUs 0-1 with its (managed, not movable) interrupt on CPU 0, so
    CPU 1's disk completions arrive on CPU 0: the deadlock `xnulinux-boot.sh`'s comment describes. Also in that run:
    xnu.ko's monitor thread, dumping the silent CPU, read an unmapped XNU address and Linux oopsed in `show_pte`
    (the carve-out is not in Linux's linear map); xnu.ko could not be unloaded afterwards (reboot).
  - Fix (uncommitted): `fki.ko cpu_list=` (foreign CPU n = Linux CPU cpu_list[n]; `fki_bind_cpu`, `fki_thread_start`,
    `fki_kick_cpu`, `fki_cpu_mpidr`, `fki_num_cpus`), and `xnulinux-boot.sh` takes its interrupt mask from it.
    dgx: `cpu_list=5,6,7,8,9` (X925 cores, each with its own NVMe queue; the fifth is the monitor's), `CPUS=4`.
  - Run 2: desktop (Terminal restored from the earlier session, Dock, Finder), no panic or oops in the first
    ~6 minutes. Boot is slower than in the KVM guest (Data volume mounted 100 s after the kernel banner; ~12 s in
    the guest; not investigated). "XNU CPU 1 made no host call for 2 s ... last call 810 (inside it)" five times
    during boot. The hosted `uptime` showed load averages in the hundreds (not investigated).
  - Network: NetworkManager on dgx took `xnu0` and removed 192.168.77.1; fixed with `nmcli dev set xnu0 managed no`
    and `/etc/NetworkManager/conf.d/99-xnulinux.conf` (unmanaged-devices=interface-name:xnu0), address re-added,
    `ipconfig set en0 DHCP` on the hosted console. Then lease 192.168.77.37, ssh from dgx, internet from the hosted
    system, Screen Sharing listening.
  - Not persistent: fki.ko is loaded by hand after each dgx boot
    (`sudo insmod ~/xnuhost/poc/fki-ko/fki.ko carve_base=0x1E00000000 carve_mb=8156 cpu_list=5,6,7,8,9`), then
    `cd ~/xnuhost/poc && bash scripts/xnulinux-boot.sh` (config `/etc/xnulinux.conf`, `/var/tmp/mac.conf`).

## GPU on the dgx bare metal: feasibility probe (2026-11-23 late; nothing connected yet)
- State: `GPU=off`, WindowServer has only `libvulkan_lvp.dylib`; the CI bundle carries no Venus driver.
- `gpu/xnu-drm/xnudrmd.c` forwards virtio-gpu DRM ioctls (`VIRTGPU_CONTEXT_INIT/EXECBUFFER/GET_CAPS/GETPARAM/MAP/
  RESOURCE_CREATE_BLOB/RESOURCE_INFO/WAIT`, `GEM_CLOSE`) to a virtio-gpu render node. dgx's `/dev/dri/renderD128` is
  the NVIDIA proprietary driver (580.178.04): no virtio-gpu, so the bridge as written has nothing to talk to.
- Way through: xnudrmd as the virtio-gpu backend itself (libvirglrenderer with Venus on NVIDIA's Vulkan).
- Probed on Linux only, in `dgx:~/xnuhost/gputest/` (vtest socket, no macOS involved):
  - NVIDIA GB10 Vulkan 1.4.312 lists `VK_EXT_external_memory_dma_buf`, `VK_KHR_external_memory_fd`,
    `VK_EXT_image_drm_format_modifier`, `VK_EXT_external_memory_host`, fence/semaphore fd (grep over all devices,
    llvmpipe included: per-device not separated).
  - Ubuntu's virglrenderer 1.0.0: device enumerates, `vkCreateDevice` -3. virglrenderer 1.2.0 built from source
    (`-Dvenus=true -Drender-server-worker=thread`) + the project's Mesa 26.3.1 Venus (`gpu/venus/patches`):
    `vulkaninfo`: "Virtio-GPU Venus (NVIDIA GB10)", Mesa 26.3.1. (Ubuntu's Mesa 25.2 Venus against 1.2.0: -9.
    `VKR_DEBUG=validate` without the validation layer installed also gives -9.)
  - `gpu/venus/test/compute.c` hangs in `vkMapMemory` (`vtest_bo_create_from_device_memory` waiting on the socket);
    server: `virgl_renderer_resource_export_blob ... failed (-22)`. On NVIDIA the host-visible device memory exports
    as an OPAQUE fd, which vtest refuses (it takes dma-buf or shm only). virglrenderer hands out
    `virgl_resource_vulkan_info` (device/driver UUID, size, memory type) for exactly this case: the embedder imports
    the opaque fd into a Vulkan device of its own and maps it (what crosvm does).
  - `fki_hostcall.c`'s XLATE already translates `VM_IO|VM_PFNMAP` mappings (`follow_pfnmap_start`), so a driver
    mapping in the daemon can be handed to the hosted kernel.
- Work left for a real connection: (1) a virglrenderer backend in xnudrmd (contexts, execbuffer, caps, fences,
  blobs; opaque-fd blobs imported and mapped through Vulkan); (2) the Darwin Venus dylib (`gpu/venus/build-darwin.sh`)
  built in CI and packed into the bundle; (3) WindowServer and apps on it. Untested unknowns: whether an imported
  NVIDIA mapping's pages can be mapped by the hosted pmap, performance, the 16 KiB blob alignment patch on a 4 KiB host.
- Installed on dgx for this: `virgl-server` and build dependencies via apt.
