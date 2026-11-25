# tools/cloud: helpers for a hosted macOS on a remote ARM VM

Small scripts for working with xnulinux when the Linux host is a rented cloud VM and you sit at another machine. They
are the cleaned-up forms of the scripts used for [`docs/cloud-arm.md`](../../docs/cloud-arm.md); an agent runbook that
uses them is in [`docs/cloud-arm-agent.md`](../../docs/cloud-arm-agent.md). License: GPL-2.0-only, like `scripts/`.

Three machines appear below: **yours** (a laptop, any Linux or macOS with ssh), the **VM** (the arm64 Linux host, which
also builds the system disk and can build the GPU bundle) and the **Mac** (Apple silicon; optional: the alternative
way to build the GPU bundle and the disk).

## Settings

```sh
cp tools/cloud/cloud.env.example tools/cloud/cloud.env    # git ignores cloud.env
$EDITOR tools/cloud/cloud.env
```

Every tool reads `cloud.env` beside it, or the file named by `XNU_CLOUD_ENV`. Values in the environment win. There are
no addresses, user names or bucket names in the scripts themselves. Secrets are never settings: ssh keys and the guest
password stay in files you name (`VM_KEY`, `GUEST_KEY`, `GUEST_PASSWORD_FILE`), and the password file is only ever fed
to a program's standard input.

## Conventions

- Nothing asks questions. ssh runs with `BatchMode=yes`; a missing setting is an error, not a prompt.
- Exit status: `0` done, `1` the operation failed, `2` wrong usage or a missing setting. `vm-ssh`, `vm-run` and
  `guest-ssh` return the remote command's status (`255`: ssh could not connect).
- Errors go to stderr and say what to fix. `--help` on any tool prints its header.
- Each header ends with a `Status:` line saying whether the cleaned version was run or only syntax-checked
  (`bash -n`; `shellcheck` was not available where they were cleaned).

## On your machine

| Tool | What it does | Repeat? | Example |
|---|---|---|---|
| `vm-ip` | Prints the VM's address (`VM_HOST`, or a cached `gcloud` lookup). | yes | `tools/cloud/vm-ip --refresh` |
| `vm-ssh` | Runs a command on the VM. | yes | `tools/cloud/vm-ssh 'uname -r'` |
| `vm-run` | Copies a local script to the VM and runs it. | depends on the script | `tools/cloud/vm-run tools/cloud/vm/boot-image.sh /var/tmp/macimg 100` |
| `guest-ssh` | ssh into the hosted macOS through the VM. | yes | `tools/cloud/guest-ssh 'sw_vers'` |
| `guest-screenshot` | Saves the hosted screen as a PNG. | yes | `tools/cloud/guest-screenshot shot.png` |
| `guest-input` | Sends clicks, typing and key chords. | acts each time | `tools/cloud/guest-input key cmd space` |
| `guest-login` | Types the guest password from `GUEST_PASSWORD_FILE` and Return. | **no**: look at a fresh screenshot first | `tools/cloud/guest-login` |
| `guest-console` | Runs one line in the hosted root shell on the console. Clears the VM's kernel log. | acts each time | `tools/cloud/guest-console 'sw_vers' 8` |
| `boot-cycle.sh` | Reboots the hosted system N times and records crash reports per boot. `0` = only check, changes nothing. | N=0 yes; otherwise it restarts the guest | `tools/cloud/boot-cycle.sh 3 after-fix` |
| `install-renderer-lib.sh` | Swaps a rebuilt `libvulkan_lvp.dylib` into the running guest (keeps `.orig`). | yes, with the same file | `tools/cloud/install-renderer-lib.sh lvp.gz` |
| `relay-mac-to-bucket.sh` | Mac's packed parts to a bucket, every part's MD5 checked, then composed. | yes: resends only wrong parts | `tools/cloud/relay-mac-to-bucket.sh img1` |
| `relay-vm-to-bucket.sh` | VM's packed parts to a bucket, every part's MD5 checked. | yes: resends only wrong parts | `tools/cloud/relay-vm-to-bucket.sh img1` |

## On the VM (`vm/`, run through `vm-run` or copied there)

`build-disk-linux.sh`, `build-gpu-bundle-linux.sh` and their helpers run from this repository's checkout on the VM,
not through `vm-run`.

| Tool | What it does | Repeat? | Example |
|---|---|---|---|
| `vm/build-disk-linux.sh` | Builds the system disk on the VM, without a Mac: fetches macOS from Apple's update server, makes `mac.img`, `mac.conf`, `trustcache.bin`. Options for size, user, password file, ssh key, automatic login, tuning. Needs a built GPU bundle. | yes: finished stages are skipped, a stopped run resumes | `bash tools/cloud/vm/build-disk-linux.sh --out /var/tmp/macimg --gpu-bundle ~/gpu/XnuCpuMetal.bundle --password-file ~/guest-pass --ssh-key ~/guest.pub` |
| `vm/disk_linux.py` | Helper of the above: the disk layout and the Data volume. Loads macOS-DroidVM's APFS scripts at run time. | not run by hand | |
| `vm/build-disk-linux.lock` | The pinned revisions of what the build fetches (macOS-DroidVM, linux-apfs-rw, apfsprogs, ipsw) and the macOS build. | a text file | |
| `vm/build-gpu-bundle-linux.sh` | Cross-builds `XnuCpuMetal.bundle` (arm64 + arm64e) on the VM, without a Mac: Apple's ld64 for Linux, the Vulkan loader, the Rust bridge, LLVM, lavapipe, the plugin. Needs a macOS SDK on the VM. About 1.5 hours on 4 CPUs. | yes: finished stages are skipped | `bash tools/cloud/vm/build-gpu-bundle-linux.sh --out ~/gpu` |
| `vm/macho-adhoc-resign.py` | Helper of the above: refreshes the page hashes of an ad-hoc code signature after a file was edited. | yes | `python3 tools/cloud/vm/macho-adhoc-resign.py libxnu_m2v.dylib` |
| `vm/apfs-alloc-count.py` | Checks the block counters of every volume in an unmounted APFS image; `--fix` corrects what the Linux APFS driver leaves wrong (the cause of macOS's `fs_alloc_count mismatch` log lines). | yes | `python3 tools/cloud/vm/apfs-alloc-count.py --offset $((501 << 20)) /var/tmp/macimg/mac.img` |
| `vm/boot-image.sh` | Installs an image folder's trust cache and `mac.conf`, boots it, prints the console's end. | no: refuses while a hosted system runs | `tools/cloud/vm-run tools/cloud/vm/boot-image.sh /var/tmp/macimg 100` |
| `vm/pull-image.sh` | Fetches `NAME.tar.zst` from a bucket (token on stdin) and unpacks it. | yes: overwrites | `gcloud auth print-access-token \| tools/cloud/vm-run tools/cloud/vm/pull-image.sh BUCKET img1` |
| `vm/save-image.sh` | Packs the stopped image and the kernel side into checked 1 GiB parts. | yes: replaces its earlier output | `tools/cloud/vm-run tools/cloud/vm/save-image.sh /var/tmp/macimg img1` |

## On the Mac (`mac/`, copy the folder there)

Nothing here is needed when the disk and the GPU bundle are built on the VM. `build-disk.sh deps` and `gpu` build the
GPU bundle on a Mac instead; the rest is the alternative disk build.

| Tool | What it does | Repeat? | Example |
|---|---|---|---|
| `mac/build-disk.sh` | Stages `preflight`, `sudoers`, `deps`, `vm`, `gpu`, `disk`, `upload`, `all`: the whole disk build. | yes: every stage skips what exists | `IPSW=~/Downloads/restore.ipsw bash build-disk.sh all` |
| `mac/disk-extras.sh` | Sourced by `build-disk.sh disk` with `EXTRAS=1`: Remote Login, Screen Sharing, your ssh key. | not run by hand | `EXTRAS=1 GUEST_PASSWORD_FILE=~/guest-pass GUEST_PUBKEY_FILE=~/guest.pub bash build-disk.sh disk` |
| `mac/autologin.py` | Automatic login for a user, so a headless Mac has the desktop session guests need. | yes | `sudo python3 autologin.py "$USER" < ~/mac-pass` |
| `mac/pack-image.sh` | Image folder to zstd tar parts of 1 GiB. | yes: replaces its earlier output | `bash pack-image.sh ~/xnubuild/macvm img1` |
| `mac/pack-backup.sh` | Any paths to parts, with a SHA-256 list and a read-back. | yes: replaces its earlier output | `bash pack-backup.sh guests .tart/vms` |
| `mac/push-parts.sh` | PUTs parts to upload URLs. Called by `relay-mac-to-bucket.sh`. | yes | `bash push-parts.sh ~/xnubuild/up/img1` |

## Optional

`optional/keystore-persist.patch`: keeps the hosted keystore file across boots, beside the disk image. Not applied on
this branch; upstream recreates the file at each boot on purpose, and the patch fixed no visible problem. Its header
says the rest.

## What these tools assume

- The bucket tools speak Google Cloud Storage (`gcloud storage`, resumable upload URLs). Another object store needs the
  three `gcloud`/`curl` places changed; `build-disk.sh upload` and plain `scp` need no bucket at all.
- `vm/build-disk-linux.sh` downloads macOS-DroidVM to the VM and runs it. That repository states no licence, so
  nothing of it is in this one; see the guide, "What the Linux build fetches".
- The image parts, the kernel-side archive and the backups **contain Apple's files**. Keep them in storage only you can
  read. Nothing in this repository contains them.
- `guest-input` arguments are visible in process lists. Passwords go through `guest-login` only.
