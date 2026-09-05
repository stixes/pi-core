# pi-core

Custom [uCore](https://github.com/ublue-os/ucore) (Fedora CoreOS) bootc image
for Raspberry Pi. **Personal project** — personal homelab scope, personal git
identity (see `git config --local user.email`). No work conventions apply here.

Targets: **Pi 5 primary, Pi 4 supported**, Pi 3 / Zero 2 W explicitly not
(RAM, not enablement). Model differences that bite: Pi 5 is SD-only and its
serial console is the debug connector (`ttyAMA10`), not GPIO 14/15
(`ttyAMA0`).

Published to `ghcr.io/<owner>/pi-core:stable` (public, cosign-signed), where
`<owner>` is derived by `scripts/repo-owner.sh` — never hardcode it.

## Model

We never bake our customisations into a disk image. Stock FCOS is flashed to the
card (or to a loop-mounted file by `scripts/build-image.sh`, same bytes), the Pi
firmware goes on its ESP, and Ignition rebases the machine onto our image on
first boot.
After that it is an ordinary bootc host. Customisation lives in `Containerfile`
+ `build_files/build.sh`; CI builds it on a native arm64 runner and the device
pulls it.

Boot chain: `EEPROM -> config.txt (kernel=rpi-u-boot.bin) -> U-Boot -> its EFI
layer -> GRUB -> BLS -> ostree deployment`.

The reasoning behind each choice is in `docs/design-decisions.md` — read it
before redesigning anything.

### What belongs in `docs/`

Public repo, versioned with the code. A doc earns a place here if it is
**durable, about this project, and safe to publish**:

- how to build, install, operate or recover the thing
- why the code is shaped the way it is (`design-decisions.md`)
- behaviour a user or contributor must know

Keep out, on purpose:

- **point-in-time material** — upstream research, comparisons, status
  snapshots. It ages on a different clock than the code and rots unnoticed.
- **personal infrastructure** — host names, addresses, estate topology,
  which machine gets which workload.
- **cross-project synthesis** — knowledge that outlives this repo.

Those three live in the private wiki instead. If a doc would need editing
because something *outside* this repo changed, it belongs there, not here.

When a doc states a checkable fact about the image, add the matching assertion
in `tests/` — see the avahi/`.local` guard for the pattern.

## Commands

```bash
just                        # list recipes
just build                  # local aarch64 build (qemu on x86; slow but works)
just test                   # tier 0 (static) — fast, no build
just ci                     # push the branch; CI builds + tests on arm64
just test-supply-chain      # tier 1.5 — the published image
just test-hardware <host>   # tier 3 — a booted Pi, over SSH, read-only
just inspect                # sanity-check the built image
just ignition               # render build/pi.ign
just image                  # build the published .img (+ .xz); needs sudo
```

## Tests

`just test` is the fast gate and the one to run while editing: `tests/static.sh`
only (shellcheck, actionlint, ignition validation, env-file format and three-way
parse agreement), about 5 seconds, no image needed.

`tests/image.sh` (architecture, firmware-stash completeness, Pi 3/4/5 DTBs,
empty `/boot`, unit enablement, mDNS, the password drop-in) needs a built image.
**Do not build it locally to check a change** — emulated dnf under qemu takes
~25 minutes on x86. Push the branch and let a native arm64 runner do it in well
under a minute: `just ci` dispatches the workflow and watches it. `just test-all`
runs both locally if you really want to wait.

`just test-supply-chain` checks the *published* image's signature and that it is
pullable with no credentials.

On hardware: `just test-hardware <host>` (read-only, over SSH) covers what can
be scripted. Everything before SSH works is a manual test at the console —
`docs/hardware-acceptance.md` is the procedure.

Assertions double as documentation guards: the image test fails if the mDNS
responder *disappears*, because INSTALL.md promises `.local` resolves, and fails
if `cockpit-ws` appears, because the default password must not gain a web front
door. (The avahi guard used to assert the opposite; it was inverted, not
deleted, when the published image needed to be findable.) If you change
behaviour a test asserts, update the docs in the same commit.

Green CI is not proof — verify the artifact:

```bash
cosign verify --key cosign.pub "ghcr.io/$(./scripts/repo-owner.sh)/pi-core:stable"
```

## Rules

- **aarch64 only.** `build.sh` asserts the arch and fails loudly; do not
  "fix" that by relaxing it.
- **`pi-core.env` must be bare `KEY=value`** — no quotes, no inline comments.
  Three parsers read it (just's `dotenv-load`, shell `source`, and
  `>> $GITHUB_ENV`) and they disagree about quoting. `tests/static.sh` enforces
  both the format and that all three agree.
- **The CI signing block is a matched set.** cosign `v3.1.2` +
  cosign-installer pinned by SHA (`v4.1.2`, it has no floating `v4` tag) +
  `docker/login-action` (cosign reads `~/.docker/config.json`; `podman login`
  writes somewhere else). Change one and check the others.
- **Never commit `cosign.key`.** It is gitignored; the CI copy lives in the
  `SIGNING_SECRET` repo secret.
- **`scripts/build-image.sh` must run on the host**, never in Toolbx/distrobox
  — container root maps to a different UID and corrupts ESP ownership. It needs
  `sudo` for loop devices and mounting the image's ESP.
- **bootc does not update Pi firmware.** `bootupd` only manages
  `/boot/efi/EFI`, but the Pi needs its files at the ESP root
  (coreos/bootupd#766). Each image carries a copy at
  `/usr/lib/pi-core/firmware`; reconcile with `pi-core-firmware sync`,
  deliberately by hand — a bad firmware write bricks the boot with no rollback.
- **`/boot` must be empty in the built image**, or `bootc container lint`
  warns. Installing firmware packages creates `/boot/efi`; remove the directory,
  not just its contents.
- **There is one install path and one Ignition config.** Download the published
  image, flash, boot, log in as `core`, configure in place. No build-time
  settings, nothing to edit on the card, no per-device state in this repo. Both
  earlier mechanisms — `pi-core.conf` + `pi-core-provision`, and per-device
  Ignition rendering with someone's SSH key — were deleted, not deprecated. Do
  not reintroduce pre-boot configuration; an image handed to a stranger cannot
  depend on it, and `hostnamectl`/`authorized_keys`/`timedatectl` already work
  after login.
- **The Ignition template is model-agnostic** — nothing in `ignition/pi.bu.in`
  is Pi 4 or Pi 5 specific, and it should stay that way. If a model needs its
  own config, that is a second template, not a conditional.
- **The published image ships `core` / `core` on purpose.** SSH password auth is
  on (`10-pi-core-passwords.conf`, which must keep sorting before FCOS's
  `40-disable-passwords.conf` — sshd takes the *first* value for a keyword) and
  nothing forces a change: leaving `core` / `core` in place is the owner's
  decision, the DietPi model. Do not "harden" this by disabling password auth or
  by expiring the password — it is what makes a card-only install work. Do keep `cockpit-ws` out — uCore enables password auth on
  localhost, so a web login on :9090 would turn a console credential into a
  remote one.
- **`console=tty0` is not clutter.** Without the karg an attached monitor goes
  blank when the kernel starts, and with no serial console that leaves a
  non-networking boot undiagnosable.

## Status

Builds, lints clean, publishes and signs. **Never booted on real hardware** —
the boot chain (EEPROM → U-Boot → GRUB → ostree) is entirely unexercised and no
automated tier can validate it. `docs/hardware-acceptance.md` is the gate;
until a run is recorded against it, treat every hardware claim as untested.

Say so plainly when reporting on this project. "Tests pass" is true and does
not mean it works.
