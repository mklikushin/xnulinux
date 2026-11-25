# Runbook for an agent: xnulinux on a cloud ARM VM

This file is written for an AI coding agent that has been asked to set up xnulinux on a rented arm64 VM with no GPU.
It is the same procedure as [`cloud-arm.md`](cloud-arm.md), arranged for unattended work: phases with entry
conditions, exact commands, a check after each phase, and what to do when a known failure appears. Read
`cloud-arm.md` section 15 (troubleshooting) when a failure is not listed here.

**Prompt for the user to paste:**

```text
Set up macOS on a cloud ARM VM by following docs/cloud-arm-agent.md in this repository.
Before anything that costs money, needs a login or a password, or touches Apple's licence terms, stop and ask me.
Never print, log or commit a secret. Never delete my VM, disk image or bucket without my explicit yes.
Work through the phases in order, run the check after each one, and tell me when a phase is done or blocked.
If the same fix fails twice, stop and report what you saw. Finish with the verification checklist.
```

## 0. Ask the human first

Do not start a phase until the user has answered what that phase needs. Ask everything you can in one message.

1. **Apple's licence.** Tell the user, in plain words and without comment: "Apple's software licence restricts macOS
   to Apple-branded hardware. Running it on a cloud VM is outside those terms. The SDKs and the Kernel Debug Kit used
   to build the kernel have similar terms. Whether to go on is your decision." Go on only after a clear yes.
2. **Third-party mirrors in the kernel build.** Tell the user: "The upstream build script (phase B) downloads two
   Apple SDKs and a Kernel Debug Kit from third-party mirrors on GitHub, pinned and checksummed by macOS-DroidVM. The
   alternative is that you supply your own copies from Apple." Run phase B only after a yes to one of the two.
3. **The GPU bundle; no Mac is required.** The system disk is built on the VM (phase D), and so can the
   `XnuCpuMetal.bundle` that draws the desktop (phase D step 1: about an hour and a half of compiling, new and tested
   for minutes, not hours). A prebuilt bundle exists but is not published (a pending decision of this fork's
   maintainer): do not look for a download and do not take one from anywhere the user has not named. Ask: "Do you
   have an XnuCpuMetal.bundle already? If not, shall I build it on the VM (default), or do you prefer to build it on
   an Apple silicon Mac with Apple's developer tools (which Mac: ssh host, user, key)?" Without a bundle the system
   boots to a root shell only, with no desktop. Use the Mac route
   (phases D-mac and E-mac) only if the user asks for a disk installed by Apple's installer or with developer tools on
   it; then the Mac needs about 80 GB free and must not be a VM.
4. **Money.** Before each of these, say what it is and the expected cost, and wait:
   - the VM (4 vCPU, 32 GB arm64; price per hour from the provider's price list; the whole procedure needs several
     hours of it, plus as long as the user wants the system up);
   - a rented Mac, only if the user chose a Mac for the GPU bundle or the Mac route (price from the provider;
     check the provider's minimum term);
   - storage, only if the image is saved outside the VM (measured: about 2.30 US dollars a month per 100 GB; one
     image is about 30 GB);
   - network transfer out of a cloud region, only on the Mac route or when saving (estimated, not confirmed: 1.50 to
     2.50 US dollars for 29 GB between continents). The default route downloads 13.8 GB from Apple into the VM; inbound
     transfer is free at most providers, but check.
   You do not know the user's prices. Look them up or ask; do not guess a total.
5. **Credentials.** You need, through the user's own secret mechanism and never in chat: a login to the cloud
   provider (or a VM the user already made, with an ssh key), a password for the guest user, and an ssh public key
   for reaching the guest; on the Mac route also write access to a bucket if one is used and the Mac's login password
   if automatic login must be set. **The guest password lives in a file on the VM** (mode 600; phase D makes a random
   one unless the user wants their own). Ask the user to put passwords in files that only they can read and to tell
   you the paths. No Apple account is needed and none must be signed in to. Never display a secret, never put one on
   a command line, never write one into the repository or a log.
6. **Names and places.** Where the VM is (address, user, key), the bucket name if any, and where you may keep
   working files on the user's machine.

## Hard rules

- **No Apple files from third parties, and none passed on.** Do not download macOS, disk images, kernel collections,
  kernel caches or trust caches from anyone but Apple's own servers, and never upload any of them to a place others
  can read, a repository included. The single exception is item 2 above, and only with the user's yes.
- **Never delete** the user's VM, disk image, bucket or objects in it without an explicit yes for that exact thing.
  Stopping the hosted system is not deleting. Stopping the VM needs a yes too.
- **Never type a password while a screen recording is running.** If you cannot tell, ask.
- **Take a fresh screenshot before sending any input to a login window**, and look at it. The dump lags by seconds.
  If you do not see the password field, do not type.
- **Passwords go only through `tools/cloud/guest-login` or over standard input** (`... < "$GUEST_PASSWORD_FILE"`).
  Never through `guest-input type`, never as an argument.
- **Stop and report after the same fix fails twice** in the same way. Say what you ran and what you saw.
- **Do not commit** `tools/cloud/cloud.env`, keys, tokens, logs with addresses, or anything of Apple's.
- **Do not install macOS updates** in the hosted system.
- Say what is verified and what is not. A step that was skipped is reported as skipped.

## How to work

- Three machines: **L** (where you run; has this repository), **VM**, **Mac**. Guest means the hosted macOS.
- Tools: `tools/cloud/` on L. Every tool is non-interactive, has `--help`, and exits `0` done, `1` failed, `2` wrong
  usage or a missing setting (`vm-ssh`, `vm-run`, `guest-ssh` return the remote status; `255` = no connection).
  Which are safe to repeat: [`tools/cloud/README.md`](../tools/cloud/README.md).
- Settings: copy `tools/cloud/cloud.env.example` to `tools/cloud/cloud.env` (ignored by git) and fill it in.
- **Long commands** run in the background on the remote machine with `nohup`, writing a log; you poll the log or a
  marker. Never hold an ssh session open for an hour. Pattern:

  ```sh
  tools/cloud/vm-ssh 'cd ~/w/poc && nohup bash scripts/vm-xnu-build.sh > ~/build.log 2>&1 < /dev/null & echo started'
  tools/cloud/vm-ssh 'tail -3 ~/build.log; pgrep -f vm-xnu-build.sh >/dev/null && echo RUNNING || echo ENDED'
  ```

- **Resuming after an interruption:** run the *check* of each phase from A onward. The first check that fails is where
  to resume. Each phase below says what to inspect before repeating it.

| Long step | Rough duration | How to tell it is done |
|---|---|---|
| B: kernel build | tens of minutes (55 minutes of VM time including retries, the first time) | `ENDED` and the phase check passes |
| D: disk on the VM | about 5.5 minutes from nothing (132 s download, 183 s image) | `grep -c "disk ready in" ~/disk.log` prints 1, and the phase check passes |
| D: GPU bundle on the VM | about 1.5 hours on 4 CPUs (LLVM twice, 29 minutes each with 4 jobs; the rest about 30 minutes) | `grep -c "bundle ready" ~/gpu.log` prints 1 |
| D: GPU bundle on a Mac (`gpu`), instead | not measured for a first build (it builds LLVM); 8 minutes for a rebuild with the disk | `~/xnubuild/logs/gpu.log` ends in `gpu stage done` |
| D-mac: guest install (`vm`) | not measured: a 25 GB download plus Apple's installer | `~/xnubuild/logs/vm.log` ends in `vm stage done` |
| E-mac: pack, upload, pull | 40 s + 206 s + about 10 minutes for 23 to 28 GB | each tool's `OK` or `pulled in` line |
| F: boot to desktop | about 2 minutes | phase check |
| H: save | 226 s to pack 29 GB, 148 s to upload | `READBACK-OK`, then `relay: OK` |

## Phase A: the VM is ready

- **Entry:** user's yes to items 1, 4 (VM) and 5; a running arm64 Ubuntu VM you can ssh into. Creating the VM is the
  user's or yours only with their cloud login and their yes to the cost. Used: 4 vCPU, 32 GB, 100 GB disk,
  Ubuntu 26.04, kernel 7.0.
- **Idempotent:** yes.
- **Do (L):**

  ```sh
  tools/cloud/vm-ssh 'test -d ~/w/poc/.git || { mkdir -p ~/w && git clone -q --branch cloud-arm https://github.com/gshost1/xnulinux.git ~/w/poc; }'
  ```

- **Check (L):** exit status 0 and the output `GATES-OK`:

  ```sh
  tools/cloud/vm-ssh '[ "$(uname -m)" = aarch64 ] && [ "$(getconf PAGESIZE)" = 4096 ] && grep -q paca /proc/cpuinfo && grep -q "\[none\]" /sys/kernel/security/lockdown && test -f ~/w/poc/scripts/vm-xnu-build.sh && echo GATES-OK'
  ```

- **On failure:** no `paca`, or a page size other than 4096: this host cannot run it; stop and tell the user. Lockdown
  not `[none]`: Secure Boot is on; the user must turn it off for the VM. Exit 255: fix `VM_HOST`, `VM_USER`, `VM_KEY`.

## Phase B: kernel and collection built on the VM

- **Entry:** phase A passes; user's yes to item 2; 60 GB free on the VM (`df -h /`).
- **Idempotent:** yes. Rerunning continues from what exists. **Inspect first:** is a build already running
  (`pgrep -f vm-xnu-build.sh`)? Do the outputs in the check already exist?
- **Do, step 1 (L), long:** start `scripts/vm-xnu-build.sh` in the background as in "How to work". Poll every few
  minutes. **Expected on a fresh VM: the first pass hangs.** Detect it:

  ```sh
  tools/cloud/vm-ssh 'pgrep -c -x decomment; df -h / | tail -1; tail -2 ~/build.log'
  ```

  If `decomment` processes exist and the log has not moved for two polls, or the disk is above 85 %:

  ```sh
  tools/cloud/vm-ssh 'pkill -x decomment; pkill -f vm-xnu-build.sh; find ~/w/dvm/out -name "*.strip.*" -delete; find ~/w/dvm/out -name "*.unifdef.*" -delete; df -h / | tail -1'
  ```

  then start the same script again. This one restart is expected and does not count as a failed fix. A second hang
  does: stop and report.
- **Check 1:** `tools/cloud/vm-ssh 'test -s ~/w/dvm/out/k27/kernel-k27.macho && echo KERNEL-OK'`
- **Do, step 2 (L):** the kernel cache from Apple's server (commands in `cloud-arm.md` section 4 step 4; run them on
  the VM in one `vm-run` script).
- **Check 2:** `tools/cloud/vm-ssh 'test "$(stat -c %s ~/w/dvm/out/kc/kc27.bin)" -gt 50000000 && echo KC27-OK'`
- **Do, step 3 (L):**

  ```sh
  tools/cloud/vm-ssh 'cd ~/w/poc && AMFI_PLATFORM=27 bash scripts/vm-xnu-rebuild.sh > ~/rebuild.log 2>&1; echo rc=$?; tail -4 ~/rebuild.log'
  tools/cloud/vm-ssh 'cd ~/w/poc && make -s -C /lib/modules/$(uname -r)/build M=$PWD/fki-ko modules && make -s -C /lib/modules/$(uname -r)/build M=$PWD/xnu-ko KBUILD_EXTRA_SYMBOLS=$PWD/fki-ko/Module.symvers modules; echo rc=$?'
  ```

- **Check 3:** output `BUILD-OK`:

  ```sh
  tools/cloud/vm-ssh 'test -s /lib/firmware/xnu/kc.bin && test -s /lib/firmware/xnu/kernel.macho && test -s ~/w/poc/fki-ko/fki.ko && test -s ~/w/poc/xnu-ko/xnu.ko && ! grep -qi "left out" ~/rebuild.log && echo BUILD-OK'
  ```

- **Known failures:**

  | Seen in the log | Do |
  |---|---|
  | `ConnectionResetError` or another download error | Start the script again (downloads resume and are checksummed). Twice in a row: stop. |
  | `No space left on device` | Delete the `*.strip.*` and `*.unifdef.*` files as above, then start again. |
  | `git apply` fails in `vm-xnu-rebuild.sh` | The tree has other changes. Do not force it. Report. |
  | `kext NAME failed to build: left out` | Report: the collection would be incomplete. |
  | `kc.bin` missing after the rebuild | `kc27.bin` was not there: do step 2, then step 3 again. Never boot a kernel built without it. |

## Phase C: memory reserved, settings written

- **Entry:** phase B passes. **This phase reboots the VM**: tell the user first if anything else runs on it.
- **Idempotent:** yes (rewrites the same files). **Inspect first:** `cat /proc/cmdline` on the VM: if it already has
  `mem=` and the check passes, skip the reboot.
- **The numbers below are for a 32 GB VM whose RAM runs from `0x40000000` to `0x83fffffff`.** Check with
  `tools/cloud/vm-ssh 'sudo grep "System RAM" /proc/iomem'`. If the map differs, do not guess: read `cloud-arm.md`
  section 5 and ask the user to confirm the numbers you propose.
- **Do (L):**

  ```sh
  tools/cloud/vm-ssh 'cd ~/w/poc && LINUX_MEM=23G CARVE_BASE=0x600000000 CARVE_MB=8156 bash scripts/vm-install-fki-service.sh'
  tools/cloud/vm-ssh 'printf "%s\n" "CPUS=3" "RAM_MB=7900" "GPU=off" "BOOTARGS=\"amfi_get_out_of_my_way=1 lp-sip0=2050 droidvm-timebase-hz=24000000 bt-transport-override=10\"" | sudo tee /etc/xnulinux.conf >/dev/null; sync; sudo reboot' || true
  ```

  Wait until `tools/cloud/vm-ssh true` succeeds again (try every 20 s, up to 5 minutes). If the VM's address changed,
  update `VM_HOST` (or `tools/cloud/vm-ip --refresh`).
- **Check (L):** output `MEM-OK`:

  ```sh
  tools/cloud/vm-ssh 'grep -q "mem=23G nokaslr" /proc/cmdline && sudo dmesg | grep -q "fki: 8156 MiB at 0x600000000" && grep -q "^CPUS=3" /etc/xnulinux.conf && grep -q "bt-transport-override=10" /etc/xnulinux.conf && echo MEM-OK'
  ```

- **Known failures:** the VM does not come back: the user must look at its serial console; do not delete it.
  `fki:` line missing: `systemctl status xnulinux-fki.service` on the VM; a message that the carve-out "overlaps" or
  "is not all RAM" means the numbers do not fit this memory map. `cma=` is not a substitute.

## Phase D: disk built on the VM (default, no Mac)

- **Entry:** phases A and B pass (C may come before or after); user's yes to items 1 and 3; 60 GB free where the disk
  goes (`df -h /var/tmp`), 15 GB more for the bundle build; `sudo -n true` works on the VM.
- **Idempotent:** yes. Every stage is skipped when it is done and still checks out; a failed run continues where it
  stopped when the same command is run again. **Inspect first:** `tail -3 ~/disk.log` on the VM, and whether
  `/var/tmp/macimg/mac.img` exists. The `image` stage is the only one that starts over when interrupted.
- **Do, step 1 (only without a bundle on the VM; long):** build it on the VM. It needs the macOS SDK that phase B
  left in `~/w/dvm/toolchains/sdks/MacOSX26.1.sdk` (the user said yes to that source in item 2).

  ```sh
  tools/cloud/vm-ssh 'sudo -n apt-get install -y -q clang-21 lld-21 llvm-21 cmake ninja-build meson glslang-tools python3-mako >/dev/null && echo TOOLS-OK'
  tools/cloud/vm-ssh 'cd ~/w/poc && nohup bash tools/cloud/vm/build-gpu-bundle-linux.sh --out ~/gpu > ~/gpu.log 2>&1 < /dev/null & echo started'
  tools/cloud/vm-ssh 'tail -2 ~/gpu.log; pgrep -f build-gpu-bundle-linux.sh >/dev/null && echo RUNNING || echo ENDED'
  ```

  Its exit status: `0` done, `1` a stage failed (the message names the stage's log under `~/gpu-work/logs/`), `2` a
  missing input (no SDK: phase B was not done), `3` a missing tool (the message has the `apt-get` line). Run the same
  command again after a failure: finished stages are skipped. If the same stage fails twice, stop and report the end
  of its log; the alternative is the Mac build below.
- **Or, step 1 on a Mac instead (only if the user chose it):** copy `tools/cloud/mac/` to the Mac (below
  `~/cloudmac`), then

  ```sh
  REPO_URL=https://github.com/gshost1/xnulinux.git REPO_REF=cloud-arm bash ~/cloudmac/build-disk.sh deps
  nohup bash ~/cloudmac/build-disk.sh gpu > ~/gpu.out 2>&1 < /dev/null &
  ```

  Poll `tail -1 ~/xnubuild/logs/gpu.log` until it ends in `gpu stage done`; then, on the Mac, with a key the VM accepts:

  ```sh
  tar -C ~/xnubuild/xnulinux/gpu/xnu-cpu-metal/dist -czf - XnuCpuMetal.bundle | ssh VM_USER@VM_ADDRESS 'mkdir -p ~/gpu && tar -C ~/gpu -xzf -'
  ```

- **Check 1 (L):** `tools/cloud/vm-ssh 'test -s ~/gpu/XnuCpuMetal.bundle/Contents/Frameworks/libvulkan_lvp.dylib && test -s ~/gpu/XnuCpuMetal.bundle/Contents/MacOS/XnuCpuMetal && echo BUNDLE-OK'`
- **Do, step 2 (L):** the password file and the key. Do not replace a password file that exists.

  ```sh
  tools/cloud/vm-ssh 'test -s ~/guest-pass || (umask 077; head -c 32 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16 > ~/guest-pass; echo >> ~/guest-pass); stat -c %a ~/guest-pass'   # 600
  tools/cloud/vm-ssh 'cat > ~/guest.pub' < "$GUEST_KEY.pub"
  ```

  Never print `~/guest-pass`. Tell the user where it is. If they want to keep a copy on L for `guest-login`, they copy
  it themselves, or you copy it with `scp` to a mode-600 file without displaying it, and set `GUEST_PASSWORD_FILE`.
- **Do, step 3 (L), long:**

  ```sh
  tools/cloud/vm-ssh 'cd ~/w/poc && nohup bash tools/cloud/vm/build-disk-linux.sh --out /var/tmp/macimg --gpu-bundle ~/gpu/XnuCpuMetal.bundle --password-file ~/guest-pass --ssh-key ~/guest.pub --install-deps > ~/disk.log 2>&1 < /dev/null & echo started'
  tools/cloud/vm-ssh 'tail -2 ~/disk.log; pgrep -f build-disk-linux.sh >/dev/null && echo RUNNING || echo ENDED'
  ```

  Exit status of the script (last line of the log names the stage): `0` done, `1` a stage failed, `2` a missing or
  unreadable input, `3` the host cannot do it (no passwordless sudo, not arm64, too little space).
- **Check 2 (L):** output `DISK-OK`:

  ```sh
  tools/cloud/vm-ssh 'cd /var/tmp/macimg && test -s mac.img && grep -q "^ROOT_UUID=" mac.conf && grep -q "^BOOT_UUID=" mac.conf && test -s trustcache.bin && python3 ~/w/poc/tools/cloud/vm/apfs-alloc-count.py --offset $((501 << 20)) mac.img >/dev/null && sgdisk -p mac.img | grep -q iBootSystemContainer && echo DISK-OK'
  ```

- **Known failures:**

  | Seen in `~/disk.log` | Do |
  |---|---|
  | `try N failed: ... Connection reset` | Nothing: it retries. `could not fetch ... in 12 tries`: run the same command again later. Twice: stop. |
  | `sudo asks for a password` (status 3) | The user must give the VM user passwordless sudo. Do not work around it. |
  | `is not an XnuCpuMetal.bundle` (status 2) | `--gpu-bundle` must point at the `.bundle` folder itself: step 1. |
  | `can be read by other users: chmod 600 it` | `chmod 600` the password file. |
  | `has NN GB free` (status 3) | Ask the user: free space, or name another `--out` and `--work`. |
  | `apfs.ko did not build` | Kernel headers missing or a newer kernel than the driver supports: report the log; do not change the pinned revisions on your own. |
  | `mac.img was built with 'size=...'` (status 2) | The options changed. Ask the user before `--force image`: it deletes the existing image. |
  | `stage image failed` | Run the same command once more (the stage starts over). Twice the same: stop and report the end of the log file that the error message names. |

- **To change an option later** (automatic login, ssh, tuning): stop the hosted system (phase F, "Stop"), run the
  step 3 command with the new option; only `stage` and `finish` run again.

## Phase D-mac (alternative): disk built on a Mac

- **When:** only if the user chose the Mac route in item 3. Otherwise skip to phase F.
- **Entry:** user's yes to items 1, 3, 4 (Mac) and 5; ssh to the Mac; `tools/cloud/mac/` copied to the Mac (below,
  in `~/cloudmac`). The user has put the guest password in a file on the Mac (here `~/guest-pass`, mode 600) and a
  public ssh key in `~/guest.pub`. The user has said where the macOS 27.2 (26B123) restore image is: a file on the
  Mac, or Apple's own download address. Do not take a restore image from anywhere else.
- **Idempotent:** yes; each stage skips what exists. **Inspect first:** `tail -1 ~/xnubuild/logs/*.log` on the Mac.
- **Do (Mac, over ssh), in order:**

  ```sh
  bash ~/cloudmac/build-disk.sh preflight
  ```

  Read the output. Stop if the CPU is not Apple silicon, `hv_vmm_present=1`, or less than 80 GB is free.
  If `sudo without password: no`: this needs the user (their password, once): ask them to run
  `bash ~/cloudmac/build-disk.sh sudoers` themselves.
  If there is no desktop session (`launchctl print gui/$(id -u)` fails): automatic login is needed. The user runs
  `sudo python3 ~/cloudmac/autologin.py "$USER" < their-password-file` and reboots the Mac, or tells you the file's
  path and says yes to both.

  ```sh
  REPO_URL=https://github.com/gshost1/xnulinux.git REPO_REF=cloud-arm bash ~/cloudmac/build-disk.sh deps
  IPSW=<the restore image> nohup bash ~/cloudmac/build-disk.sh vm  > ~/vm.out  2>&1 < /dev/null &
  nohup bash ~/cloudmac/build-disk.sh gpu > ~/gpu.out 2>&1 < /dev/null &
  ```

  Poll `tail -1 ~/xnubuild/logs/vm.log ~/xnubuild/logs/gpu.log` until both end in `stage done`. Then:

  ```sh
  EXTRAS=1 GUEST_PASSWORD_FILE=~/guest-pass GUEST_PUBKEY_FILE=~/guest.pub bash ~/cloudmac/build-disk.sh disk
  ```

- **Check (Mac):** output `DISK-OK`:

  ```sh
  cd ~/xnubuild/macvm && test -s mac.img && grep -q '^ROOT_UUID=' mac.conf && grep -q '^BOOT_UUID=' mac.conf && test -s trustcache.bin && echo DISK-OK
  ```

- **Known failures:**

  | Seen | Do |
  |---|---|
  | `The virtual machine failed to start` | No desktop session: automatic login and reboot, as above. |
  | tart does not install | `deps` handles the moved Homebrew tap; run `deps` again and read `logs/deps.log`. |
  | Mesa stops on a Python error | `gpu` rebuilds its virtual environment from Homebrew's Python; run `gpu` again. |
  | `has N undefined SPIRV-Tools symbols` | `brew unlink spirv-tools`, delete `build/mesa-lvp*` under `gpu/xnu-cpu-metal`, run `gpu` again. |
  | `gpu` fails otherwise | Do not use `GPU_STUB=1` unless the user accepts a system with no desktop. Report the log's last 30 lines. |
  | `mk-macvm-disk.sh changed` | Upstream's disk script no longer matches what `build-disk.sh` edits. Stop and report. |

## Phase E-mac (alternative): move the Mac-built disk to the VM

- **Entry:** phase D-mac passes; phases A to C pass; 60 GB free on the VM; user's yes to the transfer cost and, for a
  bucket, write access set up.
- **Idempotent:** yes. The relay resends only wrong parts; the pull overwrites.
- **Do, with a bucket (settings `BUCKET`, `MAC_HOST`, `MAC_USER`, `MAC_KEY`):**

  ```sh
  # Mac
  bash ~/cloudmac/pack-image.sh ~/xnubuild/macvm img1
  # L
  tools/cloud/relay-mac-to-bucket.sh img1
  gcloud auth print-access-token | tools/cloud/vm-run tools/cloud/vm/pull-image.sh "$BUCKET" img1 /var/tmp/macimg
  ```

  **Or without a bucket** (Mac, slow over long distances): `bash ~/cloudmac/build-disk.sh upload VM_USER@VM_ADDRESS /var/tmp/macimg`
- **Check (L):** output `IMAGE-OK`:

  ```sh
  tools/cloud/vm-ssh 'cd /var/tmp/macimg && test -s mac.img && grep -q "^ROOT_UUID=" mac.conf && test -s trustcache.bin && echo IMAGE-OK'
  ```

- **Known failures:** `relay: FAILED: the bucket has parts the Mac does not`: stale objects from an earlier push; list
  them for the user and ask before removing anything. `Data corruption detected` on the VM: a wrong part was
  composed; run the relay again, then the pull. `no upload session`: no write access to the bucket; ask the user.
- The bucket now holds macOS. Confirm with the user that it is private.

## Phase F: boot

- **Entry:** phase C passes, and phase D (or D-mac and E-mac); no hosted system running (`lsmod | grep -c '^xnu '` is 0 on the VM).
- **Idempotent:** no. Booting twice is refused; stop first. **Inspect first:** is `xnu` loaded? If yes, go to the check.
- **Do (L):**

  ```sh
  tools/cloud/vm-run tools/cloud/vm/boot-image.sh /var/tmp/macimg 100
  ```

- **Check (L):** set `GUEST_KEY` and `GUEST_PASSWORD_FILE` in `cloud.env`. Try for up to 4 minutes; output `DESKTOP-OK`:

  ```sh
  tools/cloud/guest-ssh 'pgrep -x Dock >/dev/null && pgrep -x WindowServer >/dev/null && echo DESKTOP-OK'
  tools/cloud/guest-screenshot boot.png
  ```

- **Known failures:**

  | Seen | Do |
  |---|---|
  | `boot-image: xnu.ko is not loaded` | Read `/var/tmp/xnu-boot-dmesg.txt` on the VM for `XNU panic` or `took a fault`. Report the lines. |
  | `no contiguous memory for XNU` or `fki has no carve-out` | Phase C did not take: run its check. |
  | Console stops at `Waiting on ... IOMedia` | `mac.conf` does not belong to this `mac.img`. Run phase D's script again (it rewrites `mac.conf`), or redo E-mac. |
  | `XNU panic`, with `mount-phase-1` and `xART volume mount failed` in the log | The disk has no iBoot System Container partition: it was not made by `build-disk-linux.sh`. Rebuild it with phase D. |
  | Console reaches `xnulinux#` but no desktop; log has `_spvBinaryToText` | A Mac-built GPU bundle is broken: rebuild it (phase D-mac, SPIRV-Tools row), then run phase D step 3 again (a changed bundle makes `stage` run again by itself). |
  | Console reaches `xnulinux#` but no desktop after 3 minutes, with a bundle built on the VM | Read the hosted log for `XnuCpuMetal` and `dlopen` lines and report them. Do not rebuild blindly: this build path is new. |
  | The screenshot is black two minutes after the first boot of a new disk | Expected: the first boot is busy for about five minutes. Wait and take another; do not send input. |
  | ssh refused but the screenshot shows a desktop | The disk was made without `--ssh-key` (or without `EXTRAS=1` on the Mac route). Use `guest-console`, or run phase D step 3 again with the key. |
  | Screenshot shows a login window | The window server restarted. Follow the hard rules: fresh screenshot, see the field, then `guest-login`. |

- **Stop (when needed):** `tools/cloud/guest-ssh 'sync; sync'` then
  `tools/cloud/vm-ssh 'cd ~/w/poc && bash scripts/xnulinux-boot.sh stop'` (expect `hosted system stopped`).

## Phase G: tuning (optional)

- **Skip it for a disk from phase D:** the tuning is already on the disk (unless `--tuning off` was used); run only
  the check. The rest is for a Mac-built disk.
- **Entry:** phase F passes. Ask the user whether they want it: it disables system services inside the guest.
- **Idempotent:** yes.
- **Do:** the commands in `cloud-arm.md` section 12, as root with
  `tools/cloud/guest-ssh 'sudo -S -p "" sh -c "..."' < "$GUEST_PASSWORD_FILE"`. Do **not** disable
  `com.apple.siriactionsd`. Then stop and boot again (phase F).
- **Check (L):** `tools/cloud/guest-ssh 'launchctl print-disabled system | grep -c disabled'` prints 14 or more, and
  the phase F check still passes.

## Phase H: save (optional, costs storage)

- **Entry:** user's yes to the storage cost; hosted system stopped; free space on the VM about equal to the image's
  used size.
- **Idempotent:** yes (replaces its earlier output).
- **Do and check:** `cloud-arm.md` section 17. Success is `READBACK-OK` and two `relay: OK` lines. Boot again
  afterwards (phase F). Ask before deleting the staging folder on the VM.

## Final verification checklist

Run all of it and report each line to the user as pass, fail or not run, with the output.

```sh
tools/cloud/vm-ssh 'lsmod | grep -c "^xnu "'                                                       # 1
tools/cloud/guest-ssh 'sw_vers -productVersion; pgrep -x Dock >/dev/null && echo desktop-up'       # 27.2 / desktop-up
tools/cloud/guest-ssh 'launchctl print system/com.apple.bluetoothd | grep -E "runs|last exit"'     # runs = 1 / (never exited)
tools/cloud/guest-screenshot final.png && file final.png                                            # PNG image data, 1280 x 800
tools/cloud/boot-cycle.sh 0 final                                                                   # dock=up ... crash-reports: ...
tar -C tests -cf - hosted | tools/cloud/guest-ssh 'rm -rf ~/xt && mkdir ~/xt && tar -C ~/xt -xf - && sh ~/xt/hosted/run.sh'   # hosted tests: pass
```

1. Hosted kernel loaded: first line prints `1`.
2. Desktop up and ssh works: second command prints the version and `desktop-up`.
3. `bluetoothd` stable: `runs = 1`.
4. Screenshot taken: look at `final.png` and describe what is on it. Show it to the user.
5. `keys` and `exc` (two of the three test programs): `hosted tests: pass`. This needs `clang` in the guest, and a disk
   from phase D has none. Then report "not run: no compiler in the guest" (or, if the user has the four programs built
   elsewhere, copy them in and run `sh ~/xt/hosted/run.sh FOLDER`); do not install a compiler without asking.
6. `lvp_push_immutable` (the third): on the Mac, against the lavapipe the bundle was built from, following
   [`tests/lavapipe/README.md`](../tests/lavapipe/README.md). Expected `RESULT: PASS`, exit status 0. If no Mac was
   used or it is gone, report "not run".
7. Crash reports since boot: list what `boot-cycle.sh 0` printed. A few at login are known
   (`cloud-arm.md` section 15); `iconservicesagent` or `WindowServer` in the list means the renderer fix is not in
   the bundle.

Then tell the user: what is running and what it costs per hour while it stays up, where the image and any saved copy
are, which secrets files exist and where, and everything on this list that failed or was not run.
