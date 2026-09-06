# pi-core — product requirements

What this image has to do, and how each requirement is checked. Written after
the fact, from behaviour that a real Pi either delivered or refused to.

This document is deliberately free of status. Whether a requirement currently
holds is recorded in CLAUDE.md's Status section and proven by
[hardware-acceptance.md](hardware-acceptance.md); *why* the code is shaped the
way it is belongs in [design-decisions.md](design-decisions.md).

## 1. Problem

A Raspberry Pi makes a good always-on container host, and a bad one to
administer. The usual images are mutable: state accumulates, upgrades are
in-place and irreversible, and a card that has been running for a year cannot
be reproduced. Fedora CoreOS solves that with an immutable, atomically-updated,
rollback-capable OS — but it does not boot on a Pi, because the Pi's boot ROM
is not UEFI and Fedora's aarch64 images assume it is.

pi-core is Fedora CoreOS made to boot on a Raspberry Pi, packaged so that
installing it is flashing one file.

## 2. Users

- **Primary: the owner**, running a small number of Pis as a personal homelab.
- **Secondary: anyone who downloads a release.** The repository is public and
  the image is published, so requirements are written for a stranger with one
  Pi, not for someone who has read the source.

Neither is assumed to have a serial adapter, a spare monitor, or a second
machine to prepare a card from.

## 3. Functional requirements

Each has an ID so tests and commit messages can name it.

### Installation

- **R1 — One install path.** Download the published image, write it to a card,
  boot. No second artifact, no installer step, no build required.
  *Verified: `tests/static.sh` asserts the image build uses `bootc install`.*
- **R2 — No pre-boot configuration.** Nothing to edit on the card, no config
  file, no per-device values baked at build time. An image handed to a stranger
  cannot depend on them, and two mechanisms that tried were removed.
  *Verified: no config parser exists; the Ignition path is gone.*
- **R3 — First boot must not need the network, a clock or a registry.** The
  image *is* the system, not an installer for it. A Pi has no battery-backed
  clock and may be offline; neither may prevent it reaching a login.
  *Verified: `tests/static.sh` fails if a first-boot rebase reappears;
  hardware acceptance §B.*
- **R4 — The root filesystem grows to fill the card.** Images are built to a
  fixed size and cards are not.
  *Verified: `tests/image-assertions.sh` (unit + preset); acceptance §B4.*
- **R5 — Any card of 8 GB or larger works**, on the models in §5.

### Reachability

- **R6 — Usable with nothing but the flashed card.** A default account exists,
  SSH accepts a password, and the host answers mDNS, so a headless Pi can be
  reached over the network on its first boot with no prior setup.
  *Verified: `tests/image-assertions.sh` — user, sshd drop-in, avahi, firewall.*
- **R7 — The console is legible** on 1080p, 1440p and 4K panels without
  configuration, and stays alive from firmware through to userspace.
  *Verified: `tests/static.sh` asserts the console kargs.*
- **R8 — A failure to reach the network must still leave a way in.** The
  console login is that way, and it must not depend on anything the network
  provides.

### Operation

- **R9 — Configuration happens after login**, with ordinary Fedora CoreOS
  tooling — `hostnamectl`, `authorized_keys`, `timedatectl`, `rpm-ostree kargs`.
  pi-core adds no configuration mechanism of its own.
- **R10 — Updates are atomic and reversible.** `bootc upgrade` stages a new
  deployment; the previous one remains bootable. An update must never leave a
  half-applied system.
  *Verified: acceptance §C; rollback exercised on a Pi 4 in both directions.*
- **R11 — An update must not be able to exhaust `/boot`.** Staging a second
  deployment alongside the first is the normal case, not an edge case.
  *Verified: `tests/image-assertions.sh` bounds the device-tree payload.*
- **R12 — Pi firmware updates are explicit, never automatic.** `bootc` does not
  manage the Pi's firmware, and a bad firmware write bricks a board with no
  rollback. Drift is reported; applying it is a deliberate command.
  *Verified: `tests/image-assertions.sh`; `pi-core-firmware check`.*

### Supply chain

- **R13 — The published container image is signed** and pullable with no
  credentials, because the device pulls it unauthenticated.
  *Verified: `tests/supply-chain.sh`.*
- **R14 — The published disk image is verifiable** before it is flashed, by
  someone who has only the release page.
  *Verified: signed `SHA256SUMS` accompanies every release.*
- **R15 — Nothing carries an owner.** A fork publishes and verifies its own
  image without edits.
  *Verified: `tests/static.sh` fails on a hardcoded owner anywhere in the
  image; `scripts/repo-owner.sh` derives it.*

## 4. Non-functional requirements

- **N1 — Honest reporting.** "Tests pass" is not "it works". Claims about
  hardware behaviour are only made once hardware has made them true, and the
  status section says which is which.
- **N2 — Failures must be visible.** A step that cannot do its job fails
  loudly and retries, rather than recording success. This is a requirement
  because the opposite shipped: a filesystem that never grew, on a machine
  that reported no errors.
- **N3 — Every checkable claim in the docs has an assertion.** A promise
  without a test is a promise that rots.
- **N4 — One way to do each thing.** Two mechanisms for the same job means two
  code paths, two test matrices, and docs that disagree.
- **N5 — Build-time failure is preferred to first-boot failure.** A broken
  build costs minutes; a broken first boot costs a reflash on hardware that may
  not be on the same continent.

## 5. Scope

**In scope**

| Model | Status |
|---|---|
| Pi 5 / 500 | Primary target. SD card only |
| Pi 4 / CM4 / 400 | Supported. SD or USB |

aarch64 only, asserted at build time.

**Out of scope, deliberately**

- **Pi 3, Zero 2 W** — 1 GB of RAM or less is below what Fedora CoreOS plus
  containers wants. The firmware and device trees ship anyway, because one
  package covers all models; that is not an endorsement.
- **Pre-boot configuration** — see R2.
- **Fleet management, provisioning servers, config management.** pi-core
  produces a host; what runs on it is not its concern.
- **A desktop.** No display manager, no graphical target.
- **NVMe boot on Pi 5** — U-Boot has no BCM2712 PCIe support.

## 6. Constraints

These are properties of the platform, not choices:

- The Pi's boot ROM is not UEFI, so firmware and U-Boot must be present at the
  root of the EFI partition — a path `bootupd` does not manage.
- The Pi has no battery-backed clock; the machine wakes up believing an
  arbitrary date until NTP corrects it.
- Fedora CoreOS's own tooling assumes an Ignition firstboot follows
  installation. Six behaviours it provides that way had to be reimplemented;
  see design-decisions.md before removing anything that looks redundant.
- The kernel's device-tree payload covers every aarch64 board Fedora supports
  and is copied into `/boot` per deployment.

## 7. Acceptance

A release is acceptable when tiers 0, 1 and 1.5 pass in CI, and a Pi has been
run through [hardware-acceptance.md](hardware-acceptance.md) with the result
recorded. The automated tiers cannot reach the boot chain; nothing but hardware
can close that gap.

## 8. Known gaps

Requirements not yet met. Which of them currently hold on hardware is tracked
in CLAUDE.md's Status section; this list is the requirement side of it, and the
two should not drift apart.

- **R13 does not extend to installation, and cannot.** `bootc upgrade` now
  verifies our cosign signature against the policy the image ships. `bootc
  install` never verifies one, by design rather than by omission: it installs
  from local containers-storage, which it treats as already trusted. The
  install is therefore only as trustworthy as whoever built the card, and the
  published `SHA256SUMS.sig` (R14) is what covers that instead.
- **The first upgrade after this shipped was itself unverified.** The upgrade
  that *delivers* a policy is evaluated under the previous one. Nothing can
  change that; it is noted so nobody reads a verified second upgrade as proof
  of the first.
- **Rebasing an existing Fedora CoreOS host onto pi-core is untested and
  probably broken.** The image's `/etc/fstab` assumes `bootc install`'s
  two-partition layout, and on a `coreos-installer` install the same entry
  stops the boot partition being mounted. Supporting it would mean binding
  `/boot` from a generator that checks for a `boot`-labelled filesystem rather
  than from fstab. R1 says one install path, so this is recorded rather than
  planned.
