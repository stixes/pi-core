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

### What Ignition was quietly doing

The image's `/usr/lib/bootc/install` config comes from Fedora CoreOS, and it is
written on the assumption that an Ignition firstboot follows the install. It
does not here, so six behaviours had to be reimplemented. Every one of them was
found by a Pi that failed to boot, and none is incidental — each is asserted in
`tests/image-assertions.sh` so removing it fails the build rather than a
machine.

- **`/var` is bound from the stateroot** by `/etc/fstab`. The deployment root
  is composefs and immutable, so an unmounted `/var` sends every write to a
  read-only filesystem: no `/var/home`, and NetworkManager cannot start.
- **`/boot` is bound from `/sysroot/boot`** by the same file. That entry also
  stops `coreos-boot-mount-generator` inventing a mount for `LABEL=boot`, which
  cannot exist in bootc's two-partition layout — it hangs on the device
  timeout and takes `local-fs.target` down with it.
- **Units are enabled by a preset**, `10-pi-core.preset`. `systemctl enable`
  writes under `/etc`, and the deployment's `/etc` is regenerated from presets
  at install time, so a build-time enable is silently dropped. Zincati is
  masked in `/usr` for the same reason.

  The corollary bites when testing: that regeneration happens at *install*, so
  a machine that upgrades into a new image does not pick up newly-enabled units
  or a changed `WantedBy=`. It is correct on a fresh flash and stale on an
  upgraded machine. `systemctl reenable <unit>` reproduces the install
  behaviour, and is what to reach for before concluding a unit does not work.
- **The hostname is set by a unit**, not shipped as `/etc/hostname`: podman
  bind-mounts that path during a build and it never reaches the image. It
  writes `/proc/sys/kernel/hostname` too, because systemd reads the file in
  PID 1 long before the unit runs, and avahi would otherwise publish
  `linux.local` for the whole first boot.
- **The root filesystem is grown** by `pi-core-growfs.service`, through `/var`
  rather than `/sysroot`: ostree's `prepare-root.conf` sets
  `[sysroot] readonly = true`, so growing through `/sysroot` fails with
  `XFS_IOC_FSGROWFSDATA … Read-only file system` while the partition resizes
  anyway — which looks exactly like success.
- **`bootuuid.cfg` is stamped onto the ESP** by `build-image.sh`. GRUB's stub
  config looks for a `BOOT_UUID` and otherwise searches for a filesystem
  labelled `boot`; Fedora CoreOS skips writing it because a CoreOS install
  regenerates its UUIDs, and nothing labels a partition `boot` here. Without
  it GRUB reaches a rescue prompt.

Two further install-time details:

- **`--filesystem xfs`** must be passed: the image declares mount specs but no
  root filesystem type, because `coreos-installer` never needed bootc to know.
- **`--target-no-signature-verification`**, because the image's bootc config
  sets `enforce-container-sigpolicy` and the policy it ships carries no entry
  for our cosign key. The image is verified out of band instead. Wiring the key
  into `policy.json` is the outstanding follow-up, and it matters for
  `bootc upgrade` on the device as much as for install.

The ESP firmware is copied out of the image's own stash rather than downloaded
again, so what `pi-core-firmware check` compares are two copies of the same
thing. Downloading separately meant the ESP got stock Fedora files while the
image carried customised ones, and the check reported drift on every fresh
install by construction.

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
after first boot.

### The open experiment

Because config.txt is where a Pi user looks first, the image now ships with
`disable_fw_kms_setup=1` commented out and `framebuffer_width`/`_height` set to
1280x720, *and* keeps the `video=` kargs. The prediction above says this will
change the U-Boot and GRUB screens and leave the kernel console alone. To find
out which actually wins, on a booted machine:

```bash
sudo rpm-ostree kargs \
    --delete=video=HDMI-A-1:1280x720@60 \
    --delete=video=HDMI-A-2:1280x720@60
sudo systemctl reboot
```

Then check `cat /sys/class/drm/*-HDMI-A-1/modes | head -1`. Still 1280x720
means config.txt reached the kernel and the kargs can go. Panel-native means
the prediction held and the kargs are the only lever. Worst case is a console
that does not come up at all, if the firmware's mode and `vc4-kms-v3d`
disagree — SSH is unaffected, and re-adding the kargs undoes it.

A FAT-editable knob for *arbitrary* settings — a `dietpi.txt`-style file read
on first boot — is a bigger idea and is deliberately not here yet. It would
mean a first-boot service parsing a file off the ESP, which is the pre-boot
configuration mechanism this project removed once already. Worth revisiting
only if custom hardware turns out to be a real user problem rather than a
hypothetical one.

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
  boot path and the RP1 southbridge are both present. NVMe is unresolved: the
  Pi's own firmware boots it, but `boot_targets` is `mmc usb pxe dhcp`, so
  U-Boot never scans it. See requirements.md §5.
- **Pi 4** — the model Fedora CoreOS actually documents; kept as the reference
  path.
- **Pi 3 / Zero 2 W** — cannot boot the image, which is a firmer reason than
  the RAM one recorded here first. The BCM2837 boot ROM reads MBR only and
  `bootc install to-disk` writes GPT, so the ROM never finds `bootcode.bin`.
  Tested: the card that boots the Pi 4 produced nothing at all in a Pi 3B+.
  Enablement was never the problem — the DTBs, firmware and `[pi3]` config all
  ship and the boot entry pins no device tree. A hybrid MBR on every build
  would fix it, and is not worth it to reach a 1 GB board.

  The lesson generalises: *the image* is model-agnostic, *the disk layout* is
  not. Both had to be checked and only one of them had been.

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
