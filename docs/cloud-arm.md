# xnulinux on a rented cloud ARM VM, without a GPU

This is a how-to for running xnulinux on an arm64 VM from a cloud provider: no Apple hardware under it, no GPU, nobody
at its screen. It records what was done on one such VM, in the order that worked, with the failures met on the way.

It is not the only non-Apple host. Upstream xnulinux already runs on a bare-metal NVIDIA DGX Spark (see the main
[README](../README.md)), and macOS-DroidVM, UniXNU and Snapintosh run macOS on other non-Apple ARM machines in other
ways. This guide only adds the cloud case to xnulinux: a host whose memory map, timer and CPU differ from a Mac's,
reached only over ssh.

If you want an AI coding agent to do the work, give it [`cloud-arm-agent.md`](cloud-arm-agent.md) instead. The
procedure is the same.

**Before you start, two things to decide yourself.**

- **Apple's licence.** Apple's software licence for macOS restricts it to Apple-branded hardware. The SDKs and the
  Kernel Debug Kit used to build the kernel have similar terms. Whether to go on is your decision. This repository
  contains no Apple files, and nothing here should be read as legal advice.
- **Money.** A cloud VM costs money, and so do storage and network transfer if you save the disk elsewhere. No Mac
  is needed any more; one is only used on the alternative route of section 8, or if you prefer to build the GPU
  bundle with Apple's developer tools.
  Section 1 says what was used. Check your provider's prices first.

## Contents

1. What you need
2. How the pieces fit
3. Prepare the VM
4. Build the kernel on the VM
5. Reserve memory for the hosted kernel
6. The settings file
7. Build the disk on Linux (no Mac)
8. Alternative: build the disk on a Mac
9. Move a Mac-built disk to the VM
10. Boot and stop
11. Reach the hosted system
12. Tuning for CPU rendering
13. Check the result
14. Measured numbers
15. Troubleshooting
16. What does not work, and what was not tested
17. Saving your work

Commands are marked with where they run: **VM** (the cloud VM), **Mac**, **laptop** (your own machine) or **guest**
(inside the hosted macOS).

## 1. What you need

- **The GPU bundle** (`XnuCpuMetal.bundle`), the plugin that draws the desktop on the CPU. There are three ways to
  have one (section 7 step 1): build it on the VM with `tools/cloud/vm/build-gpu-bundle-linux.sh` (no Mac; about an
  hour and a half of compiling on 4 CPUs; it needs Apple's macOS SDK, which the kernel build of section 4 already
  puts on the VM); use a prebuilt bundle (one exists, built from source with its licence notices and tested with
  this guide, but **it is not published**: that decision is pending, so there is no download link here); or build
  it with Apple's developer tools on an Apple silicon Mac.
- **No Mac for the system disk.** The default route (section 7) builds it on the VM from Apple's restore image. The
  older route (section 8) builds it on an Apple silicon Mac with Apple's own installer; it is kept as the alternative
  and is the only way to get a disk with developer tools already on it.
- **An arm64 cloud VM.** What was used:
  - Google Cloud **C4A** (`c4a-highmem-4`): Arm **Neoverse V2**, **4 vCPU, 32 GB RAM**, 96 GB disk.
  - **Ubuntu 26.04 LTS** arm64, kernel **7.0.0-1017-gcp**, 4 KB pages.
  - CPU features that matter: pointer authentication (`paca` and `pacg` in `/proc/cpuinfo`). This CPU also faults
    on a failed authentication (FEAT_FPAC), which is why one of the fixes in this branch was needed.
  - The counter runs at 1 GHz (a Mac's runs at 24 MHz). Section 6 deals with that.
  - Root access, Secure Boot off, kernel lockdown off, and the right to load unsigned kernel modules.
  Any arm64 VM with pointer authentication, 4 KB pages and at least 16 GB of RAM should be a candidate, but only the
  one above was tested. The memory numbers in section 5 are for 32 GB.
- **Your own machine** with ssh, to drive the VM.
- **macOS 27.2 (26B123) from Apple.** On the default route the VM fetches 13.8 GB of Apple's restore image straight from
  Apple's update server. On the Mac route the Mac downloads the whole image (about 25 GB), and you also need a way to
  move about 30 GB from the Mac to the VM: an object-storage bucket, or plain ssh if the two are close.

Rough time and cost, where it was measured:

| Step | Measured |
|---|---|
| Kernel build on the VM, first time | About 55 minutes of VM time, including four failed tries that the fixes in this branch now avoid. A rebuild after a patch takes 25 to 35 seconds. |
| **Disk on the VM (section 7)** | **About 5.5 minutes from nothing**: 132 s to fetch and decrypt 13.8 GB, 183 s to build a 120 GiB image, 10 s to prepare and check it. |
| Disk and GPU bundle on the Mac (section 8) | 8 minutes once the guest was installed and the tools were there. Installing the guest (a download of about 25 GB plus Apple's installer) was not timed. |
| Mac to bucket, 23 GB | 40 seconds to pack, 206 seconds to upload (Mac and bucket in the same region). |
| Bucket to VM, 28 GB | About 10 minutes; the VM's disk was the slow part. |
| Boot to desktop | About 1 minute after the hosted root shell appears. |
| Storage | About 2.30 US dollars a month for 100 GB in one bucket. |
| Network transfer, 29 GB between continents | Estimated at 1.50 to 2.50 US dollars. Not confirmed on a bill. |

The Mac rows apply to the alternative route only. The VM's hourly price and the Mac rental were not recorded: look
them up.

## 2. How the pieces fit

- `xnu.ko` is the macOS kernel (XNU, built from Apple's open source) as a Linux kernel module. `fki.ko` is the small
  module that lends it CPUs, memory, a disk file and a network link.
- The hosted kernel needs one block of memory that Linux never touches. On a VM you reserve it on the kernel command
  line (section 5).
- The system disk is a file, `mac.img`. It is built on the VM from Apple's restore image (section 7), or made on a
  Mac from a normal macOS install (section 8). It comes with two small files: `mac.conf` (two volume identifiers) and
  `trustcache.bin`.
- With no GPU, everything on screen is drawn on the CPU by Mesa's lavapipe, inside every process that draws.
- The desktop is a framebuffer that the VM dumps to a file. You look at it by converting the dump to a PNG, and you
  type and click by appending events to another file.

## 3. Prepare the VM

1. Create the VM (4 vCPU, 32 GB, arm64, Ubuntu 26.04, 100 GB disk) with your provider's tools and ssh into it.

2. **VM.** Check that the host can do it at all:

   ```sh
   grep -c paca /proc/cpuinfo        # expect: the number of CPUs (4)
   getconf PAGESIZE                  # expect: 4096
   uname -r                          # used here: 7.0.0-1017-gcp
   cat /sys/kernel/security/lockdown # expect: [none] integrity confidentiality
   ```

   If `paca` is missing or the page size is not 4096, stop: this host will not work.

3. **VM.** Get this repository, at the path the build scripts expect:

   ```sh
   mkdir -p ~/w && cd ~/w
   git clone --branch cloud-arm https://github.com/gshost1/xnulinux.git poc
   ```

   Check: `ls ~/w/poc/scripts/vm-xnu-build.sh` prints the path.

4. **Laptop.** Clone the same branch and set up the helper tools (they are described in
   [`tools/cloud/README.md`](../tools/cloud/README.md)):

   ```sh
   git clone --branch cloud-arm https://github.com/gshost1/xnulinux.git
   cd xnulinux
   cp tools/cloud/cloud.env.example tools/cloud/cloud.env
   ```

   Edit `tools/cloud/cloud.env`: set `VM_HOST` (the VM's address), `VM_USER` and `VM_KEY`. Then:

   ```sh
   tools/cloud/vm-ssh 'uname -m'     # expect: aarch64
   ```

## 4. Build the kernel on the VM

The build script downloads a toolchain from macOS-DroidVM, Apple's XNU source, and some Apple files that are not open
source: the Command Line Tools package (from Apple's own server), two SDKs and a Kernel Debug Kit. **As upstream ships
it, the SDKs and the Kernel Debug Kit come from third-party mirrors on GitHub**, pinned and checksummed in
macOS-DroidVM's lock file. Apple offers the same files to holders of a developer account. Decide whether that is
acceptable to you before you run it. The files stay on the VM.

1. **VM.** Run the build in the background and keep the log:

   ```sh
   cd ~/w/poc
   nohup bash scripts/vm-xnu-build.sh > ~/build.log 2>&1 &
   ```

   It takes tens of minutes. Watch it with `tail -f ~/build.log`.

2. **VM.** On a fresh VM the first pass hangs in a helper called `decomment` (see Troubleshooting, "the build
   stops making progress"). When the log stops moving and this prints a number above zero:

   ```sh
   pgrep -c -x decomment
   ```

   clean up and start the same script again:

   ```sh
   pkill -x decomment; pkill -f vm-xnu-build.sh
   find ~/w/dvm/out -name '*.strip.*' -delete; find ~/w/dvm/out -name '*.unifdef.*' -delete
   cd ~/w/poc && nohup bash scripts/vm-xnu-build.sh > ~/build2.log 2>&1 &
   ```

   Do this promptly: each stuck process writes gigabytes of temporary files, and they filled a 96 GB disk once.

3. **VM.** Check:

   ```sh
   ls -la ~/w/dvm/out/k27/kernel-k27.macho
   ```

   Expected: a file of about 24 MB.

4. **VM.** Get the kernel collection input, `kc27.bin`. It is the kernel cache of the virtual-Mac variant of macOS
   27.2, which holds the Apple kernel extensions the hosted system needs. macOS-DroidVM's tools fetch that one member
   from Apple's own update server and check it against Apple's manifest; the `ipsw` tool unpacks it.

   ```sh
   cd ~/w/dvm
   mkdir -p toolchains/ipsw artifacts/27.2 out/kc
   curl -fsSL -o ~/ipsw.tgz https://github.com/blacktop/ipsw/releases/download/v3.1.749/ipsw_3.1.749_linux_arm64.tar.gz
   tar -C toolchains/ipsw -xzf ~/ipsw.tgz
   python3 scripts/macos-inputs.py --profile configs/macos-27.2-26B123.json --output artifacts/27.2/inventory-26B123
   python3 scripts/macos-fetch-member.py KernelCache --profile configs/macos-27.2-26B123.json \
     --inventory artifacts/27.2/inventory-26B123/identities.json --identity vma2macosap --output-dir artifacts/27.2 --jobs 8
   toolchains/ipsw/ipsw img4 im4p extract -o out/kc/kc27.bin artifacts/27.2/kernelcache.release.vma2
   ls -la out/kc/kc27.bin
   ```

   Expected: `kc27.bin` of about 82 MB. (macOS-DroidVM's lock file pins an x86-64 build of `ipsw`; the arm64 build
   above is the one that runs here. Its one-step `product.py inputs` also downloads the whole OS, many GB, which is
   not needed.)

5. **VM.** Apply xnulinux's patches, build the kernel again with the kexts, and install the collection. The disk in
   this guide is macOS 27.2, so the code-signing platform version must be 27:

   ```sh
   cd ~/w/poc
   AMFI_PLATFORM=27 bash scripts/vm-xnu-rebuild.sh 2>&1 | tee ~/rebuild.log
   ls -la /lib/firmware/xnu/
   ```

   Expected: lines `applied 0001-...patch` and so on, `kernel: NN s`, `collection: NN s`, and both `kc.bin` (about
   90 MB) and `kernel.macho` in `/lib/firmware/xnu/`. Always build with `kc27.bin` in place: without it the kernel
   links with overlapping segments and traps early (Troubleshooting, "UBSan trap").

6. **VM.** Build the two modules against the running kernel:

   ```sh
   cd ~/w/poc
   make -s -C /lib/modules/$(uname -r)/build M=$PWD/fki-ko modules
   make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko KBUILD_EXTRA_SYMBOLS=$PWD/fki-ko/Module.symvers modules
   ls -la fki-ko/fki.ko xnu-ko/xnu.ko
   ```

   Loading them prints "module verification failed ... tainting kernel". That is a warning.

## 5. Reserve memory for the hosted kernel

The hosted kernel needs about 8 GB as **one physically contiguous block**. Linux can sometimes find one on a freshly
booted host, but not reliably. The dependable way is to take the block away from Linux at boot (`mem=`) and hand it to
`fki.ko` as a "carve-out". The numbers depend on the VM's memory map.

On the 32 GB C4A VM, RAM runs from `0x40000000` to `0x83fffffff`, with firmware regions near the top. So:

- `mem=23G`: Linux uses RAM up to `0x5ffffffff`.
- carve-out: 8156 MB starting at `0x600000000`, ending below the firmware's region.
- `nokaslr`: otherwise the boot stub may place the Linux kernel image inside the carve-out on some boots.

A general-purpose reservation with `cma=8G` does **not** work here: on arm64 it is limited to memory below 4 GB.

1. **VM.** Install the settings and the boot-time service that loads `fki.ko` with the carve-out:

   ```sh
   cd ~/w/poc
   LINUX_MEM=23G CARVE_BASE=0x600000000 CARVE_MB=8156 bash scripts/vm-install-fki-service.sh
   sudo reboot
   ```

2. **VM.** After the reboot, check:

   ```sh
   cat /proc/cmdline                 # expect it to contain: mem=23G nokaslr log_buf_len=128M
   sudo dmesg | grep 'fki: .*MiB at' # expect: fki: 8156 MiB at 0x600000000 for the foreign kernel's DRAM (outside the host's memory)
   free -g | sed -n 2p               # expect about 22 GB total
   ```

For another VM size, read the memory map first (`sudo cat /proc/iomem | grep 'System RAM'`), keep the carve-out
inside RAM and clear of the top gigabyte, and set `LINUX_MEM` to end where the carve-out starts.

## 6. The settings file

`scripts/xnulinux-boot.sh` reads `/etc/xnulinux.conf`.

**VM.**

```sh
sudo tee /etc/xnulinux.conf >/dev/null <<'EOF'
CPUS=3
RAM_MB=7900
GPU=off
BOOTARGS="amfi_get_out_of_my_way=1 lp-sip0=2050 droidvm-timebase-hz=24000000 bt-transport-override=10"
EOF
```

Each line, and why:

| Setting | Why |
|---|---|
| `CPUS=3` | The hosted system takes Linux CPUs 0 to 2. The VM has 4; Linux needs one for itself and its device interrupts. 1, 2 and 3 were tried; 4 was not. On a larger VM: up to 32 (`LINUX64_MAX_CPUS`; `xnu.ko` gives the hosted system no more than that, and says so), leaving Linux at least one. 8, 9, 12 and 14 were tried on a 16-vCPU C4A VM: all boot, pass `tests/hosted` and run 14 threads 12.7 times as fast as one. |
| `RAM_MB=7900` | The hosted system's memory. It must fit inside the 8156 MB carve-out. |
| `RAM_MB` above 7900 | More memory: set `RAM_MB` and a carve-out that holds it (`CARVE_MB` = `RAM_MB` + 256 in section 5; Linux's `mem=` must end where the carve-out starts). It needs `xnu-patches/0009` (the physical aperture below the kernel). Before it the aperture followed the kernel and took as much of the kernel's 48 GiB of heap window as there is memory, and what was left could not hold the kernel map's fixed claims (24 GiB for the zone map, 11 GiB for the compressor): above about 8000 MB the boot panicked in `kmem_range_init`. Tested: 24000 MB on a 64 GB C4A VM (20 GiB written and read back, section 13's checks), and 7900 MB still boots. `XNU_ARGS="compressor_mb=N"` (a parameter of `xnu.ko`, default 6144) lowers the compressor's limit; without 0009 it was the only way above 8000 MB and reached 12000. |
| `GPU=off` | There is no GPU and no virtio-gpu device. Everything is drawn on the CPU. |
| `exec-env=WindowServer:LP_NUM_THREADS=8` in `BOOTARGS`, with `CPUS=8` | Optional: a faster desktop. The window server draws every frame on the CPU, and the Metal plugin gives each process two rasteriser threads whatever the CPU count (its default, meant for several hosted systems on one host). This boot argument sets the window server's own environment (`exec-env=NAME:VAR=VALUE`), so it uses the CPUs it has. Measured on a 16-vCPU C4A VM with a page animating in a full-size browser window: 4 to 5 frames a second with 4 CPUs and the default, 9 to 10 with 8 CPUs and 8 threads (and the plugin's `supportsFamily:` cache, without which the extra threads changed nothing). More than 8 CPUs and threads did not make it faster: 9 frames a second with 12 CPUs and 10 threads, the window server using 5.5 CPUs instead of 4.7. Mesa patch `0004` (the thread that queues a small render pass draws it itself, instead of waking every rasteriser thread for an icon) adds about 12%: 8.9 frames a second without it (`LP_INLINE_SCENE_PIXELS=0`), 9.95 with it, 11 threads no faster than 8. A frame there is about 21 ms of the window server encoding it, then about 75 ms of drawing in which the rasteriser threads are busy for 50: the pixels, not the hand-offs, are most of it. To see where a frame goes: `METAL2VULKAN_ENCODER_TIMES=1` (time by render pass; it makes each pass wait for the one before, so read its shares, not its totals) and `XNU_CPU_METAL_TRACE=1` (every pass and draw) in the same `exec-env`, with `XNU_CPU_METAL_STDERR=/var/tmp/wsgpu` to get the output of a daemon into a file (`/var/tmp/wsgpu.<pid>`). |
| `amfi_get_out_of_my_way=1 lp-sip0=2050` | Upstream's defaults: code-signing enforcement relaxed, as the disk is modified. They must be repeated because `BOOTARGS` replaces the default. |
| `droidvm-timebase-hz=24000000` | The host's counter runs at 1 GHz; a Mac's runs at 24 MHz, and parts of macOS 27 assume that. The kernel then scales the counter by 3/125 (1 GHz × 3 / 125 = 24 MHz). The cost is in section 14. |
| `bt-transport-override=10` | Without a Bluetooth device, `bluetoothd` waits ten seconds for a chip, exits, and is restarted, forever. This selects its built-in virtual controller, so it starts once and stays. |

Check: `cat /etc/xnulinux.conf` shows the four lines.

## 7. Build the disk on Linux (no Mac)

This is the main route. One script on the VM, `tools/cloud/vm/build-disk-linux.sh`, fetches macOS 27.2 (26B123) from
Apple's own update server and builds `mac.img`, `mac.conf` and `trustcache.bin` on the VM. Nothing of Apple's leaves
the VM, and nothing has to be moved between machines.

It does not need a Mac. The one input it does not make itself is the **GPU bundle** (step 1): a second script
builds that on the VM, or you bring a prebuilt one, or you build it on a Mac.

Everything in this section runs on the **VM** unless marked. Do sections 3 and 4 first: the script runs from this
repository's checkout in `~/w/poc`, and the disk must be the same macOS build as the kernel collection of section 4.

**What it needs on the VM:** 60 GB free where the disk goes; `sudo` that does not ask for a password; the packages
`git python3 curl rsync gdisk build-essential` and the headers of the running kernel (`--install-deps` installs what
is missing). `--help` says exactly which commands run as root.

1. **Get the GPU bundle onto the VM**, as a folder named `XnuCpuMetal.bundle`. It is the plugin that draws the
   desktop on the CPU (lavapipe and the Metal-to-Vulkan layer). There are three ways to have one:

   - **Build it on the VM.** No Mac. It needs the macOS SDK that section 4 left in
     `~/w/dvm/toolchains/sdks/MacOSX26.1.sdk` (Apple's files, fetched there from a third-party mirror, as section 4
     says), about 15 GB of disk, and time: LLVM is compiled twice, 29 minutes each with 4 jobs on an otherwise idle
     VM; everything else takes about 30 minutes.

     ```sh
     cd ~/w/poc
     sudo apt-get install -y clang-21 lld-21 llvm-21 cmake ninja-build meson glslang-tools python3-mako
     nohup bash tools/cloud/vm/build-gpu-bundle-linux.sh --out ~/gpu > ~/gpu.log 2>&1 < /dev/null &
     tail -f ~/gpu.log
     ```

     Check: the log ends with `bundle ready: .../gpu/XnuCpuMetal.bundle`. A stage that fails names its log; run the
     same command again and finished stages are skipped. This route is new: read "The GPU bundle" at the end of this
     section for exactly what was tested.

   - **A prebuilt bundle.** One was built for this guide from the sources and patches in this repository (both
     architectures from source, no private paths, with a notice file for every licence) and tested on this route. It
     is not published; that decision is pending. If you were given it, or built one yourself earlier, unpack it on
     the VM as `~/gpu/XnuCpuMetal.bundle`. Take a bundle only from someone you trust: it is code that runs inside
     every process that draws.
   - Build it on an Apple silicon Mac. This takes the `deps` and `gpu` stages of section 8 only: no macOS guest, no
     restore image, no desktop session. On the **Mac**, in a copy of `tools/cloud/mac/`:

     ```sh
     REPO_URL=https://github.com/gshost1/xnulinux.git REPO_REF=cloud-arm bash build-disk.sh deps
     nohup bash build-disk.sh gpu > ~/gpu.out 2>&1 &
     ```

     When `tail -1 ~/xnubuild/logs/gpu.log` ends in `gpu stage done`, send the bundle to the VM (85 MB packed):

     ```sh
     tar -C ~/xnubuild/xnulinux/gpu/xnu-cpu-metal/dist -czf - XnuCpuMetal.bundle | ssh VM_USER@VM_ADDRESS 'mkdir -p ~/gpu && tar -C ~/gpu -xzf -'
     ```

   The Mac build is the one with the most hours of use behind it.

   Check (VM): `ls ~/gpu/XnuCpuMetal.bundle/Contents/Frameworks/` lists `libvulkan_lvp.dylib`, `libvulkan.1.dylib`
   and `libxnu_m2v.dylib`. (A bundle built by the Mac route's scripts may also hold `libvulkan_virtio.dylib`; it is not
   needed with `GPU=off`, and the prebuilt bundle leaves it out.)

2. **Make the password file and the ssh key file.** The password is for the hosted user (and for `sudo` inside the
   guest). It is read from a file; it is never typed on a command line. A random one:

   ```sh
   (umask 077; head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16 > ~/guest-pass; echo >> ~/guest-pass)
   ```

   Or your own: `(umask 077; read -rs -p 'guest password: ' p; printf '%s\n' "$p" > ~/guest-pass)`.

   Then, from your **laptop**, the public half of the key you will use to reach the guest:

   ```sh
   tools/cloud/vm-ssh 'cat > ~/guest.pub' < ~/.ssh/id_ed25519.pub
   ```

   Check (VM): `stat -c %a ~/guest-pass` prints `600`, and `ssh-keygen -lf ~/guest.pub` prints a fingerprint.
   To log in by hand later you need the password: read the file yourself, or copy it to your laptop over ssh
   (`GUEST_PASSWORD_FILE` in `cloud.env`).

3. **Run the build** in the background and watch the log:

   ```sh
   cd ~/w/poc
   nohup bash tools/cloud/vm/build-disk-linux.sh --out /var/tmp/macimg --gpu-bundle ~/gpu/XnuCpuMetal.bundle \
     --password-file ~/guest-pass --ssh-key ~/guest.pub --install-deps > ~/disk.log 2>&1 < /dev/null &
   tail -f ~/disk.log
   ```

   It runs six stages: `preflight`, `deps`, `inputs`, `image`, `stage`, `finish`. Each prints `STAGE: done in N s`.
   If one fails, the last lines say what to fix; run the same command again and it continues after the last stage
   that finished.

   Check: the log's last lines are `disk ready in /var/tmp/macimg:`, the three files, and `boot it with: ...`. Then:

   ```sh
   cat /var/tmp/macimg/mac.conf     # ROOT_UUID=... BOOT_UUID=... MACOS=27.2
   python3 tools/cloud/vm/apfs-alloc-count.py --offset $((501 << 20)) /var/tmp/macimg/mac.img   # every volume: ok
   ```

4. Boot it: section 10. The first boot is slow: the root shell comes after about 40 seconds, but the screen stays
   black for up to two minutes, and the system is busy for about five minutes (load average above 100) while it
   builds its caches. Later boots show the desktop in about one minute.

**Options** (all in `build-disk-linux.sh --help`; each can also be set as an environment variable):

| Option | Default | What it does |
|---|---|---|
| `--size-gib N` | 64 | Size of the main container. The image is sparse: it takes about 22 GB on the VM's disk at any size. 120 was tested. |
| `--user NAME` | `xnu` | The hosted administrator. The other tools assume `xnu` (`GUEST_USER`). |
| `--ssh-key FILE`, `--ssh on\|off` | on when a key is given | Remote Login, and your key in the user's `authorized_keys`. |
| `--screen-sharing on\|off` | off | Screen Sharing (port 5900 in the guest). |
| `--autologin on\|off` | on | Off shows the login window at boot; log in with `tools/cloud/guest-login` (section 11). |
| `--tuning on\|off` | on | The settings of section 12, applied to the disk before the first boot. |
| `--macos NAME` | `27.2-26B123` | The macOS build. It must match the kernel collection. Only this one was tested. |
| `--work DIR` | `OUT-work` | Downloads and tools. Keep it: a later build reuses it and takes about 3 minutes. |
| `--force STAGE` | | Run a stage again. `--force image` rebuilds `mac.img` from the downloads. |

To change an option on a disk that exists (for example automatic login), stop the hosted system and run the same
command with the new value: only `stage` and `finish` run again, in about 10 seconds. That keeps everything already on
the disk. It is meant for a fresh disk. On a disk that macOS has already used it works too (it was done five times
here and every boot afterwards was normal), but Linux then writes into a volume macOS has been writing, and Apple's
own checker has things to say afterwards (section 16). For a disk you care about, change such settings inside the
guest instead, or build the disk again.

**Measured** on the VM of section 1 (4 vCPU; the hosted system was stopped or idle):

| Step | Measured |
|---|---|
| `deps` (fetch the tools, build `mkapfs` and `apfs.ko`) | 11 s |
| `inputs` (download and decrypt) | 132 s. 13.8 GB are fetched, of a restore image of 25.6 GB; they unpack to 17 GB, which stays in the work folder. Peak use while decrypting: 28 GB. |
| `image` | 183 s for 120 GiB |
| `stage` | 2 to 3 s |
| `finish` | 6 to 7 s |
| Whole build, from nothing | about 5.5 minutes |
| `mac.img` on disk | 22 GB (sparse; 20 GB System, 1.9 GB Data) |
| First boot: root shell / login window or desktop / calm | 40 s / about 2 minutes / about 5 minutes |

**What this disk lacks, compared with one built on a Mac (section 8):**

- **No developer tools and no third-party applications.** There is no compiler in the guest, so `tests/hosted`
  needs programs built elsewhere (its README says how). Install software inside the guest afterwards.
  `tools/hosted/install-developer-tools.sh`, run as root in the guest, installs Apple's Command Line Tools (clang, git,
  make, python3, swift, the macOS SDK) from Apple's update server: 520 MB to fetch, about five minutes on a Google Cloud
  C4A VM, tested on a disk built by this section. After it `tests/hosted/run.sh` builds its own programs.
- **No Recovery system.** There is no Recovery container, the Recovery volume is empty, and Preboot holds only the
  App cryptex, not the boot files a real Mac's firmware reads. A hosted boot uses none of them.
- **Files are stored uncompressed, and without their BSD file flags.** The Linux APFS driver reads Apple's
  compressed files but writes plain ones, and it cannot set flags such as `hidden` or `restricted`. The files that came
  with Apple's System volume keep both. Extended attributes are copied (the only one Apple's files carry here is
  `com.apple.rootless`; it was compared on all 17 folders that have it).
- **No Intel support.** The x86-64 and Rosetta shared caches are left out.
- **Apple's installer never ran.** The user account, the "setup done" marks and the launchd settings are written
  straight into the Data volume by `tools/hosted/gui-user.py` and the script.

It was booted 14 times, one of which failed (Troubleshooting, "A boot ends after a few seconds"), and run for 48
minutes with applications opened and closed. Section 16 says exactly what was tested. The Mac-built disk has more
hours behind it.

**How it works, in short.** Apple's restore image is a ZIP file on Apple's server, so single members can be fetched
by HTTP range: the System volume (a bare APFS container), two cryptex images and three trust caches. Two members are
encrypted; Apple's key server gives their keys without an account. The script makes a GPT disk with two APFS
containers: a small one of the "iBoot System Container" type with empty iSCPreboot, xART, Hardware and Recovery
volumes (without it the boot stops, see Troubleshooting), and the main one, which is Apple's System volume grown to
size, with Data, Preboot, VM and Update volumes added. The Linux APFS driver then copies the OS cryptex into the
System volume, the App cryptex into Preboot, and the system's own Data template into Data, one volume mounted at a
time. Last, the Data volume gets what upstream's `scripts/mk-macvm-disk.sh` gives it on a Mac.

**What the Linux build fetches, and under which licence.** Nothing in this table is stored in this repository. The
exact revisions are in `tools/cloud/vm/build-disk-linux.lock`.

| What | Revision | Licence | Used for |
|---|---|---|---|
| [macOS-DroidVM](https://github.com/Droid-VM/macOS-DroidVM) | commit `524d27b` | **none stated**: the repository has no licence file | Its range fetcher (`macos-inputs.py`, `macos-fetch-member.py`) and its offline APFS tools (`make-macos-disk.py`, `apfs-add-volumes.py`, `grow-data-store.py`). |
| [linux-apfs-rw](https://github.com/linux-apfs/linux-apfs-rw) | commit `0318712` | GPL-2.0-only | The kernel module `apfs.ko`, built for the running kernel and loaded while the disk is built. |
| [apfsprogs](https://github.com/linux-apfs/apfsprogs) | commit `1bd1c1c` | GPL-2.0-only | `mkapfs`, for the new volumes. |
| [ipsw](https://github.com/blacktop/ipsw) | release 3.1.749, checked by SHA-256 | MIT | Decrypting the two encrypted members. |
| macOS 27.2 (26B123) restore image | Apple's update server; manifest SHA-256 pinned by macOS-DroidVM | Apple's software licence | The system itself. See the note at the top of this guide. |

Because macOS-DroidVM states no licence, this repository copies none of its code. The script downloads it to your
VM at the pinned commit and runs it there, unchanged on disk. Three things are adjusted from outside at run time, and
`tools/cloud/vm/disk_linux.py` explains each: which volumes it adds to the main container, extended attributes in
its `rsync` calls, and a stand-in for `unshare` on hosts that forbid unprivileged user namespaces. Whether running
code that has no stated licence suits you is your decision.

**The GPU bundle.** `XnuCpuMetal.bundle` is built from open source: this repository's plugin and bridge
(GPL-2.0-or-later), metal2vulkan (GPL-2.0-or-later or LGPL-3.0-or-later), Mesa's lavapipe (MIT), LLVM (Apache-2.0 with
the LLVM exception) and the Khronos Vulkan loader (Apache-2.0). It contains no Apple library. Building it needs
Apple's macOS SDK (headers and library stubs), on a Mac or on Linux.

Three bundles were run on a Linux-built disk here:

| Bundle | How it was built | What it was run for |
|---|---|---|
| Mac build, with the Venus library | `tools/cloud/mac/build-disk.sh gpu` | 7 boots (one failed, see Troubleshooting) and a 48-minute run; it is also the bundle of the Mac-built disk, with many hours of use |
| Prebuilt bundle (not published) | on a Mac, both architectures from source, path-clean, stripped, no Venus library | 4 boots, a 25-minute run with applications opened and closed, `tests/hosted` |
| Linux build | `tools/cloud/vm/build-gpu-bundle-linux.sh`, on the VM | 2 boots (one with the bundle from the script as published), a 14-minute run with applications opened and closed, `tests/hosted` |

With each of them the window server, an arm64e program of Apple's, loaded the four files of the bundle, the desktop
and application windows were drawn, and no crash report was written for the window server or the icon service.

How the Linux build works: the distribution's clang 21 compiles for `arm64-apple-macos` and `arm64e-apple-macos`
against the SDK. LLVM's own linker (`ld64.lld`) links the arm64 half, but it cannot link arm64e (it has no
authenticated-pointer relocations), and a plain Linux build of Apple's linker cannot read the SDK's `.tbd` stubs. So
the script builds Apple's open-source `ld64` from cctools-port together with apple-libtapi, the pairing osxcross uses.
Rust builds the bridge (stable for arm64; nightly with `-Zbuild-std` for arm64e, then the same symbol renames and
branch rewrite as on a Mac). LLVM and Mesa are cross-built with the options of the Mac scripts. Where the Mac build
runs `codesign`, the linkers' own ad-hoc signatures are kept and refreshed by `tools/cloud/vm/macho-adhoc-resign.py`.

What the Linux build fetches besides the sources `gpu/xnu-cpu-metal/scripts/fetch-sources.sh` already names (all
pinned in `tools/cloud/vm/build-disk-linux.lock`):

| What | Revision | Licence |
|---|---|---|
| [cctools-port](https://github.com/tpoechtrager/cctools-port) (Apple's cctools and ld64 for Linux) | commit `e101a69` | APSL-2.0, parts GPL-2.0-or-later |
| [apple-libtapi](https://github.com/tpoechtrager/apple-libtapi) | branch 1300.6.5, commit `46e03a9` | University of Illinois/NCSA open source licence |
| Rust toolchains, through rustup | 1.100.0 and nightly-2026-11-24 | MIT OR Apache-2.0 |
| Vulkan-Headers | tag `vulkan-sdk-1.4.363.0` | Apache-2.0 OR MIT |

Limits of the Linux build as tested: it was built once, on the VM of section 1 (Ubuntu 26.04, clang 21.1.8, SDK 26.1), and
used for about twenty minutes. Three of the script's stages (`sources`, `bridge`, `llvm`) were run as the same
commands by hand before the script existed; the script has not been run from nothing in one go. Its bundle is not
stripped and its files contain the paths of the build folder: fine on your own VM, not something to pass on. The
graphics tests under `gpu/xnu-cpu-metal/test` were not run against it.

## 8. Alternative: build the disk on a Mac

This is the older route. Use it when you want a disk installed by Apple's own installer, or one with developer tools
or other applications already on it. It needs an Apple silicon Mac for a few hours (macOS 27, about 80 GB free, not
itself a virtual machine), a download of about 25 GB, and a transfer of about 30 GB to the VM (section 9). If you
built the disk in section 7, skip to section 10.

Everything in this section runs on the **Mac**. Copy `tools/cloud/mac/` there (or clone the repository) and work in
that folder. `build-disk.sh --help` lists the stages and settings.

1. If nobody is logged in at the Mac's screen (a rented Mac), turn on automatic login and reboot. Apple's
   Virtualization framework starts a macOS guest only for a user with a desktop session. Put the Mac user's password
   in a file only you can read, then:

   ```sh
   chmod 600 ~/mac-pass
   sudo python3 autologin.py "$USER" < ~/mac-pass
   sudo reboot
   ```

   Check after the reboot: `launchctl print gui/$(id -u) >/dev/null && echo session` prints `session`.

2. Look at the Mac and set up passwordless sudo (the disk script uses `sudo -n` throughout):

   ```sh
   bash build-disk.sh preflight
   bash build-disk.sh sudoers
   ```

   `preflight` changes nothing. Expect an Apple silicon CPU, macOS 27, about 80 GB free, and `hv_vmm_present=0`.

3. Install the tools and clone the repository. Point it at this branch so the GPU bundle gets the renderer fix:

   ```sh
   REPO_URL=https://github.com/gshost1/xnulinux.git REPO_REF=cloud-arm bash build-disk.sh deps
   ```

   Check: the last lines list versions of `tart`, `zstd`, `cmake`, `ninja`, `meson`, `llvm@22`, `glslang`, and the
   repository's commit.

4. Install the guest and build the GPU bundle. Set `IPSW` to the macOS 27.2 (26B123) restore image for Apple silicon,
   as a file you downloaded from Apple or Apple's own download address for it. It must be the same build as the
   `kc27.bin` from section 4. Both stages are long; run them where they survive a dropped connection:

   ```sh
   IPSW=/path/to/UniversalMac_27.2_26B123_Restore.ipsw nohup bash build-disk.sh vm  > ~/vm.out  2>&1 &
   nohup bash build-disk.sh gpu > ~/gpu.out 2>&1 &
   ```

   Check: `tail -1 ~/xnubuild/logs/vm.log` ends in `vm stage done`, and `tail -1 ~/xnubuild/logs/gpu.log` ends in
   `gpu stage done`. For a disk with room for more software, add `VM_DISK_GB=120` to the `vm` line (the image is
   sparse; 120 GB was used for the second image).

5. Make the disk. `EXTRAS=1` gives the guest user `xnu` a password of your own and turns on Remote Login, Screen
   Sharing and your ssh key. Create the two files first (the password file on one line, mode 600; the public key is
   the one whose private half you will use from your laptop):

   ```sh
   EXTRAS=1 GUEST_PASSWORD_FILE=~/guest-pass GUEST_PUBKEY_FILE=~/guest.pub bash build-disk.sh disk
   ```

   Check: the output ends with `disk stage done` and shows three files in `~/xnubuild/macvm/`: `mac.img` (sparse; 28
   GB used here), `mac.conf` with `ROOT_UUID=`, `BOOT_UUID=` and `MACOS=27.2`, and `trustcache.bin`.

   Without `EXTRAS=1` the user is `xnu` with upstream's default password, and there is no ssh into the guest.
   Third-party applications, developer tools included, can be put on the disk by setting `APPS` to a folder of
   `.app` bundles (a feature of upstream's `mk-macvm-disk.sh`).

The image contains macOS. **Do not publish it or put it in storage others can read.**

## 9. Move a Mac-built disk to the VM

The three files must end up in one folder on the VM. This guide uses `/var/tmp/macimg`.

**Simplest, when the Mac and the VM are near each other: ssh.** On the **Mac**, with a key the VM accepts:

```sh
bash build-disk.sh upload VM_USER@VM_ADDRESS /var/tmp/macimg
```

Between continents this ran at about 3 MB/s, which is hours for 28 GB.

**Faster over distance: a bucket.** Pack on the Mac, upload the parts in parallel, compose them, pull on the VM.
The scripts are written for Google Cloud Storage and need `gcloud` logged in on your laptop; set `BUCKET`, `MAC_HOST`,
`MAC_USER` and `MAC_KEY` in `cloud.env`. Any other object store works the same way with its own commands: upload
`part.*`, then on the VM `cat` them in name order into `zstd -d | tar -xSf -`.

1. **Mac.**

   ```sh
   bash pack-image.sh ~/xnubuild/macvm img1
   ```

   Expected: `packed in NN s: NN parts, NNG`.

2. **Laptop.** Send the parts and check every one:

   ```sh
   tools/cloud/relay-mac-to-bucket.sh img1
   ```

   Expected last line: `relay: OK gs://BUCKET/img1.tar.zst NNN bytes from NN verified parts`. The Mac never gets cloud
   credentials: the laptop makes one upload address per part. A rerun sends only parts that are missing or wrong.

3. **Laptop.** Pull on the VM. The access token travels on standard input:

   ```sh
   gcloud auth print-access-token | tools/cloud/vm-run tools/cloud/vm/pull-image.sh "$BUCKET" img1 /var/tmp/macimg
   ```

   Expected: `pulled in NNN s`, then the three files and the contents of `mac.conf`.

Check on the **VM**, whichever way you used:

```sh
ls -ls /var/tmp/macimg/        # mac.img, mac.conf, trustcache.bin
cat /var/tmp/macimg/mac.conf   # ROOT_UUID=... BOOT_UUID=... MACOS=27.2
```

## 10. Boot and stop

1. **Laptop.** Boot the image and wait 100 seconds:

   ```sh
   tools/cloud/vm-run tools/cloud/vm/boot-image.sh /var/tmp/macimg 100
   ```

   It copies the trust cache and `mac.conf` into place, turns off "panic on oops" (so a fault in the hosted kernel
   ends the run instead of rebooting the VM), and runs `scripts/xnulinux-boot.sh`. Expected: the end of the hosted
   console, with lines from `launchd` and a prompt `xnulinux#`, and `xnu.ko loaded: 1`.

2. **Laptop.** Look at the screen about a minute later:

   ```sh
   tools/cloud/guest-screenshot shot.png
   ```

   Expected: a 1280×800 PNG of the desktop (wallpaper, menu bar, Dock).

3. To stop cleanly, sync inside the guest, then stop from the **VM**:

   ```sh
   tools/cloud/guest-ssh 'sync; sync'
   tools/cloud/vm-ssh 'cd ~/w/poc && bash scripts/xnulinux-boot.sh stop'
   ```

   Expected: `hosted system stopped`. Stop it before you stop or delete the VM.

To boot again after a VM restart, run step 1 again. To have it start with the VM, see `scripts/install-service.sh`
(not tried on this host).

## 11. Reach the hosted system

Set `GUEST_KEY` and `GUEST_PASSWORD_FILE` in `tools/cloud/cloud.env` on your laptop. The guest gets its address from
the VM by DHCP; the tools look it up.

- **A root shell that always works: the console.** It needs no login and no network in the guest.

  ```sh
  tools/cloud/guest-console 'sw_vers' 8
  ```

  Expected: `ProductName: macOS`, `ProductVersion: 27.2`, `BuildVersion: 26B123`. Keep lines short; the console is slow.

- **ssh** (needs `--ssh-key` in section 7, or `EXTRAS=1` in section 8). It jumps through the VM:

  ```sh
  tools/cloud/guest-ssh 'sw_vers -productVersion; whoami'      # expect: 27.2 and xnu
  tools/cloud/guest-ssh 'sudo -S -p "" id -u' < "$GUEST_PASSWORD_FILE"   # expect: 0
  ```

  The second form is how to become root: the password goes over standard input, never on a command line.

- **Screenshots.** `tools/cloud/guest-screenshot out.png`. The dump lags the screen by a few seconds.

- **Keyboard and pointer.**

  ```sh
  tools/cloud/guest-input click 640 400
  tools/cloud/guest-input key cmd space
  tools/cloud/guest-input type 'hello' key return
  ```

  Coordinates are pixels on the 1280×800 screen. There is no acknowledgement: take a screenshot to see the effect.

- **Logging in at a login or lock window.** The disk logs in automatically at boot (unless it was built with
  `--autologin off`). But if the window server crashes,
  the session ends at a login window, and there is nobody to type. Do it from the laptop:

  1. `tools/cloud/guest-screenshot now.png`, and look at it. You must see the password field.
  2. If the field is not focused, click it (for the lock screen at this resolution: `tools/cloud/guest-input click 640 718`).
  3. `tools/cloud/guest-login`

  Never skip the fresh screenshot. A password typed while the screen is still changing goes to whatever has the
  keyboard at that moment.

- **Screen Sharing.** Open a tunnel and connect with the Screen Sharing app on a Mac:

  ```sh
  tools/cloud/guest-ssh -L 5900:localhost:5900 -N
  ```

  Then connect to `vnc://localhost:5900` as `xnu`. The server offers only Apple's authentication types, so a generic
  VNC client will not connect. On a running system `tools/hosted/enable-screen-sharing.sh` (as root in the guest) turns
  the service on and grants its agent screen capture and input; without the grants a session is refused or cannot
  click. `tools/cloud/vnc-check.py PORT USER PASSWORD-FILE OUT.png [click X Y]` is a client without a window: it logs in
  with Apple's authentication, saves one full frame and can send a click. Tested with it through a tunnel from a Mac
  (Google Cloud C4A, CPU rendering): a 1280x800 frame in 1 to 3 seconds, and a click that the hosted desktop acted on
  ("Your screen is being controlled" shows there). A session with Apple's Screen Sharing app itself was not run.

### A stream from the Linux host (WebRTC)

`tools/hosted/xnu-stream.py` runs on the Linux host, reads the screen where `xnu.ko` dumps it, encodes it there (H.264,
or VP8 with `--codec vp8`) and pushes it to one browser over WebRTC; the viewer's pointer, buttons, wheel and keys come
back on a data channel and go to the hosted system as `tools/hosted/xnu-input.py` sends them. macOS takes no part (no
Screen Sharing, no capture in the guest, no login), so it also shows the login window and costs the hosted system
nothing but the dump.

On the host, once: `sudo apt-get install --no-install-recommends gstreamer1.0-tools gstreamer1.0-plugins-base
gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-nice
gir1.2-gst-plugins-bad-1.0 gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 gir1.2-nice-0.1 python3-gst-1.0`, and in
`/etc/xnulinux.conf` a dump in memory, 60 times a second (the default is once a second, to a file):

```sh
FB_DUMP=${FB_DUMP:-/dev/shm/xnu-fb.raw}
XNU_ARGS="${XNU_ARGS:-fb_dump_ms=16}"
```

Let the boot script create that file (one made by another user in `/dev/shm` is refused: "cannot open fb_dump"); for
`tools/hosted/fb2png.py` and the helpers that read `/var/tmp/xnu-fb.raw`, link it: `ln -s /dev/shm/xnu-fb.raw
/var/tmp/xnu-fb.raw`. Then, with the hosted system up:

```sh
python3 tools/hosted/xnu-stream.py                    # on the host: page on 127.0.0.1:8555, media on TCP port 8556
ssh -N -L 8555:127.0.0.1:8555 -L 8556:HOST-INTERNAL-ADDRESS:8556 USER@HOST    # on your computer
```

and open `http://127.0.0.1:8555/`. Nothing is opened to the internet: the page is on the host's loopback and the media
goes over TCP through the tunnel. `--advertise PUBLIC-ADDRESS` offers UDP on `--media-port` instead, which wants that
port open to the viewer and the page behind access control of its own (it has none); that was not run.

Measured on a Google Cloud C4A VM from a Mac 50 ms away (headless Chrome, through the tunnel), with a page animating
in a full-size Safari window: the hosted screen at 47 frames a second (52 without the stream), 46.9 a second decoded by
the viewer, none dropped, under 1 Mbit/s, 40% of one host CPU. Screen Sharing gave a VNC client 8 to 10 updates a
second from the same screen. From a click sent by the viewer to the changed pixels back in its video: 306 ms at the
median (290 to 363), of which the hosted system itself takes 147 (a click written on the host to the changed pixel in
the dump; 94 to 140 for the Apple menu); the page shows the browser's own pointer, so the pointer moves at once.

Not there yet: the pointer's image (macOS hands it over as a layer of its own, which this display driver does not draw
without a GPU device, so it is in the dump at some times and not at others: no I-beam or resize arrows), frames are
read while the display may be writing them (a torn frame now and then), one viewer at a time, no sound.

### Screen capture and scripting over ssh

A program started from an ssh session cannot capture the screen (`screencapture`: "could not create image from display")
and its Apple events wait behind a consent dialog on the hosted screen (`"sshd-keygen-wrapper" wants access to control
"Finder"`). `tools/hosted/grant-automation.sh`, run once as root in the guest after the first login, writes the grants
(screen capture, accessibility, input events, and Apple events to Finder, System Events, Terminal, Safari and Chrome):

```sh
tools/cloud/guest-ssh 'cat > /tmp/grant.sh' < tools/hosted/grant-automation.sh
tools/cloud/guest-ssh 'echo PASSWORD | sudo -S sh /tmp/grant.sh'
```

Check: `screencapture -x /tmp/s.png` writes a 1280x800 image, and
`osascript -e 'tell application "Finder" to get name of startup disk'` prints `Macintosh HD` at once. Its header says how
to grant other programs and targets and how to take the grants out again. macOS 27 still shows one dialog the first time an ssh session
captures the screen, and again every 30 days (`"com.apple.sshd-session" is requesting to bypass the system private
window picker`): the capture works anyway; click Allow once with `tools/cloud/guest-input` (writing replayd's
`ScreenCaptureApprovals.plist` beforehand did not prevent it). Tested on a Mac-built disk (macOS 27.2.1) on a
Google Cloud C4A VM: denied before, both working after, denied again after `REVOKE=1`.

## 12. Tuning for CPU rendering

With `GPU=off` the window server alone takes about one CPU while the screen is changing. These changes were applied
inside the guest and kept. They can all be undone. **The gain was not measured**: no before-figure was taken.

**A disk built on Linux (section 7) has all of this already**, unless you passed `--tuning off`: the script writes
the same settings into the disk before the first boot. Do only the check at the end of this section. The commands
below are for a Mac-built disk.

**Guest**, as root (`sudo -S` over `guest-ssh`, or the console):

```sh
for l in com.apple.security.cryptexd com.apple.locationd com.apple.icloud.searchpartyd com.apple.findmy.findmybeaconingd \
  com.apple.icloud.findmydeviced com.apple.findmymacd com.apple.findmymacmessenger com.apple.softwareupdated \
  com.apple.mobile.softwareupdated com.apple.adid com.apple.fairplayd com.apple.fairplaydeviceidentityd \
  com.apple.modelcatalogd com.apple.perfpowermetricd; do launchctl disable system/$l; done
mdutil -a -i off
pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0
```

`cryptexd` and `locationd` are on the list because they crashed repeatedly here; the others are idle work for hardware
or services the hosted system does not have.

**Guest**, as the user `xnu` (less for the compositor to blend and animate):

```sh
defaults write com.apple.universalaccess reduceTransparency -bool true
defaults write com.apple.universalaccess reduceMotion -bool true
defaults write com.apple.Accessibility ReduceMotionEnabled -bool true
```

These three lines are the settings that were applied, but the exact command lines were not kept; check them in System
Settings, Accessibility, Display if they do not take.

Then reboot the hosted system (section 10). Check: `launchctl print-disabled system | grep -c 'disabled'` is 14 or
more, and `top -l 2 | grep 'CPU usage' | tail -1` shows about 90 % idle a few minutes after login (the first sample of `top` is not meaningful).

Two cautions from experience:

- Some user agents for the voice assistant, suggestions, weather and tips were also disabled here. **Leave
  `com.apple.siriactionsd` enabled.** Disabling it makes three control-centre widgets crash at every login
  (Troubleshooting, "widgets crash at login").
- `softwareupdated` kept running although disabled.

## 13. Check the result

Run these from the **laptop** and compare:

```sh
tools/cloud/vm-ssh 'lsmod | grep -c "^xnu "'                                  # 1
tools/cloud/guest-ssh 'sw_vers -productVersion; pgrep -x Dock >/dev/null && echo desktop-up'   # 27.2, desktop-up
tools/cloud/guest-ssh 'launchctl print system/com.apple.bluetoothd | grep -E "runs|last exit"' # runs = 1, never exited
tools/cloud/guest-screenshot check.png                                        # a PNG of the desktop
tools/cloud/boot-cycle.sh 0 check                                             # dock=up ... crash-reports: ...
```

The pointer-authentication fix. It needs `clang` in the guest. A disk built on Linux has no compiler: build the four
test programs elsewhere and pass their folder, as [`tests/hosted/README.md`](../tests/hosted/README.md) describes
(`sh ~/xt/hosted/run.sh FOLDER`).

```sh
tar -C tests -cf - hosted | tools/cloud/guest-ssh 'rm -rf ~/xt && mkdir ~/xt && tar -C ~/xt -xf - && sh ~/xt/hosted/run.sh'
```

Expected last line: `hosted tests: pass`. Details: [`tests/hosted/README.md`](../tests/hosted/README.md).

The renderer fix has its own test, a plain Vulkan program that is built on the Mac against the lavapipe from the GPU
bundle build: [`tests/lavapipe/README.md`](../tests/lavapipe/README.md). Expected last line: `RESULT: PASS`.

## 14. Measured numbers

All on the C4A VM described in section 1, hosted macOS 27.2 with 3 CPUs, CPU rendering.

| What | Value |
|---|---|
| Idle, a few minutes after login, after tuning | 90 to 96 % of 3 CPUs idle, about 470 processes |
| Window server while the screen changes | about 97 % of one CPU |
| Desktop after the root shell | about 1 minute; Dock and Finder 25 s after the window server |
| First C compile in the guest | 15 s |
| A new Swift package, `swift build` | 18 s |
| Kernel rebuild after a patch | 26 s, plus 9 s for the collection |
| Icon-service renderer crashes in the first 240 s after login | 17 and 19 in two boots before the renderer fix; 0, 0, 0 in three boots after |

**Cost of the 24 MHz timebase.** With the counter scaled, a user program cannot read the hardware counter directly;
every read is a trap into the kernel. Measured in the guest:

| Call | Time |
|---|---|
| `mach_absolute_time` | 400 ns |
| `mach_continuous_time` | 400 ns |
| `clock_gettime` | 404 ns |
| `getppid` (a plain system call, for comparison) | 407 ns |

So a timebase read costs the same as a system call. With `xnu.ko perf=1`, the first 8 minutes of a boot had 51.0
million traps from user space of all kinds, and idle had 1,500 to 3,000 a second. Even if every one were a timebase
read, that is 51 M × 0.4 µs = about 20 s of CPU out of about 1,440 CPU-seconds: **at most 1.4 %**, and about 0.1 % of
one CPU at idle. A faster path for user space was judged not worth building.

**Pointer-authentication keys**, from `tests/hosted/keys.c`:

| Process | Real Apple silicon Mac | Hosted, before the fix | Hosted, with the fix |
|---|---|---|---|
| plain `arm64` | all four off | IA off, IB **on**, DA off, DB **on** | all four off |
| `arm64e` | all four on | all four on | all four on |

## 15. Troubleshooting

Each entry: what you see, why, what to do. All of these happened.

### Host and build

**`cma: Failed to reserve 8192 MiB` at boot, after adding `cma=8G`.**
Cause: on arm64 the global CMA area must lie below 4 GB. A per-node area (`numa_cma=0:8G`) does reserve the memory,
but `fki.ko` does not use it.
Fix: do not use CMA. Use `mem=` and the carve-out (section 5).

**`apt-get` fails on `p7zip-full` ("has no installation candidate").**
Cause: Ubuntu 26.04 dropped the package; `7zip` provides `7z`.
Fix: fixed in this branch (`scripts/vm-xnu-build.sh` asks for it only where apt has it).

**The build stops with `sed: can't read toolchains/linux/cctools-work/.../thread_status.h: No such file or directory`.**
Cause: the script patched a toolchain tree that is only cloned later, so it failed on a host that had never built.
Fix: fixed in this branch.

**`ConnectionResetError: [Errno 104] Connection reset by peer` during `setup-appleclang.py fetch`.**
Cause: the network.
Fix: run the script again. Downloads are checksummed, and what is complete is not fetched twice.

**The build stops making progress; `decomment` processes use a full CPU each; the disk fills.**
Cause: a helper in XNU's build keeps `getc()`'s result in a `char`. On arm64 Linux `char` is unsigned, the end-of-file
value never matches, and it loops forever, writing `*.strip.<pid>` files of about 8 GB each. The build script has the
fix (`char` to `int`), but it can only apply it once the source tree exists, and on a fresh host the tree is created
by the same step that then runs the helper. So the first pass always hangs.
Fix: section 4 step 2: kill, delete the temporary files, run the script again. The second pass applies the fix first.
Not fixed in this branch: a clean fix belongs inside macOS-DroidVM's `setup-env.py`.

**`System ERROR: errno=28 : No space left on device` while extracting the Kernel Debug Kit.**
Cause: the temporary files from the hang above.
Fix: delete `*.strip.*` and `*.unifdef.*` under `~/w/dvm/out`, then run again.

**`cp: cannot create regular file '/lib/firmware/xnu/kernel.macho'`.**
Cause: nothing created the directory on a fresh host.
Fix: fixed in this branch (`scripts/vm-xnu-rebuild.sh` creates it).

**The kernel traps at once: `Oops - BRK`, with `wfe_timeout_configure` and `___ubsan_handle_sub_overflow_minimal`
when symbolised. Seen when loading a kernel built without `kc27.bin`.**
Cause: without `kc27.bin` the rebuild script skips the step that lays out the kernel's segments, and links with a
stale layout from macOS-DroidVM. xnulinux's patches make the code segment bigger, so it overlaps the next segment;
the linker says nothing. At run time a string the kernel needs has been overwritten, the device-tree lookup for the
clock fails, the timebase reads as zero, and an overflow check traps. It has nothing to do with the host.
Fix: always put `kc27.bin` in place before `vm-xnu-rebuild.sh` (section 4). The module's bare-kernel modes (`mode=1`,
`mode=2`) are bring-up leftovers; `mode=2` also fails later for another reason. Only `mode=3`, which the boot script
uses, is expected to work.

**After a crash of the VM, `insmod: ERROR: could not insert module fki-ko/fki.ko: Invalid parameters`.**
Cause: the VM rebooted on a kernel panic before the freshly built modules were written to disk; they are empty files.
Fix: rebuild the modules (section 4 step 6), and `sync` before any risky load. `boot-image.sh` turns off
`panic_on_oops` so that a fault in the hosted kernel no longer reboots the VM.

**The hosted system stops at `Waiting on ... IOMedia ... Apple_HFS`.**
Cause: no disk, or the identifiers in `mac.conf` are not this disk's.
Fix: check that `/var/tmp/mac.conf` is the one that came with `mac.img`.

**Programs are killed at launch on a 27.2 disk; the log talks about code signatures and platform.**
Cause: the collection was patched for the wrong platform version. The script's default is 26 (for a 27.0.1 disk).
Fix: `AMFI_PLATFORM=27 bash scripts/vm-xnu-rebuild.sh`.

### Linux disk build

**The hosted system panics during boot. The log has `get_apfs_node: Timed out waiting for node with role 5 on
69646961-6700-11AA-AA11-00306543ECAC`, `mount_phase_one: xART volume mount failed - error 49154` and `Boot task failed:
mount-phase-1 - exited due to SIGABRT`.**
Cause: the disk has one APFS container only. launchd's first mount phase looks for the xART volume in the container of
a GPT partition whose type is "iBoot System Container" (the GUID in the message), as on every installed Apple
silicon disk. macOS-DroidVM's own disk layout keeps xART in the main container and marks it in its own disk driver,
which xnulinux does not have. The first Linux-built disk here, made with that layout, stopped exactly there.
Fix: a second, small container of that partition type with iSCPreboot, xART, Hardware and Recovery volumes, all
empty. `build-disk-linux.sh` makes it (500 MiB, the disk's first partition). If you see this panic, the disk was not
made by that script, or its first partition is damaged: `sgdisk -p mac.img` must list `iBootSystemContainer`.

**`ConnectionResetError: [Errno 104] Connection reset by peer`, often followed by `zipfile.BadZipFile: File is not
a zip file`, while reading the restore image.**
Cause: Apple's server drops a connection now and then; macOS-DroidVM's fetch tools do not retry the first read.
Fix: nothing to do. The script retries (up to 8 times for the manifest, 12 for a member) and prints `try N failed`.
Parts already fetched are kept. It happened in two of two full runs here.

**`unshare: write failed /proc/self/uid_map: Operation not permitted`.**
Cause: macOS-DroidVM runs `mkapfs` in a user namespace, and Ubuntu forbids unprivileged user namespaces.
Fix: handled. The script detects it and runs that one command with `sudo` instead.

**`ValueError: path must stay within .../macOS-DroidVM`, or `refusing to overwrite .../inventory`.**
Cause: macOS-DroidVM's tools only accept paths inside their own folder, and its inventory tool wants a folder that
does not exist yet.
Fix: handled. The script keeps Apple's files inside the fetched tree (`WORK/macOS-DroidVM/artifacts/`). You only meet
these messages when you call those tools by hand.

**`build-disk-linux: sudo asks for a password` (exit status 3).**
Cause: the script uses `sudo -n` and never prompts.
Fix: give the VM user passwordless sudo (cloud images usually have it), or run it as a user that has it.

**The macOS kernel log has, for the System, Data and Preboot volumes at every boot,
`sanity_check_alloced_blocks: ... fs_alloc_count mismatch: ... udata: N fs_alloc_count A != count C`.**
Cause: a bookkeeping difference in the Linux APFS driver. Each volume keeps two running totals, blocks allocated and
blocks freed. On a volume written by Apple their difference is exactly the number of data blocks; macOS relies on
that. The Linux driver also adds the tree nodes it allocates and frees to those totals. macOS then counts those nodes
twice and prints the line. No data is wrong, and macOS never corrects the totals by itself: the first Linux-built
disk here printed the three lines at every boot.
Fix: `build-disk-linux.sh` runs `tools/cloud/vm/apfs-alloc-count.py --fix` as its last step. It walks each volume,
counts the data blocks and sets the "allocated" total to match. After it: 0 such lines in each of the 8 boots whose
kernel log was read. To check a disk
that is not booted: `python3 tools/cloud/vm/apfs-alloc-count.py --offset $((501 << 20)) mac.img`.

**A boot ends after a few seconds. The log has `[Event: fsck] posix_spawn(): 14: Bad address` and
`userspace panic: boot task failure: fsck - posix_spawn: 14: Bad address`.**
Cause: unknown. launchd's very first program start of the boot failed, and launchd stops the system on purpose when a
boot task fails. It happened on one boot of 14 of the Linux-built disk. The disk had not changed since the boot
before and checked clean; the next boot of the same disk was normal. Compile jobs were running on the VM at the
time, as they were during other boots that worked. Whether it is tied to the Linux-built disk or to the host being
busy was not established.
Fix: stop the run (`scripts/xnulinux-boot.sh stop`) and boot again. `boot-image.sh` reports this case with exit
status 1 and the panic line.

**The screen is black after the first boot of a new disk, although the root shell answers.**
Cause: the first boot builds caches. The login window or desktop appeared about two minutes after boot, and the load
average stayed above 100 for about five minutes.
Fix: wait. Check with `tools/cloud/guest-ssh uptime` rather than by sending input.

**apfsprogs' `apfsck` stops on the image with `Resource compressed file: block metadata is too big`.**
Cause: a limit of that checker on some of Apple's compressed files. It says nothing about the disk.
Fix: check from inside the booted guest instead: `fsck_apfs -n -l /dev/disk2s1` (and `s2`, `s3`).

### Mac

**`tart create` ends with "The virtual machine failed to start".**
Cause: the user has no desktop session (nobody logged in at the screen).
Fix: automatic login and a reboot (section 8 step 1).

**`brew install cirruslabs/cli/tart` no longer works.**
Cause: tart moved to another Homebrew tap, and Homebrew ignores a third-party tap until it is trusted.
Fix: `build-disk.sh deps` does `brew tap openai/tools; brew trust openai/tools; brew install openai/tools/tart`.

**Mesa's build stops with a Python error.**
Cause: Mesa needs Python 3.10 or newer; the system `python3` is 3.9.
Fix: `build-disk.sh gpu` makes its virtual environment from Homebrew's Python 3.13.

**The desktop never appears; the hosted log says
`XnuCpuMetal: dlopen(libvulkan_lvp.dylib) failed: symbol not found in flat namespace '_spvBinaryToText'`
and the window server aborts in `__WSSystemCanCompositeWithMetal`.**
Cause: Homebrew's `spirv-tools` is installed (it comes with `glslang`). Mesa finds it through pkg-config and compiles
calls to it into lavapipe, but the driver is linked without that library.
Fix: `brew unlink spirv-tools`, delete the lavapipe build folders, rebuild lavapipe and the bundle. `build-disk.sh
gpu` now does this and refuses a bundle with undefined `_spv` symbols. Upstream has a similar change on a CI branch.

### Transfer

**`zstd: Data corruption detected` when unpacking on the VM.**
Cause: one part failed to upload in a second push, and the stale part from the first push went into the composed
object.
Fix: compare checksums of every part with the source before composing. `relay-mac-to-bucket.sh` does: it refuses to
compose until all match, and stops if the bucket holds a part the Mac does not have.

### In the hosted system

**The hosted system reaches some sites and not others: `curl https://github.com` connects and then times out, a download
stops after about 64 KB, while small pages load.**
Seen on Google Cloud (C4A, `c4a-standard-16`, Ubuntu 24.04, kernel 7.0.0-1017-gcp, gVNIC). Two causes on the Linux side:
- The path's MTU is 1460 and the hosted `en0` has 1500, so the far end's full-size segments do not fit. A TLS handshake
  with a large reply (github.com, registry.npmjs.org) never finishes.
- The uplink has hardware GRO on (`ethtool -k <uplink> | grep rx-gro-hw`). Linux segments its packets again on the way
  to `xnu0`, and for some of them the segmentation fails (`__skb_gso_segment` returns `-EINVAL` in
  `validate_xmit_skb`): the packet and every retransmission of it are dropped. `cat /sys/class/net/xnu0/statistics/tx_dropped`
  climbs while a download is stalled.
Fix: `scripts/vm-net-up.sh` (run by `xnulinux-boot.sh` at every boot) now clamps the TCP MSS to the path MTU and turns
hardware GRO off on the uplink; software GRO stays on. Measured after: github.com and the npm registry answer, a 58 MB
download runs at 85 MB/s, `tx_dropped` does not move.

**Notification and Dock icons are blank squares; `iconservicesagent` crashes again and again
(`EXC_BAD_ACCESS` in `lp_rast_triangle_32_*` inside `libvulkan_lvp.dylib`); once the window server died the same way
and the session ended at a login window.**
Cause: a bug in Mesa's lavapipe. When a descriptor set is pushed over one with another layout, lavapipe copies the
old set's bytes over the new one and loses its built-in ("immutable") sampler. The shader then indexes a table with
garbage. It is intermittent: four of six boots had it.
Fix: in this branch, `gpu/xnu-cpu-metal/patches/mesa/0002-lavapipe-push-immutable-samplers.patch`
([upstream PR #17](https://github.com/AFK-surf/xnulinux/pull/17)). Rebuild the GPU bundle from this branch, or swap
the library in a running system with `tools/cloud/install-renderer-lib.sh`. Not reported to Mesa.

**Applications that are plain `arm64` (not `arm64e`) crash when a window or sheet opens, or at the first exception:
`EXC_ARM_PAC_FAIL` or SIGBUS in `libunwind`.** This includes most third-party software and some developer tools.
Cause: the hosted kernel left two of the four pointer-authentication keys (IB and DB) switched on for plain `arm64`
processes. The system unwinder checks each return address with the IB key; a plain `arm64` frame's return address is
unsigned; on a CPU that faults on a failed check (FEAT_FPAC, as Neoverse V2 has) the process dies. A real Mac runs
such processes with all four keys off.
Fix: in this branch, in `xnu-patches/0001-linux64-machine-layer.patch`
([upstream PR #15](https://github.com/AFK-surf/xnulinux/pull/15)). Rebuild the kernel (section 4 step 5) and reboot
the hosted system. UniXNU fixed the same thing in its kernel earlier.

**`bluetoothd` starts every ten seconds; the log fills with `AppleVPKeyStore ... unexpected session uid: -1 requested
by: bluetoothd`.**
Cause: with no Bluetooth device described, it assumes a real Mac's chip, waits ten seconds for its driver, gives up
and exits; launchd restarts it. The keystore lines are a harmless query at each start, not the cause.
Fix: boot argument `bt-transport-override=10` (section 6).
[Upstream issue #16](https://github.com/AFK-surf/xnulinux/issues/16) proposes describing the device instead.

**`ScreenshotControls`, `DisplayControls` and `WindowManagerControlsExtension` crash at every login with a Swift
assertion in WidgetKit.**
Cause: self-inflicted. The tuning had disabled `com.apple.siriactionsd`, which those widgets ask for their actions.
The same macOS build in a normal virtual Mac does not crash.
Fix: leave `com.apple.siriactionsd` enabled (`launchctl enable gui/501/com.apple.siriactionsd`, then log in again).
That the crashes stop was not verified afterwards.

**`cryptexd` crashes in a loop; `locationd` crashes at boot.**
Cause: not investigated. Both depend on things the hosted system does not have.
Fix: disable them (section 12).

**The session is at a login window and nothing can type.**
Fix: section 11, "Logging in at a login or lock window".

**A permission prompt for "sshd-keygen-wrapper" appears.**
Cause: something run over ssh used automation (for example `osascript` talking to System Events).
Fix: answer it with `guest-input`, or avoid automation over ssh.

**`log show` shows nothing from your own program or library.**
Cause: unknown. Do not rely on it for your own messages; write to a file.

**`sysctl hw.optional.arm.FEAT_PAuth` says 0.**
Pointer authentication works all the same. Not investigated.

**The hosted kernel log says `do_cacheid() - 512 bytes Unknown cache`, `failed to find the interrupt-controller`,
`failed to find cpu-debug-interface`.**
Harmless. The first is XNU decoding this CPU's cache registers wrongly (the line size is right). The others are by
design: Linux owns the interrupt controller.

## 16. What does not work, and what was not tested

Does not work or is missing:

- **Graphics speed.** Everything is drawn on the CPU. The desktop is usable, not fast. Video and games were not tried.
- **Sound, camera, Bluetooth devices, USB.** None exist.
- **Apple account services** (sign-in, the App Store, iCloud). Not tried. macOS-DroidVM reports that sign-in fails on
  its hosts; expect the same and plan on direct downloads.
- **Security.** Code-signing enforcement and system integrity protection are relaxed by the boot arguments, and the
  system volume's seal is broken by upstream's disk script. Do not put anything you care about in it.
- **`softwareupdated`** still runs though disabled. Do not install system updates: the kernel collection is tied to
  one build.
- **A Spotlight indexing extension of the voice-memo app** crashes; `AppleKeyStoreUserClient failed MACF` messages from
  three daemons continue. Not investigated.
- **On a Linux-built disk (section 7):** no developer tools, no Recovery system, no Intel support; files written by
  Linux are uncompressed and lack BSD file flags. The list is in section 7.
- **The Linux build of the GPU bundle is new.** It was built once and used for about twenty minutes (section 7,
  "The GPU bundle"). The Mac-built bundle is the one with hours of use.
- **A chess game crashed twice** (`EXC_ARM_DA_ALIGN` in a texture upload) before the two fixes and not in three tries
  after. The cause was never established.

Not tested:

- **This exact branch, end to end.** The system described here was built from upstream at commit `06bc271` plus local
  patches. The two fixes are the same changes in upstream's form, the fixed renderer was rebuilt from that form, and
  the build-script fixes were applied by hand on the VM in an earlier shape. A fresh VM built from `cloud-arm` from
  the first step has not been done. The Linux disk build of section 7 was run from this branch's files, on the VM
  that already had the kernel side.
- **The Linux disk build beyond what is listed here.** Tested: one disk of 120 GiB, macOS 27.2 (26B123), on the VM of
  section 1. 14 boots, one of which failed without an explanation; the login window with `--autologin off`, logged
  in with the input tools; changing options on the existing disk five times (only the last two stages ran); a
  48-minute run and two shorter ones with Safari, Calculator, System Settings, Terminal and Finder windows opened and
  closed over ssh; ssh; the Screen Sharing handshake; `tests/hosted`; three different GPU bundles. Not tested: other
  sizes (an earlier form of the same steps built 48 GiB), `--tuning off`, `--ssh off`, another user name, other
  macOS builds, other hosts, days of uptime, filling the disk, saving and restoring it (section 17), and
  `--install-deps` actually installing something.
- **A clean bill from Apple's `fsck_apfs` for a used Linux-built disk.** Run in the guest (`fsck_apfs -n -l`), it
  reports System and Preboot as OK. For the Data volume of the test disk it ended with "could not be verified
  completely", three times: reference counts of some extents, the block count, the size statistics of three folders,
  and four cache files marked as compressed without their compression attribute. The four files were damaged by a
  step of an earlier version of the staging script when it was run again on the used disk; that step is gone. The
  folder statistics are a likely result of Linux writing into folders macOS keeps statistics for. The extent warnings
  are not explained: checked from the VM after a sync and a stop, the same volume had no extent without an owner
  three times and two small ones (14 blocks) twice. On the first Linux-built disk (staged once, booted twice) and on
  the Mac-built disk, Data checked OK. **Not tested: this check on a Linux-built disk that was staged only once and
  then used for a while.** Nothing was seen to go wrong in use.
- **The helper tools in their cleaned form.** Each tool's header says whether it was run or only syntax-checked. Run
  as published: `vm-ssh`, `vm-run`, `guest-ssh`, `guest-screenshot`, `boot-cycle.sh`, `vm/boot-image.sh` and the
  three files of the Linux disk build. The others were only syntax-checked; their private originals did the work.
- **Restoring a saved image on a new VM** (section 17).
- **More than 3 hosted CPUs**, other VM sizes, other clouds, other CPUs, a 16 KB-page host kernel.
- **Running as a service** (`scripts/install-service.sh`) on this host.
- **A session with Apple's Screen Sharing app**; a headless client (`tools/cloud/vnc-check.py`) got frames and clicked.
- **Long uptimes and load.** The longest runs were hours, not days. No stress run like upstream's was done here.
- **Which of the three parts of the renderer patch** is needed. The crash dump points at the first.

## 17. Saving your work

Once the hosted system is set up, save the image and the kernel side, so a deleted VM is not a lost afternoon.

1. Stop the hosted system (section 10).
2. **Laptop.**

   ```sh
   tools/cloud/vm-run tools/cloud/vm/save-image.sh /var/tmp/macimg save1
   tools/cloud/relay-vm-to-bucket.sh save1
   tools/cloud/relay-vm-to-bucket.sh save1k
   ```

   Expected: `READBACK-OK ...`, then for each relay `relay: OK ... all NN parts match the VM's MD5`. Here a 29 GB
   image packed in 226 s and uploaded in 148 s.
3. Boot again (section 10), and delete the staging folder `/var/tmp/up` on the VM when the upload is verified.

`save1k` holds the built kernel collection, the modules (built for the host kernel that was running), `kc27.bin`, the
settings file and the kernel command line. Both archives contain Apple's files: private storage only. Restoring them
on a fresh VM was not tested.

## Credits

This is a small addition to other people's work: [xnulinux](https://github.com/AFK-surf/xnulinux) (the whole
approach of hosting XNU inside Linux, and every script this guide drives),
[macOS-DroidVM](https://github.com/Droid-VM/macOS-DroidVM) (the 4 KB-page XNU base, the Linux toolchain, the timebase
scaling option), [UniXNU](https://github.com/UniXNU/UniXNU) (which fixed the pointer-authentication keys first, and whose
notes pointed at several of the tuning steps), and [metal2vulkan](https://github.com/steelbrain/metal2vulkan) with
[Mesa](https://mesa3d.org)'s lavapipe, which draw the desktop.

macOS is a trademark of Apple Inc. This work is not affiliated with or endorsed by Apple.
