# pi-core

Custom [uCore](https://github.com/ublue-os/ucore) (Fedora CoreOS) bootc image
for Raspberry Pi. **Personal project** — personal homelab scope, personal git
identity (see `git config --local user.email`). No work conventions apply here.

Scope is in `docs/requirements.md` §5; don't restate it here. The two model
differences that bite in practice: Pi 5 is SD-only, and its serial console is
the debug connector (`ttyAMA10`), not GPIO 14/15 (`ttyAMA0`).

Published to `ghcr.io/<owner>/pi-core:stable` (public, cosign-signed), where
`<owner>` is derived by `scripts/repo-owner.sh` — never hardcode it.

## Model

`scripts/build-image.sh` runs `bootc install to-disk` to deploy the pi-core
container onto a disk image, and adds the Pi firmware to its ESP. The published
image **is** pi-core, not an installer for it: one boot, nothing downloaded, no
network needed to reach a usable machine. After that it is an ordinary bootc
host. Customisation lives in `Containerfile` + `build_files/build.sh`; CI builds
it on a native arm64 runner and the device pulls it for updates.

There is no Ignition config. It was deleted with the installer model — see
`docs/design-decisions.md` for what that cost and why it was still worth it.

Boot chain: `EEPROM -> config.txt (kernel=rpi-u-boot.bin) -> U-Boot -> its EFI
layer -> GRUB -> BLS -> ostree deployment`.

What the image must do is in `docs/requirements.md`; the reasoning behind each
choice is in `docs/design-decisions.md` — read both before redesigning
anything.

### What belongs in `docs/`

Public repo, versioned with the code. A doc earns a place here if it is
**durable, about this project, and safe to publish**:

- what the thing must do, and how each requirement is verified
  (`requirements.md`)
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
just image                  # build the published .img (+ .xz); needs sudo
```

## Tests

`just test` is the fast gate and the one to run while editing: `tests/static.sh`
only (shellcheck, actionlint, env-file format and three-way parse agreement,
and that build-image.sh still passes the console kargs), about 5 seconds, no image needed.

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
- **There is one install path.** Download the published image, flash, boot, log
  in as `core`, configure in place. No build-time settings, nothing to edit on
  the card, no per-device state in this repo. Three mechanisms that once did
  this — `pi-core.conf` + `pi-core-provision`, per-device Ignition rendering,
  and the first-boot rebase — were deleted, not deprecated. Do not reintroduce
  pre-boot configuration; an image handed to a stranger cannot depend on it.
- **What Ignition used to provide, the image must.** The `core` user comes from
  `sysusers.d` (a bare `/etc/passwd` entry fails `bootc container lint`) and
  root growth from `pi-core-growfs.service`, because Fedora CoreOS only grows
  the root on an Ignition firstboot. Both are asserted in tier 1.
- **The image is model-agnostic** — nothing in it is Pi 4 or Pi 5 specific, and
  it should stay that way.
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

Runs on a Raspberry Pi 4. A flashed card boots to a login and a working network
unattended, `bootc upgrade` applies a new image in about 20 seconds and reboots
into it, the root filesystem grows to fill the card, and `<hostname>.local`
resolves. Builds, lints clean, publishes and signs.

Not yet proven, and worth saying so rather than implying otherwise:

- **Pi 5.** Everything here is model-agnostic and the firmware ships for it,
  but only a Pi 4 has run this.
- **`bootc rollback`.** There has been one upgrade and the previous deployment
  was pruned, so nothing has been rolled back yet.
- **Unattended growth from a fresh card.** Proven by hand and proven to
  no-op correctly, but the 5.5 GB -> full-card path has not run untouched on a
  first boot since it was fixed.
- **The image install is unsigned.** `build-image.sh` passes
  `--target-no-signature-verification` because the container policy in the
  image carries no entry for our cosign key. The image is verified out of band
  instead. This is the largest outstanding gap.

`docs/hardware-acceptance.md` is the checklist. Six behaviours that Fedora
CoreOS provides during an Ignition firstboot had to be reimplemented for
`bootc install`, each found by a failed boot: see `docs/design-decisions.md`
before assuming anything in that area is incidental.