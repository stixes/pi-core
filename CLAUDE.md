# pi-core

Custom [uCore](https://github.com/ublue-os/ucore) (Fedora CoreOS) bootc image
for Raspberry Pi. **Personal project** — personal homelab scope, personal git
identity (see `git config --local user.email`). No work conventions apply here.

Scope is in `docs/requirements.md` §5; don't restate it here. The two model
differences that bite in practice: Pi 5 is SD-only, and its serial console is
the debug connector (`ttyAMA10`), not GPIO 14/15 (`ttyAMA0`).

Published to `ghcr.io/<owner>/pi-core` (public, cosign-signed), where `<owner>`
is derived by `scripts/repo-owner.sh` — never hardcode it. Two tags:
**`:stable`** is moved only by a `v*` release tag and is what flashed cards
track and what the flashable image is built from; **`:testing`** is moved by
every push to main and by the nightly rebuild. A commit on main must not be
able to reach a device — that is the whole point of the split, and
`tests/static.sh` guards it.

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
just ci                     # push the branch, open a PR; CI builds + tests on arm64
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

## Release cycle

**Main is for preparing a release, not for development.** Features are built on
branches; main is where a release is assembled once the owner wants one. If no
release is being prepared, there is no reason to merge.

1. Work happens on a feature branch, as a PR. A PR build runs tiers 0 and 1 on
   a native arm64 runner and **publishes nothing**, so it cannot move a tag any
   device follows.
2. Hardware-test the branch before proposing anything. What that takes depends
   on the change: a flashable image for anything in the boot chain, and for
   anything above it the switch in step 6.
3. When something significant has accumulated, *suggest* a release.
4. **The owner asks for the merge.** Never merge or push to main unprompted —
   not to "get it onto `:testing`", not because CI is green, not because the
   change looks finished. Green CI is evidence, not authorisation.
5. Merging to main builds and publishes `:testing`, which is what a Pi tracks
   between releases.
6. Hardware-test from `:testing`, no reflash needed for anything above the boot
   chain:
   `bootc switch --enforce-container-sigpolicy ghcr.io/<owner>/pi-core:testing`
7. The owner asks for the release.
8. `git tag -a v<counter>.<YYYYMMDD> && git push --tags` — CI **rebuilds that
   commit**, publishes `:stable`, builds and signs the flashable `.img`, and
   cuts the release. Annotate it: the release notes are read from the tag
   object, and a lightweight tag has no message to read.
9. Back to 1.

**Only a PR build publishes nothing.** A `workflow_dispatch` is not a
`pull_request`, so its push and sign steps run and `:testing` moves — from a
*branch*, to the tag a device follows. `publish_image` gates only the
flashable-image job, never the container push, so no setting makes a dispatch
safe. `just ci` therefore opens a PR rather than dispatching, and
`tests/static.sh` fails if it goes back to dispatching. A manual
`publish_image` run has the same effect and additionally tags its prerelease
`image-<date>-<time>`.

### Versions are dated, not semantic

`v<counter>.<YYYYMMDD>` — `v1.20260906` — with `.1`, `.2` appended for a second
release on one day. The shape is Fedora's, and for the same reason: most
releases are *the same software rebuilt against newer upstream*, which no
semantic version can honestly describe.

**The counter is a compatibility generation, not a feature number.** Bump it
only when an existing card cannot upgrade into the new release — when a reflash
is required. It is expected to sit at 1 for a long time, and only a human moves
it. `tests/static.sh` refuses to extend any tag that is not in this shape, so an
`-rc` or a leftover `v0.x` cannot become the base of an automatic release.

A tagged build takes its version **from the ref**, not from `git describe`:
once the weekly rebuild puts a second tag on a commit that already carries one,
describe has two valid answers and may give the older.

**The rebuild at step 5 is deliberate, not laziness.** It is what lets a
release carry content that only exists in a release — the version string today,
an SBOM or changelog later. Promoting the tested digest with `skopeo copy` is
cheaper and keeps the cosign signature for free, but then nothing inside the
image can change.

What it costs is worth knowing: **a rebuild of the same commit is not the same
image.** `BASE_IMAGE` tracks `ucore-minimal:stable` and the dnf installs in
`build.sh` resolve against current Fedora, so the released artifact can carry a
different base and different packages than the `:testing` build that was tested
on hardware. Tiers 0, 1 and 1.5 re-run on it, so it is not unguarded — but
boot, growth and upgrade behaviour was proven on a different artifact.

So: **after cutting a release, point the Pi at `:stable` and run `just
test-hardware` before flashing any card from it.**

### The weekly rebuild

`.github/workflows/weekly.yml` runs Mondays. It rebuilds **the last dated
release's commit** — never main — against current upstream, so a deployed card
gets base-image and Fedora security fixes without anyone cutting a feature
release. It skips the week if the base image digest has not moved, and releases
anyway if it cannot tell.

It builds nothing itself: it creates the tag and dispatches `build.yml` on it,
so there is one implementation of "cut a release". A tag pushed with
`GITHUB_TOKEN` deliberately triggers no workflow; `workflow_dispatch` is the
documented exception, which is why the dispatch is explicit.

This is the one automatic path to a device, and it is safe for three reasons
that must all stay true: the source is a commit that was already released, the
devices run `AutomaticUpdatePolicy=stage` so nothing applies without a reboot
the owner chooses, and `bootc rollback` covers the reboot that goes wrong.
Tiers 0, 1 and 1.5 run on it like any other release; hardware acceptance does
not, so a base-image regression that breaks the boot chain would reach cards.
That is the residual risk, and it is the reason the rebuild is scoped to
released source only.

If a release ever surprises us, the next lever is pinning: the base digest is
already recorded on every image as
`org.opencontainers.image.base.digest`, so a release could be built against the
exact base a tested build used. Deliberately not done, because it would also
freeze what the nightly rebuild exists to pick up.

## Rules

- **Nothing reaches main unless the owner asks for it.** Work on a branch, open
  a PR, test on hardware, and then *wait*. A merge is not implied by green CI,
  by a finished-looking change, by permission to touch the hardware, or by any
  instruction that mentions `:testing` — `:testing` is a consequence of merging,
  not a reason to merge. If no release is being prepared, there is nothing to
  merge for. Ask, and take silence as no.
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
  in as `core`, configure in place. No build-time settings and no per-device
  state in this repo. Per-device Ignition rendering and the first-boot rebase
  were deleted, not deprecated, and stay dead.

  `pi-core.conf` + `pi-core-provision` came back deliberately (R20), because a
  machine going into a rack may never see a console. It is bounded by R2 and
  that bound is the whole design: **no file, an empty file, or a file of
  comments must leave the machine exactly as it would have been**, the shipped
  template has every value blank, and a key that fails costs that setting
  rather than the boot. If a change would make the image *depend* on the file,
  it is the wrong change.
- **Enablement applies at install, not at upgrade.** A preset is evaluated when
  the deployment's `/etc` is generated, so a unit added in a new image arrives
  *disabled* on a machine that upgrades into it, and a changed `WantedBy=` does
  not take effect either. A fresh flash is unaffected. When testing on a
  machine that has upgraded, `systemctl reenable <unit>` reproduces what an
  install would have done — this has caught two changes out already.
- **What Ignition used to provide, the image must.** The `core` user comes from
  `sysusers.d` (a bare `/etc/passwd` entry fails `bootc container lint`) and
  root growth from `pi-core-growfs.service`, because Fedora CoreOS only grows
  the root on an Ignition firstboot. Both are asserted in tier 1.
- **One image for every model.** There are no per-model builds and no build-time
  model switches, and there should never be. Per-model behaviour is allowed only
  through files the *firmware* selects — the `[pi3]`/`[pi4]`/`[pi5]` sections of
  `config.txt`, and the device trees it picks by board revision. The Pi 5 device
  tree replacement lives there for exactly that reason; a build that branched on
  the model instead would be the wrong shape.
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

Runs on a Raspberry Pi 4 and a Pi 5 Model B. A flashed card boots to a login
and a working network unattended, `bootc upgrade` applies a new image in about
20 seconds and reboots into it, `bootc rollback` returns to the previous
deployment and back again, the root filesystem grows to fill the card,
`<hostname>.local` resolves, and upgrades verify our cosign signature. Builds,
lints clean, publishes and signs.

A flashed release image has been through the whole cycle on a Pi 5 Model B
(D0): download, flash, unattended boot, network, root growth to fill the card,
tier 3 18/18. The root filesystem grew from the 5.5 GB image untouched on a
first boot, which closes the last standing doubt about that path.

The Pi 5 took two device-tree fixes to get there, and what remains is one gap
that is upstream's: no thermal zones, so no fan control and no temperature
reading. C0 silicon is **not** supported, and Pi 500 / CM5 are not covered.
`docs/requirements.md` §8 has the detail, `docs/pi5.md` the mechanism and the
silicon-stepping trap. Shipping the RP1 drivers was never the hard part.

Not yet proven, and worth saying so rather than implying otherwise:

- **A Pi 4 on anything recent.** The reference board last booted an image from
  early September; its card was repurposed for the Pi 5 work and never flashed
  back. Every file a Pi 4 *reads* is byte-identical to v1.20260928, and tier 1
  fails if the Pi 4 device tree is ever replaced, so the boot chain is sound by
  construction — but nothing above it has been exercised on that board in
  weeks, and it is the model this project calls its reference path.

- **Installation is unsigned, and stays that way.** `bootc upgrade` verifies
  our cosign signature (proven on hardware, with negative controls). `bootc
  install` never verifies: it installs from local containers-storage, which it
  trusts by construction, so the flag that used to be there was a no-op.
  `SHA256SUMS.sig` on the release is what a downloader checks instead.

`docs/hardware-acceptance.md` is the checklist. Six behaviours that Fedora
CoreOS provides during an Ignition firstboot had to be reimplemented for
`bootc install`, each found by a failed boot: see `docs/design-decisions.md`
before assuming anything in that area is incidental.