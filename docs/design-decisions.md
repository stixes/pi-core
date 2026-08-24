# Design decisions

Why the code looks the way it does. Short and durable by intent — point-in-time
research and deployment planning are deliberately kept out of this repo, since
they go stale on a different clock than the code.

## Rebase, not a disk image

We never build a disk image. Stock Fedora CoreOS is flashed to the card, the Pi
firmware is added to its ESP, and Ignition rebases the machine onto our image on
first boot.

- It is the only Pi path Fedora documents and tests.
- Customisation stays a Containerfile, so CI builds it and the device pulls it —
  no image-building pipeline to maintain.
- It avoids an unproven question: whether Ignition behaves on a disk produced by
  `image-builder` rather than by `coreos-installer`.

## U-Boot, not an EDK2 chainloader

EDK2 makes a Pi look like a SystemReady server, so unmodified aarch64 images
boot. But its defaults need interactive firmware-menu changes — a 3 GB RAM cap
on Pi 4, and ACPI mode which hides GPIO. That is the wrong trade for a headless
machine. U-Boot's EFI layer has fewer moving parts and needs no console.

## `ucore-minimal`, not `ucore`

The full variant adds storage tooling including `mergerfs`, which has no aarch64
build. Minimal already carries what a Pi needs: bootc, docker+podman, tailscale,
cockpit, firewalld.

## Pi 5 primary, Pi 4 supported, Pi 3 not a target

One `bcm283x-firmware` pull covers Pi 3/4/5, so the *payload* is model-agnostic
and there is no cost to shipping it whole. Targeting is a separate decision:

- **Pi 5** — U-Boot 2026.04 carries `brcm,bcm2712` including `bcm2712-sdhci`,
  and the image's kernel has `rp1_pci`, `clk-rp1` and `pinctrl-rp1`, so the SD
  boot path and the RP1 southbridge are both present. No NVMe: U-Boot has no
  BCM2712 PCIe yet.
- **Pi 4** — the model Fedora CoreOS actually documents; kept as the reference
  path.
- **Pi 3 / Zero 2 W** — excluded on RAM (1 GB and 512 MB), not on enablement.
  The DTBs are in the kernel and the firmware ships, so they may well boot;
  they are just not somewhere a container host belongs.

## aarch64 only, asserted at build time

`build_files/build.sh` fails loudly if the build arch is not aarch64. A silently
x86 image would look fine in a registry and be undiagnosable on the device.

## Firmware reconciliation is manual

`bootc upgrade` cannot update the Pi's firmware: `bootupd` manages only
`/boot/efi/EFI`, while a Pi needs its firmware, DTBs, `config.txt` and
`u-boot.bin` at the root of the ESP (coreos/bootupd#766).

Each image therefore carries a copy at `/usr/lib/pi-core/firmware`, a boot-time
unit reports drift, and `pi-core-firmware sync` applies it **on request**. Not
automatic: a bad firmware write bricks the boot and there is no rollback for it.

## Zincati masked, Docker over Quadlet

Zincati fights a Universal Blue rebase, so the Ignition config masks it and lets
`rpm-ostreed-automatic` stage updates instead. Container workloads use Docker
Compose rather than podman Quadlet, because an OS rebase can orphan the
container runtime that units assume.

## The owner is derived, never committed

`scripts/repo-owner.sh` resolves the GHCR namespace from `REPO_ORGANIZATION`,
`GITHUB_REPOSITORY_OWNER`, or the git remote. Hardcoding it meant a fork would
verify the upstream author's image instead of its own.

## The CI signing pins are one set

cosign v3.1.2 + cosign-installer v4.1.2 (SHA-pinned; there is no floating `v4`
tag) + `docker/login-action` (cosign reads `~/.docker/config.json`, which
`podman login` does not write). Changing any one of the three breaks signing —
see the comments in `.github/workflows/build.yml`.
