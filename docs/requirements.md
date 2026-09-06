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
- **R2 — Nothing may *depend* on pre-boot configuration.** A card flashed and
  booted with nothing edited reaches a login and a working network. No
  per-device values are baked at build time, and no setting may be one whose
  absence breaks the boot. Optional pre-boot configuration is allowed, and
  specified in R20; this requirement is what bounds it.
  *Verified: `tests/provision.sh` — an absent or empty config changes nothing.*
- **R3 — First boot must not need the network, a clock or a registry.** The
  image *is* the system, not an installer for it. A Pi has no battery-backed
  clock and may be offline; neither may prevent it reaching a login.
  *Verified: `tests/static.sh` fails if a first-boot rebase reappears;
  hardware acceptance §B.*
- **R4 — The root filesystem grows to fill the card.** Images are built to a
  fixed size and cards are not.
  *Verified: `tests/image-assertions.sh` (unit + preset); acceptance §B4.*
- **R5 — Any card of 8 GB or larger works**, on the models in §5.

- **R20 — Optional headless setup from a file on the card.** A machine destined
  for a rack or a shelf may never see a console, and reaching it as `core` /
  `core` over SSH means first discovering its address and then typing a
  password into a production host. So the flashed card carries an editable
  file — on the FAT partition any laptop can mount — that can set the hostname,
  authorise an SSH key, set the console password, the timezone, and join a
  wireless network. It is read once on first boot.

  The constraints are what make this compatible with R2, and they are the
  requirement as much as the feature is:

  - **Absent, empty or comment-only is the supported case.** The behaviour with
    no file is byte-for-byte today's behaviour.
  - **Every key is optional**, and an unknown or malformed one is reported and
    skipped, never fatal.
  - **The file is data, never code.** It is parsed against a key whitelist and
    never sourced, so a value cannot execute.
  - **A failing key must not fail the boot.** Each setting is applied
    independently; one bad value costs that setting, not the machine.
  - **Secrets do not stay on the card.** Values that are credentials are
    blanked after they are applied.

  *Verified: `tests/provision.sh` (tier 0, including that a value containing
  `$(...)` is not executed); `tests/image-assertions.sh` for shipping and
  enablement.*

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

### Updating

- **R16 — Updates are staged, never applied unattended.** The machine may fetch
  and stage a new deployment on its own; making it live is always a reboot the
  owner chooses. This is what makes an automatic release stream safe to point
  at a device at all.
  *Verified: `tests/hardware.sh`; `AutomaticUpdatePolicy=stage`.*
- **R17 — A staged update is announced at login, whoever staged it.** An update
  that waits silently for a reboot that never comes is not an update. The
  announcement must not depend on which tool did the staging.
  *Verified: `tests/image-assertions.sh` (path unit on the staged-deployment
  marker, preset enablement); proven on a Pi 4 for both `bootc` and
  `rpm-ostree` staging.*
- **R18 — Security fixes reach a device without a feature release.** Most of
  what a deployed card needs is upstream: a newer base image and newer
  packages. Waiting for pi-core to have something to say about it is the wrong
  gate.
  *Verified: `.github/workflows/weekly.yml`; `tests/static.sh` asserts it
  rebuilds released source only.*

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
- **R19 — An image says what it is and what it came from.** A digest is not an
  answer to "which build is this, and against what upstream". Both the release
  version and the base image digest are recorded on every image.
  *Verified: `tests/image.sh` asserts both labels.*

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

- **Pi 3, Zero 2 W** — they cannot boot this image at all, and RAM is the
  lesser reason. The BCM2837 boot ROM reads **MBR only**; it scans the first
  partition of an MBR table for `bootcode.bin`. `bootc install to-disk` writes
  GPT, so the ROM finds nothing and stops before the firmware, U-Boot or HDMI
  come up. Tested: a card that boots a Pi 4 put into a Pi 3B+ produced no
  output and never reached the network. The Pi 4 and Pi 5 EEPROMs handle GPT,
  which is why the same card works there.

  Everything *inside* the image is fine for a Pi 3 — the `bcm2837` device
  trees, `bootcode.bin`/`start.elf`, `arm_64bit=1`, the `[pi3]` config section
  and U-Boot's BCM2837 support all ship, and the boot entry pins no device
  tree. Supporting the model would mean a hybrid MBR on every built image; that
  is partition-table surgery of the kind that has already destroyed one image
  in this project, to reach a board with 1 GB of RAM. Deliberately not done.
- **Pre-boot configuration** — see R2.
- **Fleet management, provisioning servers, config management.** pi-core
  produces a host; what runs on it is not its concern.
- **A desktop.** No display manager, no graphical target.
- **NVMe boot on Pi 5** — under investigation, and the reason previously given
  here was wrong. The Pi's own firmware boots NVMe fine; the question is
  whether U-Boot can carry on from it. Our shipped U-Boot 2026.04 *does*
  contain the `brcm,bcm2712-pcie` compatible and the `nvme` commands, but
  `boot_targets` is `mmc usb pxe dhcp`, so nothing scans NVMe automatically.
  Whether the controller probes, and whether the NVMe-over-PCI transport is
  built in at all, is untested.

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

The hardware run must be against **the image the release publishes**, not the
`:testing` image that preceded it. A version tag rebuilds its commit, and the
base image and Fedora packages float, so the two are different artifacts even
though the source is identical.

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
- **The Pi 5 has never booted pi-core.** Everything in the image is
  model-agnostic and the firmware ships for it, but no Pi 5 has run it, so the
  RP1 southbridge binding that ethernet and USB depend on is unproven.
- **Rebasing an existing Fedora CoreOS host onto pi-core is untested and
  probably broken.** The image's `/etc/fstab` assumes `bootc install`'s
  two-partition layout, and on a `coreos-installer` install the same entry
  stops the boot partition being mounted. Supporting it would mean binding
  `/boot` from a generator that checks for a `boot`-labelled filesystem rather
  than from fstab. R1 says one install path, so this is recorded rather than
  planned.
