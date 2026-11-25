# xnulinux on an NVIDIA DGX Spark (GB10), without a Mac

The scripts as they ran, except that the vmapple stack's locations now come from the environment (not rerun since):
work paths (`~/xnuvm`, `~/xnuhost`) and volume UUIDs are that machine's. Details: `NOTES.md`.

- `guest/`: an arm64 Ubuntu guest under KVM (QEMU from a container); `hcmd.sh` runs commands on the hosted console.
- `disk/`: the system disk, in place of `scripts/mk-macvm-disk.sh`, in this order:
  `mac-restore.sh`, `trustcache-from-ipsw.py`, `hboot.sh` + `1-cryptex.cmds`, `tboot.sh` + `2-tar-data.cmds`,
  `overlay.py`, `hboot.sh` + `3-new-data.cmds`, `apsb.py IMAGE NEW_UUID --apply`.
  A vmapple restore encrypts the Data volume with that VM's keys, so a new unencrypted one is made.
- `qemu/`: `QEMU_VMAPPLE_LP_SIP0=<flags>` turns SIP off in a vmapple guest (a patch on the vmapple QEMU in use).

Bare metal: Secure Boot off; `kvm-arm.mode=nvhe mem=112G nokaslr`;
`insmod fki.ko carve_base=0x1E00000000 carve_mb=8156 cpu_list=5,6,7,8,9`; NetworkManager off `xnu0`;
`/etc/xnulinux.conf`: `GPU=off CPUS=4`.

- `gpu/`: `build-virglrenderer.sh` installs virglrenderer 1.2.0 with Venus, which `gpu/xnu-drm/xnudrmd` then serves the
  hosted system's Vulkan from (NVIDIA's render node is not virtio-gpu). Written and tested off the machine only
  (`make -C gpu/xnu-drm test-virgl`); not yet run on NVIDIA's driver.

With `GPU=auto` and the Venus driver in `/Library/GPUBundles/XnuCpuMetal.bundle` Metal and WindowServer run on the GB10
(`Virtio-GPU Venus (NVIDIA GB10)`), the Dock with its icons. The counter here runs at 1 GHz: xnu.ko has XNU scale it to
Apple's 24 MHz (user space assumes it).

Open: without a GPU `iconservicesagent` crashes in lavapipe; stopping a run takes minutes; one boot in three takes the
leftover encrypted Data volume for the root device.
