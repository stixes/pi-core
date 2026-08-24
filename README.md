# pi-core

A custom [uCore](https://github.com/ublue-os/ucore) derivative for Raspberry Pi,
for my personal homelab.

**Status: prototype.** CI builds, signs and publishes
`ghcr.io/stixes/pi-core:stable`, but nothing here has booted real hardware yet.

## How it works

The same shape as an existing uCore host in my homelab, adapted for a Pi:

1. Flash a card with stock **Fedora CoreOS** (aarch64) using `coreos-installer`.
2. Drop the Raspberry Pi firmware + U-Boot onto the card's ESP, because the Pi's
   boot ROM is not UEFI and cannot boot FCOS on its own.
3. On first boot, Ignition rebases the machine onto **our** image
   (`ghcr.io/<owner>/pi-core`) and reboots into it.
4. From then on it is an ordinary bootc host: `bootc upgrade`, atomic, rollback.

We never build a disk image. The customisation lives in `Containerfile` +
`build_files/build.sh`, gets built by CI on a native arm64 runner, and the
device pulls it.

## Boot chain

```
Pi EEPROM  ->  config.txt (kernel=rpi-u-boot.bin)  ->  U-Boot
           ->  U-Boot's EFI layer  ->  GRUB  ->  BLS entry  ->  ostree deployment
```

U-Boot rather than an EDK2 chainloader: EDK2 needs interactive firmware-menu
setup on first boot (3 GB RAM cap, ACPI mode hides GPIO), which is wrong for a
headless box. See `docs/research.md` for the full comparison.

## Layout

| Path | Purpose |
|---|---|
| `pi-core.env` | All build parameters (base image, owner, Fedora release) |
| `Containerfile` | `FROM ucore-minimal:stable`, runs `build.sh` |
| `build_files/build.sh` | Package installs + the firmware stash |
| `system_files/` | Overlay copied to `/` |
| `ignition/pi4.bu.in` | Butane template for first boot (autorebase) |
| `scripts/fetch-firmware.sh` | Pull + extract the Pi firmware payload |
| `scripts/render-ignition.sh` | Template -> `build/pi4.ign` |
| `scripts/flash.sh` | FCOS install + firmware onto the ESP |
| `.github/workflows/build.yml` | Build, sign, push to GHCR (arm64 runner) |
| `docs/` | Research brief and build plan |

## Usage

```bash
make build                      # build locally (qemu on x86; slow but works)
make inspect                    # sanity-check the built image
make ignition                   # render build/pi4.ign
make flash DISK=/dev/sdX        # DESTRUCTIVE: FCOS + firmware onto a card
```

`scripts/flash.sh` must run **on the host, not in Toolbx** — root in a Toolbx
container maps to a different UID and corrupts ownership on the ESP.

Step-by-step from a blank card: [INSTALL.md](INSTALL.md).

## The firmware gap

`bootc upgrade` updates the OS atomically. It does **not** update the Pi
firmware, DTBs, `config.txt` or U-Boot, because `bootupd` only manages
`/boot/efi/EFI` and the Pi needs those files at the ESP root
([bootupd#766](https://github.com/coreos/bootupd/issues/766);
PR [#935](https://github.com/coreos/bootupd/pull/935) is still open).

pi-core works around this rather than solving it:

- every image carries a copy of the firmware at `/usr/lib/pi-core/firmware`
- `pi-core-firmware-check.service` reports drift into the journal on each boot
- `sudo pi-core-firmware sync` writes it to the ESP, preserving your `config.txt`

It is deliberately manual: a bad firmware write bricks the boot and there is no
rollback for it. If this becomes tiresome, the upgrade path is
[kfox1111/rpi-bootc-bootloader](https://github.com/kfox1111/rpi-bootc-bootloader),
which also brings Pi `tryboot` A/B rollback.

## Signing

CI signs each pushed image with cosign. The public key is `cosign.pub`, in this
repo. The matching private key is **not** in the repo — it lives in the
`SIGNING_SECRET` repository secret, and is gitignored locally as `cosign.key`.

Verify a published image with:

```bash
cosign verify --key cosign.pub ghcr.io/stixes/pi-core:stable
```

The image does not yet ship a container-policy entry for this key, so the
Ignition rebase still uses the unverified transport. Wiring the policy in is the
next step toward a fully verified boot chain.

## License

Apache-2.0, matching uCore / Universal Blue upstream.

## Prototype limitations

- **Rebase is unsigned.** The Ignition config uses
  `ostree-unverified-registry:`. CI signs the image with cosign, but the
  verification policy is not wired into the image yet, so the signed transport
  cannot be used until it is.
- `REPO_ORGANIZATION` in `pi-core.env` is set to `stixes` — change it if that is
  not the right GHCR owner. CI also needs a `SIGNING_SECRET` repository secret.
- No workload yet. The intended first job is an independent observability node
  (uptime-kuma, homepage, beszel) — see `docs/plan.md` for why.
- Pi 4 is the only tested target. The firmware payload already covers Pi 3 and
  Pi 5, but neither has been tried; on Pi 5 expect the gaps listed in
  `docs/research.md` (NVMe boot, thermal, audio).
