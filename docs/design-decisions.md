# Design decisions

Why the code looks the way it does. Short and durable by intent — point-in-time
research and deployment planning are deliberately kept out of this repo, since
they go stale on a different clock than the code.

## A pre-rebased image, not an installer

`scripts/build-image.sh` runs `bootc install to-disk` to deploy the pi-core
container straight onto the disk image. A flashed card boots the finished
system: one boot, no rebase, nothing downloaded.

This replaced an earlier model where we shipped stock Fedora CoreOS plus an
Ignition config that pulled the pi-core container on first boot and rebased
onto it. That was chosen because it was the only Pi path Fedora documented, it
kept customisation in a Containerfile, and it avoided an unproven question
about whether Ignition behaves on a disk produced by something other than
`coreos-installer`.

The first boot on real hardware is what settled it. The rebase made first boot
depend on the network, the clock and a registry, and all three are things a
Raspberry Pi is bad at on day one: it has no battery-backed clock, so it woke
up in the past and every TLS handshake to ghcr.io failed "certificate is not
yet valid". Worse, everything that made the machine *reachable* — password SSH,
the mDNS responder — arrived with the image the rebase had failed to pull, so
a failure left no way in at all.

Installing the image at build time removes that entire class of failure by
construction, and with it the autorebase unit, the `chrony-wait` ordering, the
Ignition config, and the two-reboot dance.

It costs three things Ignition had been providing for free, all now build-time
and all asserted in `tests/image-assertions.sh`:

- the `core` user, declared in `sysusers.d` (a bare `/etc/passwd` entry trips
  `bootc container lint`);
- root filesystem growth, which Fedora CoreOS does in its initramfs but only on
  an Ignition firstboot — `pi-core-growfs.service` does it instead;
- `--target-no-signature-verification` at install time, because the image's own
  bootc config sets `enforce-container-sigpolicy` and the policy it ships does
  not yet carry our cosign key. Wiring that key in is the follow-up that lets
  the flag go away.

Customisation still lives in `Containerfile` + `build_files/build.sh`, and the
machine is still an ordinary bootc host that updates by pulling the same
container. Only the first boot changed.

## U-Boot, not an EDK2 chainloader

EDK2 makes a Pi look like a SystemReady server, so unmodified aarch64 images
boot. But its defaults need interactive firmware-menu changes — a 3 GB RAM cap
on Pi 4, and ACPI mode which hides GPIO. That is the wrong trade for a headless
machine. U-Boot's EFI layer has fewer moving parts and needs no console.

## `ucore-minimal`, not `ucore`

The full variant adds storage tooling including `mergerfs`, which has no aarch64
build. Minimal already carries what a Pi needs: bootc, docker+podman, tailscale,
firewalld.

Not cockpit: `/usr/share/cockpit` exists but `cockpit-ws` does not, so nothing
listens on :9090. That absence is load-bearing now — see below — and
`tests/image-assertions.sh` fails if `cockpit-ws` ever appears.

## Default credentials on the published image

The image on the releases page ships `core` / `core`, with SSH password
authentication enabled and nothing forcing a change. Stock Fedora CoreOS
disables password authentication; we re-enable it in
`10-pi-core-passwords.conf`, which has to sort before FCOS's
`40-disable-passwords.conf` because sshd takes the first value it obtains for a
keyword.

The point is an image that works with nothing but a flashed card — no serial
adapter, no per-device config, no key baked in for one person. That is what
DietPi and Raspberry Pi OS have always done, and it is the reason either is
usable by someone who owns one Pi and no lab.

What it costs, stated plainly: for as long as the owner leaves those credentials
alone, the machine accepts a password published in the release notes, from
anywhere on the LAN, and mDNS tells the LAN where to find it.

An earlier version expired the password so the first login had to replace it.
That was removed deliberately: whether `core` / `core` is acceptable is the
owner's judgement about their own network, and forcing the issue is exactly the
paternalism the DietPi model declines. What remains is narrower and does not
override that decision:

- `cockpit-ws` is absent, so there is no browser-shaped second front door on
  :9090 — uCore enables password auth for localhost, which a web login would
  otherwise turn into a remote credential;
- the risk is documented in the release notes and in INSTALL.md, where someone
  about to flash it will read it, rather than buried here.

Someone who wants none of this changes the password, or adds a key and sets
`PasswordAuthentication no`, at the first login.

## The console mode is a karg, not a `config.txt` setting

The image caps the console at 1280x720 via `video=` kargs passed to
`bootc install`. On a Raspberry Pi the obvious place for this is `config.txt`,
which sits on the FAT partition where anyone can edit it before first boot.
That does not work here, and the reason is worth recording so it is not tried
again:

- Fedora's `config.txt` sets `kernel=rpi-u-boot.bin`, so the firmware boots
  U-Boot, not Linux. `cmdline.txt` is only read when the firmware boots a
  kernel directly.
- `disable_fw_kms_setup` — the setting that governs firmware display setup —
  works by having the firmware *append `video=` to the kernel command line*.
  GRUB builds that line itself from the BLS entry. Measured on a running Pi 4,
  `/proc/cmdline` and the device tree's `/chosen/bootargs` are byte-identical
  and both contain GRUB's `BOOT_IMAGE=(hd0,gpt3)…`, so GRUB is what writes
  `/chosen/bootargs`. Anything the firmware passed to U-Boot is gone by then.
- `vc4-kms-v3d` reads EDID from the display over I2C rather than taking the
  firmware's word for it, so `framebuffer_width` and `hdmi_mode` do not reach
  the kernel's mode selection either.

The adjustment path is therefore `rpm-ostree kargs --replace=…` after login,
which is consistent with everything else about this image being configured
after first boot. A FAT-editable knob would mean a first-boot service reading a
file off the ESP and rewriting kargs — the pre-boot configuration mechanism
this project deliberately deleted.

## mDNS, reversing an earlier decision

The image runs `avahi-daemon` and opens `mdns` in the firewall's default zone,
so `<hostname>.local` resolves. This repo previously asserted the opposite — the
image test failed if avahi appeared, because INSTALL.md promised `.local` would
not resolve.

It changed for the same reason as the default password: an image handed to
someone else has to be findable without reading a DHCP lease table off a router
they may not administer. The assertion was inverted rather than deleted, so
losing the responder now fails the build.

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

## One install path, configured after login

The only supported install is: download the published image, flash it, boot it,
log in as `core`. There is no build-time configuration, nothing to edit on the
card, and no per-device state anywhere in this repository.

Two earlier mechanisms did that job and are gone:

- **`pi-core.conf` on the card's FAT partition**, read on first boot by
  `pi-core-provision`. It existed because Ignition cannot read a local file —
  its config is baked into the boot partition at install time and the spec
  (v3.5) fetches only from `http`, `https`, `tftp`, `s3`, `arn`, `gs` and
  `data`. (The `oem://` scheme that turns up in search results is Ignition
  v0.20, Container Linux era, long gone.) So it was a real solution to a real
  constraint — it was just solving a problem the published image does not have.
- **Per-device Ignition rendering**, which baked one person's SSH key into a
  config nobody else could use.

Both bought pre-boot configuration, and pre-boot configuration is precisely
what an image handed to a stranger cannot rely on. `hostnamectl`,
`authorized_keys` and `timedatectl` already do this after login, on a machine
that is by then an ordinary Fedora CoreOS host. Keeping a second, bespoke way
to do the same things meant two code paths, two sets of tests and two places
for the docs to drift.

The cost is that every machine arrives as `pi-core` and they collide over mDNS
until renamed. Renaming is one command, and anyone with two Pis will hit it
immediately.

## The owner is derived, never committed

`scripts/repo-owner.sh` resolves the GHCR namespace from `REPO_ORGANIZATION`,
`GITHUB_REPOSITORY_OWNER`, or the git remote. Hardcoding it meant a fork would
verify the upstream author's image instead of its own.

## The CI signing pins are one set

cosign v3.1.2 + cosign-installer v4.1.2 (SHA-pinned; there is no floating `v4`
tag) + `docker/login-action` (cosign reads `~/.docker/config.json`, which
`podman login` does not write). Changing any one of the three breaks signing —
see the comments in `.github/workflows/build.yml`.
