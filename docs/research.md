---
title: pi-core — technology research brief
date: 2026-08-24
status: research complete, no decisions made
---

# pi-core: custom Raspberry Pi image on uCore/Fedora

Goal: a custom, immutable, image-based Raspberry Pi OS derived from
Universal Blue **uCore** (Fedora CoreOS + batteries).

## 1. The stack, layer by layer

| Layer | What it is | Relevance |
|---|---|---|
| **OCI image** | The OS ships as a container image (`ghcr.io/ublue-os/ucore:stable`) | The "image" we customize is a Containerfile, not a disk builder |
| **bootc** | Boots + updates a machine *from* an OCI image; `bootc switch/upgrade`, A/B deployments | The update mechanism |
| **ostree** | Underlying immutable-filesystem/deployment engine bootc drives | `/usr` read-only, `/etc` 3-way merged, `/var` persistent |
| **Fedora CoreOS (FCOS)** | Minimal auto-updating server OS; Ignition first-boot provisioning | uCore's base; stable stream is now **44.20260802.3.1** (Fedora 44, kernel 6.19.x) |
| **uCore** | ublue's FCOS + server packages, 3 variants, cosign-signed, daily builds | Our base image |
| **image-builder (osbuild)** | Turns a bootc image into a disk image | **bootc-image-builder was archived 2026-06-18** and merged into `osbuild/image-builder`; use `image-builder` / the `--bootc-ref` flow |
| **Pi boot firmware** | Closed BCM firmware in EEPROM (Pi4/5) reading `config.txt` from the *first FAT partition* | The whole hard part; it is not UEFI |

### uCore variants (all now multi-arch: **amd64 + arm64**, since 2025-11)
- `ucore-minimal` — bootc, cockpit, firewalld, docker+podman, tailscale, wireguard, tmux, ZFS
- `ucore` — + storage tooling (cockpit-storaged, distrobox, mergerfs*, nfs, rclone, samba, snapraid, PCP)
- `ucore-hci` — + libvirt/KVM + cockpit-machines
- tags: `stable`, `lts` (6.18 longterm kernel), `testing`; nvidia variants (x86 only in practice)
- *mergerfs is not yet available on aarch64*

Verified 2026-08-24 by querying ghcr manifests: every variant (`stable`, `lts`)
publishes both `linux/arm64` and `linux/amd64`. ublue's own caveat: aarch64
images have only been lightly tested, in VMs.

**Verified by building it** (2026-08-24, `ucore-minimal:stable` arm64):
`PRETTY_NAME="Fedora CoreOS 44.20260802.3.1 (uCore minimal)"`. Note the kernel
is **7.1.6-201.fc44.aarch64** — ublue's own build, *newer* than Fedora 44's
stock 6.19.10-300. The Pi DTBs are present in it regardless:
`bcm2711-rpi-4-b.dtb`, `bcm2712-rpi-5-b.dtb` and `bcm2837-rpi-3-b-plus.dtb` all
ship in `/usr/lib/modules/7.1.6-201.fc44.aarch64/dtb/broadcom/`. So the Pi 3/4/5
DTB coverage claimed below holds for the image we actually consume, not just for
stock Fedora.

**Important build detail:** uCore *replaces the kernel* with ublue's own signed
kernel build (`install-ucore-minimal.sh` installs from an akmods kernel-rpms
mount, for Secure Boot + ZFS akmods). It is Fedora's kernel, rebuilt — so any
Pi enablement that is in Fedora's kernel is in uCore's; anything out-of-tree is not.

## 2. Raspberry Pi hardware support in Fedora (the deciding factor)

**Pi 4 / CM4 / Pi 400:** well supported, and Fedora CoreOS has an *official
documented install procedure* for the Pi 4 (`docs.fedoraproject.org/sw/fedora-coreos/provisioning-raspberry-pi4/`).

**Pi 5:** getting there, not done.
- Verified directly against the F44 repo (2026-08-24): stock
  `kernel-core-6.19.10-300.fc44.aarch64` ships `bcm2712-rpi-5-b.dtb` **and**
  `bcm2712-d-rpi-5-b.dtb` (c0 *and* d0 revs), and `kernel-modules-core` ships
  `drivers/misc/rp1/rp1_pci.ko` (RP1 southbridge = USB + ethernet). So the
  mainline baseline is in the stock Fedora kernel that FCOS/uCore consume.
- But Fedora's *official* F44 Pi5 images (nullr0ute, 2026-03) shipped
  `6.19.9-300.**pr1**.fc44` — a patched build, i.e. some enablement is still
  out-of-tree. Peter Robinson is explicitly upstream-only; no COPR hacks.
- Known-broken on Pi5 as of 2026-03: **NVMe (and NVMe/USB boot)**, thermal/fan
  control, audio. HDMI + accelerated graphics work but need
  `cma=256M@0M-1024M` on the kernel cmdline. Pi500 and CM5 not working.
- Fedora 44 ships `bcm2711-firmware`, `bcm2712-firmware`, `bcm283x-firmware`,
  `bcm283x-overlays`, `uboot-images-armv8` (2026.04), `arm-image-installer` 5.4.

**Pi 3 / Zero 2 W:** better than first assumed. Verified 2026-08-24: the stock
F44 aarch64 kernel ships `bcm2837-rpi-3-b.dtb`, `bcm2837-rpi-3-b-plus.dtb`,
`bcm2837-rpi-3-a-plus.dtb`, `bcm2837-rpi-2-b.dtb`, `bcm2837-rpi-cm3-io3.dtb`
and `bcm2837-rpi-zero-2-w.dtb`. So the DTBs are there and the AlmaLinux
downstream-kernel route is not mandatory. The real constraint is **RAM**: 1 GB
(Pi 3B+) / 512 MB (Zero 2 W) against an FCOS+container workload. Treat as
viable for a boot/update proving ground, unproven as a service host.

## 3. The three ways to boot a bootc/ostree OS on a Pi

1. **U-Boot as the "kernel"** — firmware loads `u-boot.bin` from the FAT
   partition; U-Boot provides an EFI implementation; GRUB/BLS then boots the
   ostree deployment. This is what the official FCOS-on-Pi4 doc and
   `ondrejbudai/fedora-bootc-raspi` do. Simplest conceptually.
2. **EDK2 UEFI chainloader** — `pftf/RPi4` (v1.42, actively maintained) or
   `worproject/rpi5-uefi` (community, updated mid-2026). Makes the Pi look like
   a SystemReady server, so unmodified FCOS aarch64 "just works". Costs: default
   3 GB RAM cap on Pi4 (togglable), ACPI-by-default hides GPIO (switch to
   DeviceTree mode), and it lags new hardware badly.
3. **Direct kernel boot, no chainloader** — Pi firmware reads `config.txt` and
   loads kernel+initrd+dtb straight from the FAT partition; a helper syncs the
   ostree deployment's kernel/initrd/dtb into that partition on each staged
   update. This is `kfox1111/rpi-bootc-bootloader` (v0.0.8), used by AlmaLinux.
   Best hardware support and it uses the Pi's **`tryboot`** feature for real A/B
   rollback (plus an optional GPIO-6 button to force the previous image).
   Most moving parts; least "standard Fedora".

## 4. The known-unsolved problem: firmware updates

`bootupd` (what bootc uses to update the bootloader) manages only
`/boot/efi/EFI`. The Pi needs `start*.elf`, `fixup*.dat`, `*.dtb`, `config.txt`,
`u-boot.bin` at the **root** of the ESP. Consequences:

- `coreos/bootupd#651` → closed as dup of `#766`; PR **#935**
  (`extend-payload-to-esp`) is **still open, needs-rebase as of 2026-03**.
- Everyone therefore hacks around it: ondrejbudai stashes the files in
  `/usr/lib/bootc-raspi-firmwares` and wraps `bootupctl` with a shim;
  AlmaLinux hooks `ostree-finalize-staged.service` with `rpi-bootc-bootloader`.
- Net effect for us: **Pi firmware/bootloader is pinned to whatever we flashed**
  unless we adopt the AlmaLinux-style sync hook. The OS updates atomically; the
  bootloader does not.

## 5. Reference implementations worth stealing from

| Project | Base | Pi models | Approach | State |
|---|---|---|---|---|
| `ondrejbudai/fedora-bootc-raspi` | `fedora-bootc:40` | Pi4 | u-boot + `bootupctl` shim, bib `--type raw` → `arm-image-installer --target=rpi4` | tiny, clear, stale (F40) |
| `AlmaLinux/bootc-images-rpi` | centos/alma bootc | **Pi5/4/3/Zero2W, tested** | RPi *downstream* kernel (`raspberrypi2-kernel4`) + `rpi-bootc-bootloader` + custom partition layout | most mature; experimental but real releases |
| `mrguitar/fedora-rpi5-bootc` | fedora-bootc | Pi5 | dwrobel COPR kernel + firmware + cmdline.txt fix | explicitly "does not yet yield a working image" |
| `kfox1111/rpi-bootc-bootloader` | n/a (tool) | Pi3–Pi5 | direct boot, devicetree mgmt, tryboot A/B, GPIO rollback button | v0.0.8, the key building block |
| `ublue-os/image-template` | any ublue image | n/a | Containerfile + GH Actions + cosign signing → GHCR | our packaging pattern; **runner is `ubuntu-24.04`, x86-only — needs `ubuntu-24.04-arm` or QEMU** |

## 6. Candidate architectures

**A. Pi 4 + stock uCore, documented path (lowest risk)**
`coreos-installer install -a aarch64 -i config.ign` to SD/USB → drop Pi firmware
+ u-boot (or EDK2) onto the ESP → boot → Ignition auto-rebases to our custom
uCore image (ublue ships an `ucore-autorebase.butane` example for exactly this).
Customization lives entirely in a Containerfile in this repo; no disk-image
build pipeline needed. Firmware stays manual.

**B. Pi 5 + custom uCore-derived image (what we probably want, more work)**
`FROM ghcr.io/ublue-os/ucore-minimal:stable` (arm64) + `bcm2712-firmware`,
`uboot-images-armv8`, `rpi-bootc-bootloader` + `config.txt`/cmdline handling →
build disk image with `image-builder` and a custom partition layout (FAT boot
partition first) → flash. Risk: FCOS's Ignition-first-boot model vs. a
image-builder-produced disk; uCore's supported entry point is coreos-installer +
Ignition, not a prebuilt raw image. Plus the Pi5 gaps (NVMe boot, thermal).

**C. Abandon FCOS base, port uCore's package set onto a Pi-native bootc base**
(AlmaLinux rpi bootc, or fedora-bootc + Pi kernel). Best hardware support,
tryboot rollback, proven on Pi5 — but it is no longer "uCore", we inherit
maintenance of the package layer, and we lose ublue's signed daily builds.

## 7. Risks / open items
- Pi firmware + bootloader are **not** covered by atomic updates (bootupd gap).
- SD/USB flash endurance: none of these images are write-tuned (AlmaLinux warns).
- Ignition on a non-coreos-installer disk image is unproven for uCore.
- Serial console (UART) is effectively mandatory for first-boot debugging on Pi5.
- No Secure Boot on Pi; uCore's signed-kernel machinery buys us nothing here.
- ZFS/akmods on aarch64 in uCore is lightly tested.
- `mergerfs` unavailable on aarch64 (rules out full `ucore` variant if needed).

## 8. Sources
- ucore: github.com/ublue-os/ucore (README, Containerfile.in, install-ucore-minimal.sh)
- FCOS on Pi4: docs.fedoraproject.org/sw/fedora-coreos/provisioning-raspberry-pi4/
- Fedora Pi5: nullr0ute.com/2026/03/fedora-44-on-the-raspberry-pi-5/ ;
  discussion.fedoraproject.org/t/raspberry-pi-5-images-for-fedora-44/183204
- bootc image builds: osbuild.org/docs/bootc/deprecation-notice/ ; github.com/osbuild/image-builder-cli
- Pi bootc references: github.com/{ondrejbudai/fedora-bootc-raspi, AlmaLinux/bootc-images-rpi,
  mrguitar/fedora-rpi5-bootc, kfox1111/rpi-bootc-bootloader}
- bootupd gap: github.com/coreos/bootupd/issues/651, pull/935
