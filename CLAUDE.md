# pi-core

Custom [uCore](https://github.com/ublue-os/ucore) (Fedora CoreOS) bootc image
for Raspberry Pi. **Personal project** — personal homelab scope, personal git
identity (see `git config --local user.email`). No work conventions apply here.

Published: `ghcr.io/stixes/pi-core:stable` (public, cosign-signed).

## Model

We never build a disk image. Stock FCOS is flashed to the card, the Pi firmware
goes on its ESP, and Ignition rebases the machine onto our image on first boot.
After that it is an ordinary bootc host. Customisation lives in `Containerfile`
+ `build_files/build.sh`; CI builds it on a native arm64 runner and the device
pulls it.

Boot chain: `EEPROM -> config.txt (kernel=rpi-u-boot.bin) -> U-Boot -> its EFI
layer -> GRUB -> BLS -> ostree deployment`.

Background and rejected alternatives are in `docs/research.md`; the target
workload and phasing are in `docs/plan.md`. Read those before redesigning
anything.

## Commands

```bash
make build      # local aarch64 build (qemu on x86; slow but works)
make inspect    # sanity-check the built image
make ignition   # render build/pi4.ign
make flash DISK=/dev/sdX   # DESTRUCTIVE
```

## Rules

- **aarch64 only.** `build.sh` asserts the arch and fails loudly; do not
  "fix" that by relaxing it.
- **`pi-core.env` must be bare `KEY=value`** — no quotes, no inline comments.
  Three parsers read it (make `include`, shell `source`, `>> $GITHUB_ENV`) and
  they disagree about quoting. Make keeps both the quotes and the whitespace
  before an inline comment.
- **The CI signing block is a matched set.** cosign `v3.1.2` +
  cosign-installer pinned by SHA (`v4.1.2`, it has no floating `v4` tag) +
  `docker/login-action` (cosign reads `~/.docker/config.json`; `podman login`
  writes somewhere else). Change one and check the others.
- **Never commit `cosign.key`.** It is gitignored; the CI copy lives in the
  `SIGNING_SECRET` repo secret.
- **`scripts/flash.sh` is destructive and must run on the host**, never in
  Toolbx/distrobox — container root maps to a different UID and corrupts ESP
  ownership.
- **bootc does not update Pi firmware.** `bootupd` only manages
  `/boot/efi/EFI`, but the Pi needs its files at the ESP root
  (coreos/bootupd#766). Each image carries a copy at
  `/usr/lib/pi-core/firmware`; reconcile with `pi-core-firmware sync`,
  deliberately by hand — a bad firmware write bricks the boot with no rollback.
- **`/boot` must be empty in the built image**, or `bootc container lint`
  warns. Installing firmware packages creates `/boot/efi`; remove the directory,
  not just its contents.

## Verifying a build is real

Green CI is not proof. Check the artifact:

```bash
cosign verify --key cosign.pub ghcr.io/stixes/pi-core:stable
```

and confirm the config reports `architecture: arm64`, `ostree.bootable: 1`.

## Status

Builds, lints clean, publishes and signs. **Never booted on real hardware.**
Nothing here is verified against a Pi yet — treat hardware claims as untested.
