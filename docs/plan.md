---
title: pi-core — build plan (Pi 4 first)
date: 2026-08-24
scope: personal homelab
---

# Plan: uCore on Raspberry Pi 4

Decisions taken 2026-08-24:
- **Target hardware:** Pi 4 first. Pi 3 and Pi 5 are future targets, so keep
  model-specific bits isolated rather than hardcoded.
- **Base:** stay on uCore. Optimise for a working device fast.
- **Scope:** personal homelab only.

## Chosen architecture — the documented FCOS path

Install stock Fedora CoreOS aarch64 to the boot medium with `coreos-installer`,
drop the Pi firmware + U-Boot onto its ESP, boot, and let an Ignition-declared
one-shot service **auto-rebase to our custom uCore image**. ublue ships
`examples/ucore-autorebase.butane` doing exactly this (unsigned rebase first,
then a second boot rebases to the cosign-verified ref).

Why this and not the alternatives:
- No disk-image build pipeline needed at all — customization is a Containerfile
  in this repo, pushed to GHCR; the device pulls it.
- It is the only Pi path Fedora actually documents and tests.
- Avoids the unproven "Ignition on an image-builder-produced disk" question.

**U-Boot, not EDK2.** EDK2 makes the Pi look like a SystemReady server, but its
defaults need interactive menu fiddling on first boot (3 GB RAM cap; ACPI mode
which hides GPIO). For a headless box, U-Boot is fewer moving parts.
Revisit only if U-Boot's EFI layer misbehaves.

**Storage: USB SSD, not microSD.** ostree/bootc deployments are write-heavy and
none of these images are write-tuned; the AlmaLinux project explicitly warns
about burning through cheap flash. Pi 4 boots from USB with a current EEPROM.

## Phases

### 0. Prerequisites (hands-on, one time)
- Update the Pi 4 **EEPROM** to current (`rpi-imager` → bootloader update disk).
  Old EEPROMs cannot read the FAT16 ESP that FCOS uses.
- Decide boot medium; have a USB-serial adapter available for first-boot debug.

### 1. Custom uCore image (this repo)
- `Containerfile` → `FROM ghcr.io/ublue-os/ucore-minimal:stable` (arm64 exists).
  `ucore-minimal` unless we need the storage tooling; note `mergerfs` has no
  aarch64 build, which is an argument against the full `ucore` variant.
- Layer local specifics (tailscale is already in ucore-minimal; add our
  monitoring/agent bits, sysctls, systemd units).
- Build + push to GHCR with cosign signing, modelled on `ublue-os/image-template`
  — but the template's workflow runs on `ubuntu-24.04`; we need
  **`ubuntu-24.04-arm`** runners (free for public repos) or QEMU cross-build.

### 2. Provisioning artifacts
- Butane → Ignition config: `core` user + SSH key, hostname, autorebase units
  pointed at *our* image, local network/tailscale bits.
- A `flash.sh` that does the documented sequence end to end:
  1. `dnf download --resolve --releasever=44 --forcearch=aarch64 --destdir=... \
      uboot-images-armv8 bcm283x-firmware bcm283x-overlays` (verify whether
      `bcm2711-firmware` is pulled in by `--resolve`; the doc's prose lists it
      but its command omits it — Pi 4 needs `start4.elf`/`fixup4.dat`).
  2. `rpm2cpio | cpio -idv`, then
     `mv usr/share/uboot/rpi_arm64/u-boot.bin boot/efi/rpi-u-boot.bin`.
  3. `sudo coreos-installer install -a aarch64 -s stable -i config.ign $DISK`
  4. mount the `EFI-SYSTEM` partition, `rsync -avh --ignore-existing --chown 0:0`
     the firmware in, unmount.
- ⚠️ All of this must run **outside** a Toolbx container (root UID mapping
  breaks ownership). Relevant here — the build host is Fedora Atomic.

### 3. First boot & validation
- Expect 20–30 s of black screen before anything appears.
- Verify: boots → Ignition applied → autorebase to our image → reboot → second
  autorebase to the signed ref → `bootc status` shows our image.
- Then validate the actual workload and `bootc upgrade` on a subsequent build.

### 4. Deferred / known gaps (do not solve now)
- **Pi firmware + U-Boot are not updated by bootc** (`bootupd` only manages
  `/boot/efi/EFI`; PR coreos/bootupd#935 still open). Updating them means
  re-running step 2's rsync by hand. If this becomes painful, adopt
  `kfox1111/rpi-bootc-bootloader` — which also brings Pi `tryboot` A/B rollback.
- Pi 5 later: stock F44 kernel has the Pi 5 DTBs and `rp1_pci`, but Fedora's own
  Pi 5 images used a patched build, and NVMe boot / thermal / audio were broken
  as of 2026-03. Re-check before committing.
- Pi 3 later: DTBs are in the stock F44 kernel (verified), so the base image may
  work unchanged; RAM (1 GB on 3B+) is the binding constraint, not enablement.
  Keep model-specific config out of the base layer regardless.

## Repo shape (proposed)
```
Containerfile              # FROM ucore-minimal:stable + local layer
build_files/build.sh       # package installs / tweaks
system_files/              # /etc + /usr overlay
ignition/pi4.bu            # butane source -> config.ign
scripts/flash.sh           # firmware fetch + coreos-installer + ESP rsync
.github/workflows/build.yml# arm64 runner, build + cosign + push to GHCR
docs/{research,plan}.md
```
