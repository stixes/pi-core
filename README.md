# pi-core

A custom [uCore](https://github.com/ublue-os/ucore) (Fedora CoreOS) bootc image
for Raspberry Pi, for my personal homelab.

> **Status: prototype — never booted on real hardware.** CI builds, signs and
> publishes `ghcr.io/<owner>/pi-core:stable`, and `just test` passes, but no Pi
> has yet passed [docs/hardware-acceptance.md](docs/hardware-acceptance.md).
> Treat every claim about hardware behaviour as untested.

## Targets

| Model | Status | Notes |
|---|---|---|
| **Pi 5 / 500** | primary | **SD card only** — U-Boot has no BCM2712 PCIe, so no NVMe boot, and USB boot does not work either. Serial console is the debug connector (`ttyAMA10`) |
| **Pi 4 / CM4 / 400** | supported | The model Fedora CoreOS documents. Boots from USB. Serial console is GPIO 14/15 (`ttyAMA0`) |
| Pi 3 / Zero 2 W | not a target | Firmware and DTBs ship and it may well boot, but 1 GB / 512 MB is below what FCOS plus containers wants |

## How it works

1. Flash a card with stock **Fedora CoreOS** (aarch64) using `coreos-installer`.
2. Drop the Raspberry Pi firmware + U-Boot onto the card's ESP, because the Pi's
   boot ROM is not UEFI and cannot boot FCOS on its own.
3. On first boot, Ignition rebases the machine onto **our** image and reboots
   into it.
4. From then on it is an ordinary bootc host: `bootc upgrade`, atomic, rollback.

We never build a disk image. The customisation lives in `Containerfile` +
`build_files/build.sh`, gets built by CI on a native arm64 runner, and the
device pulls it.

```
Pi EEPROM  ->  config.txt (kernel=rpi-u-boot.bin)  ->  U-Boot
           ->  U-Boot's EFI layer  ->  GRUB  ->  BLS entry  ->  ostree deployment
```

U-Boot rather than an EDK2 chainloader, `ucore-minimal` rather than `ucore`, and
the rest of the reasoning: [docs/design-decisions.md](docs/design-decisions.md).

Step-by-step from a blank card: [INSTALL.md](INSTALL.md).

## Just want a running Pi?

Take the prebuilt image from the [releases page](../../releases), flash
`pi-core-*.img.xz` to a card with Raspberry Pi Imager, balenaEtcher, Rufus
(DD mode) or `dd`, and boot it. Log in as **`core` / `core`**, at the console or
over SSH at `pi-core.local`; the password is expired, so the first login makes
you change it.

That image enables SSH password authentication and advertises itself over mDNS
so it can be reached with nothing but a flashed card — which also means the
published password works from anywhere on the LAN until you finish that first
login. On a network you do not control, log in from a console before connecting
Ethernet. The reasoning is in
[docs/design-decisions.md](docs/design-decisions.md#default-credentials-on-the-published-image).

Building it yourself instead bakes in your own SSH key and leaves password
authentication off.

## Usage

```bash
just                        # list recipes
just build                  # build locally (qemu on x86; slow but works)
just test                   # static checks + image assertions
just inspect                # sanity-check the built image
just ignition               # render build/pi.ign
just password-hash          # console password hash (see INSTALL.md)
just flash /dev/sdX         # DESTRUCTIVE: FCOS + firmware onto a card
just image                  # build a flashable .img instead of writing a card
just test-supply-chain      # verify the published image's signature
just test-hardware <host>   # assertions against a booted Pi, over SSH
```

`just flash` must run **on the host, not in Toolbx** — root in a container maps
to a different UID and corrupts ownership on the ESP.

## Layout

| Path | Purpose |
|---|---|
| `pi-core.env` | Build parameters. Bare `KEY=value` only — three parsers read it |
| `justfile` | Every entry point |
| `Containerfile` | `FROM ucore-minimal:stable`, runs `build.sh` |
| `build_files/build.sh` | Package installs + the firmware stash |
| `system_files/` | Overlay copied to `/` (the `pi-core-firmware` helper and its unit) |
| `ignition/pi.bu.in` | Butane template for first boot (autorebase); model-agnostic |
| `provisioning/pi-core.conf.example` | Headless per-device settings, copied to the card |
| `scripts/fetch-firmware.sh` | Pull + extract the Pi firmware payload |
| `scripts/render-ignition.sh` | Template -> `build/pi.ign` |
| `scripts/flash.sh` | FCOS install + firmware onto the ESP |
| `scripts/repo-owner.sh` | Derives the GHCR owner; never hardcoded |
| `tests/` | static / image / supply-chain / hardware tiers |
| `docs/design-decisions.md` | Why the code looks the way it does |
| `docs/hardware-acceptance.md` | The checklist a real Pi must pass |
| `.github/workflows/build.yml` | Build, test, sign, push to GHCR (arm64 runner) |

## Testing

`just test` runs without hardware or a registry: shellcheck, actionlint,
Ignition validation, and assertions against the built image (architecture,
firmware-stash completeness, Pi 3/4/5 DTBs, empty `/boot`, unit enablement).

`just test-supply-chain` checks the *published* image — that its cosign
signature verifies, and that it can be pulled with **no credentials**, which is
what the Pi does during the first-boot rebase.

`just test-hardware <host>` is the part that needs a booted Pi. Everything
before SSH works is a manual test at the console; see
[docs/hardware-acceptance.md](docs/hardware-acceptance.md).

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

Deliberately manual: a bad firmware write bricks the boot and there is no
rollback for it. If it becomes tiresome, the upgrade path is
[kfox1111/rpi-bootc-bootloader](https://github.com/kfox1111/rpi-bootc-bootloader),
which also brings Pi `tryboot` A/B rollback.

## Signing

CI signs each pushed image with cosign. `cosign.pub` is in this repo; the
private key lives only in the `SIGNING_SECRET` repository secret and is
gitignored locally as `cosign.key`.

```bash
cosign verify --key cosign.pub "ghcr.io/$(./scripts/repo-owner.sh)/pi-core:stable"
```

**The rebase itself is still unsigned.** The Ignition config uses
`ostree-unverified-registry:` because the image does not yet ship a
container-policy entry for this key. Wiring that in is the next step toward a
verified boot chain.

## Forking

Nothing carries an owner: `scripts/repo-owner.sh` derives the GHCR namespace
from `GITHUB_REPOSITORY_OWNER` in CI, or your git remote locally, so a fork
publishes and verifies its own image without edits. Override with
`REPO_ORGANIZATION=...`.

You will want your own signing key: `cosign generate-key-pair`, commit the new
`cosign.pub`, and add the private key as your fork's `SIGNING_SECRET`.

## License

Apache-2.0, matching uCore / Universal Blue upstream.
