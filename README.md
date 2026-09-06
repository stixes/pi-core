# pi-core

A custom [uCore](https://github.com/ublue-os/ucore) (Fedora CoreOS) bootc image
for Raspberry Pi, for my personal homelab.

> **Status:** runs on a Pi 4 — boots, updates and grows unattended. What is and
> is not proven is kept in [CLAUDE.md](CLAUDE.md#status); the checklist that
> proves it is [docs/hardware-acceptance.md](docs/hardware-acceptance.md).

Targets **Pi 5 and Pi 4**; Pi 3 and Zero 2 W are out of scope on RAM. Scope and
the reasons are in [docs/requirements.md](docs/requirements.md#5-scope).

## How it works

1. CI builds the pi-core container on a native arm64 runner and signs it.
2. `bootc install to-disk` deploys that container onto a disk image, so the
   image *is* pi-core rather than an installer for it.
3. The Raspberry Pi firmware + U-Boot go onto the image's ESP, because the Pi's
   boot ROM is not UEFI and cannot boot Fedora CoreOS on its own.
4. Flash, boot once, log in. Nothing is downloaded and no network is needed to
   reach a usable machine.
5. From then on it is an ordinary bootc host: `bootc upgrade`, atomic, rollback.

Customisation lives in `Containerfile` + `build_files/build.sh`. The device
pulls that same container for updates; only the first boot is pre-baked.

```
Pi EEPROM  ->  config.txt (kernel=rpi-u-boot.bin)  ->  U-Boot
           ->  U-Boot's EFI layer  ->  GRUB  ->  BLS entry  ->  ostree deployment
```

U-Boot rather than an EDK2 chainloader, `ucore-minimal` rather than `ucore`, and
the rest of the reasoning: [docs/design-decisions.md](docs/design-decisions.md).

## Installing

Download, flash, boot, log in — that is the whole install, and it is the only
one supported. There is no build-time configuration and nothing to edit on the
card; a machine is configured after you log into it. Step by step:
[INSTALL.md](INSTALL.md).

Take the image from the [releases page](../../releases) and write
`pi-core-*.img.xz` to a card with Fedora Media Writer or Rufus, then boot it.
The image is pi-core itself, deployed with `bootc install`, so first boot needs
no network and downloads nothing. Log in as **`core` / `core`**, at the console
or over SSH at `pi-core.local`.

That image enables SSH password authentication and advertises itself over mDNS
so it can be reached with nothing but a flashed card — which also means the
published password works from anywhere on the LAN for as long as you leave it
in place. Changing it is your call, not something the image forces. On a network
you do not control, log in from a console before connecting Ethernet. The reasoning is in
[docs/design-decisions.md](docs/design-decisions.md#default-credentials-on-the-published-image).

Then configure it in place: `hostnamectl set-hostname`, add your key, and set
`PasswordAuthentication no` in `/etc/ssh/sshd_config.d/10-pi-core-passwords.conf`
to close that window for good.

## Usage

```bash
just                        # list recipes
just build                  # build locally (qemu on x86; slow but works)
just test                   # fast static checks (~5 s, no build)
just ci                     # push the branch; CI builds + tests on arm64
just inspect                # sanity-check the built image
just image                  # build the flashable .img that gets published
just test-supply-chain      # verify the published image's signature
just test-hardware <host>   # assertions against a booted Pi, over SSH
```

`just image` must run **on the host, not in Toolbx** — root in a container maps
to a different UID and corrupts ownership on the ESP. It also needs `sudo`, for
loop devices and mounting the image's EFI partition.

## Layout

| Path | Purpose |
|---|---|
| `pi-core.env` | Build parameters. Bare `KEY=value` only — three parsers read it |
| `justfile` | Every entry point |
| `Containerfile` | `FROM ucore-minimal:stable`, runs `build.sh` |
| `build_files/build.sh` | Package installs + the firmware stash |
| `system_files/` | Overlay copied to `/` (the `pi-core-firmware` helper and its unit) |
| `scripts/build-image.sh` | `bootc install` + firmware -> the published `.img` |
| `scripts/repo-owner.sh` | Derives the GHCR owner; never hardcoded |
| `tests/` | static / image / supply-chain / hardware tiers |
| `docs/requirements.md` | What the image has to do, and how each requirement is checked |
| `docs/design-decisions.md` | Why the code looks the way it does |
| `docs/hardware-acceptance.md` | The checklist a real Pi must pass |
| `.github/workflows/build.yml` | Build, test, sign, push to GHCR (arm64 runner) |

## Testing

`just test` is the fast local gate: shellcheck, actionlint and config checks,
about five seconds, no image build. `just test-image` asserts against a built
image (architecture, firmware stash, Pi 3/4/5 DTBs, empty `/boot`, the `core`
user, growfs, mDNS, the password drop-in) — building locally means emulated dnf
under qemu, so `just ci` hands that to a native arm64 runner instead.

`just test-supply-chain` checks the *published* image — that its cosign
signature verifies, and that it can be pulled with **no credentials**, which is
what the Pi does when it pulls an update.

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

**The image install is still unsigned.** `build-image.sh` passes
`--target-no-signature-verification` because the container policy shipped in
the image does not yet carry this key. The image is verified out of band
instead. Wiring the key into `policy.json` is the next step toward a verified
boot chain, and it also matters for `bootc upgrade` on the device.

## Forking

Nothing carries an owner: `scripts/repo-owner.sh` derives the GHCR namespace
from `GITHUB_REPOSITORY_OWNER` in CI, or your git remote locally, so a fork
publishes and verifies its own image without edits. Override with
`REPO_ORGANIZATION=...`.

You will want your own signing key: `cosign generate-key-pair`, commit the new
`cosign.pub`, and add the private key as your fork's `SIGNING_SECRET`.

## Provenance

Written by Claude (Anthropic) under my direction, and verified by me.

- **Code and build tooling** — AI-written, human-directed. Every change is
  gated by the automated tiers before it reaches a card.
- **Documentation** — AI-written, human-reviewed. The decisions it records are
  mine; the wording is not.
- **Hardware verification** — human. No automated tier can reach the boot
  chain, so every claim here about booting, updating or growing came from a
  physical Pi rather than from a test suite.

## License

Apache-2.0, matching uCore / Universal Blue upstream.
