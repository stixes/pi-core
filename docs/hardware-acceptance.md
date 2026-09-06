# Hardware acceptance checklist

The automated tiers (`just test`, `just test-supply-chain`) prove the image is
*well-formed*. They cannot prove it **boots**: the chain from EEPROM through
`config.txt`, U-Boot, GRUB and into the ostree deployment is exercised only on
real hardware. This checklist is that gate.

It runs in two halves, because the machine cannot check itself until you can
reach it:

- **Part 1 — manual, at the machine.** Monitor and keyboard. You watch the boot
  and record what happened. Nothing can be scripted here; if the boot chain
  fails there is no shell to run a script in.
- **Part 2 — automated, over SSH.** Once you can log in: `just test-hardware
  <host>` runs the assertions and prints pass/fail.
- **Part 3 — manual again.** Update and rollback, because it reboots the
  machine out from under you.

Run it end to end on the first hardware attempt, and again whenever the base
image, kernel, firmware payload or boot configuration changes.

## Before you start

### Pick an observation channel

You need *some* way to see what the machine is doing. In order of usefulness:

| Channel | Sees | Needs |
|---|---|---|
| **Serial console** | everything, including firmware and U-Boot | USB-TTL adapter; Pi 5 also a JST-SH cable for the debug connector |
| **HDMI + USB keyboard** | firmware splash, U-Boot, GRUB, and the kernel **from the second boot onward** | a monitor, and a console password (below) |
| **Network + post-mortem** | only that it reached userspace; failures reconstructed afterwards from the card | nothing extra |

Serial remains the best option and a USB-TTL adapter is cheap insurance, but
**acceptance is runnable without one.** If you have no serial console, do both
of the following or you will be debugging blind:

1. **Use the console login.** The image ships `core` / `core`, so a machine
   that boots but never reaches the network can still be logged into with a
   monitor and keyboard.

2. **Keep a monitor attached from power-on.** Note the kernel only logs to HDMI
   the console is capped at 720p and `console=tty0` is set by
   `scripts/build-image.sh` as install-time kargs, so an attached monitor
   should stay alive all the way through.

### What you cannot see without serial

Checks **A1–A2** (firmware start, U-Boot banner) are only partially observable
on HDMI, and the window between GRUB and userspace is dark on first boot. If
the machine fails there, fall back to bisection rather than guessing:

- Does a stock Raspberry Pi OS card boot on this Pi? → isolates the board and
  the EEPROM.
- Does the pi-core card enumerate on the network at all? → separates a dead
  boot chain from a dead network.

### Post-mortem from the card

When a boot fails after the kernel starts, power off, move the card to your
workstation and read what it left behind — this recovers most of what a serial
console would have shown:

```bash
sudo mount /dev/sdX4 /mnt        # the root partition
sudo journalctl -D /mnt/ostree/deploy/*/var/log/journal -b -1 --no-pager | tail -100
sudo ls /mnt/ostree/deploy/*/var/lib/       # did the deployment land?
```

Check the partition number with `lsblk -f`; the root filesystem is labelled
`root`. Nothing is written there before the kernel mounts it, so a failure at
A1–A3 leaves no trace on disk — that is the case serial exists for.

Record the baseline before powering on:

| Field | How |
|---|---|
| Pi model + board revision | printed on the board / `tr -d '\0' < /proc/device-tree/model` later |
| Which UART was used | debug connector (Pi 5) or GPIO header (Pi 4) |
| Boot medium | SD card or USB SSD, make and size |
| EEPROM version | `vcgencmd bootloader_version`, or the date shown by the bootloader update |
| Image digest | `skopeo inspect docker://ghcr.io/<owner>/pi-core:stable \| jq -r .Digest` |
| Card written at | timestamp |

---

# Part 1 — manual, at the machine

Monitor and keyboard attached before power-on. You are the instrument here:
note what appears and when, because none of it is recoverable afterwards.

## A. Boot chain

The part nothing else can test. Watch the serial console.

- [ ] **A1** Firmware starts and reads `config.txt` — any output at all within
      ~30 s of power-on.
- [ ] **A2** U-Boot banner appears. *(If A1 passes but A2 never does,
      `rpi-u-boot.bin` is missing or unreadable on the ESP.)*
- [ ] **A3** GRUB menu / countdown appears, then a BLS entry is selected.
- [ ] **A4** Kernel boots — console shows kernel messages, not a hang.
- [ ] **A5** systemd reaches a login prompt.

Record: seconds from power-on to A1, and to A5.

**Pi 5 specifics.** The Pi 5 path is less travelled than the Pi 4 one, so treat
these as live questions rather than assumptions:

- [ ] **A6** (Pi 5) Ethernet and USB work — both hang off the RP1 southbridge,
      so `rp1_pci` loading is the thing being tested. `ip link` and `lsusb`.
- [ ] **A7** (Pi 5) Record whether thermals/fan behave; fan control was still
      incomplete in Fedora's Pi 5 support and may simply be absent.

## B. First boot and login

- [ ] **B1** The machine reaches a login prompt without an install step. There
      is no rebase and no second reboot: `bootc status` should already name
      `ghcr.io/<owner>/pi-core:stable`.
- [ ] **B2** Logging in at the console as `core` / `core` works and gives a
      shell.
- [ ] **B3** `systemctl is-enabled zincati.service` reports `masked`.
- [ ] **B4** The root filesystem filled the card — `df -h /sysroot` should show
      the card's size, not the image's. If not:
      `journalctl -u pi-core-growfs.service`. Part 2 measures this again
      against the partition size; the eye check here is what catches it before
      SSH exists.
- [ ] **B5** `avahi-daemon` is running and `pi-core.local` resolves from
      another machine on the same network. Record whether it needed the DHCP
      address instead — mDNS is best-effort and depends on the network.
- [ ] **B6** The machine accepts SSH as `core`. **This is the handover point** —
      from here on the checks are scripted.

## C. Updating

`bootc install` produces two partitions, an ESP and root, so `/boot` lives in
the root filesystem and has the whole card to grow into. The 384 MB boot
partition that once stranded an upgrade is gone with the installer model, and
the device trees are pruned to Broadcom besides.

- [ ] **C1** `sudo bootc upgrade` completes without "No space left on device".
- [ ] **C2** `df -h /boot` after staging — record the figure; two deployments
      should sit near 210 MB, not 350 MB.
- [ ] **C3** The machine reboots into the new deployment, and
      `sudo bootc rollback` returns to the previous one.

# Part 2 — automated, over SSH

Once **B6** passes, stop hand-checking and run:

```bash
just test-hardware <address>        # or user@host
```

It is read-only: no upgrade, no reboot, no firmware writes. It covers D and E
below and prints the observations worth recording (model, revision, kernel,
thermals, firmware drift). Hand-check anything it reports as `skip`.

The manual equivalents, for reference or when SSH is not available:

## D. Running the right thing

- [ ] **D1** `bootc status` names `ghcr.io/<owner>/pi-core:stable` — **not**
      `ucore-minimal`.
- [ ] **D2** The booted digest matches the one recorded in the baseline.
- [ ] **D3** `systemctl is-system-running` returns `running`, not `degraded`.
      If degraded: `systemctl --failed` and record every unit listed.
- [ ] **D4** SSH from another machine works using the DHCP-leased address.
- [ ] **D5** `docker info` succeeds and `tailscale version` runs.

Record: `uname -r`, and `cat /proc/cpuinfo | grep Revision`.

## E. Firmware tooling

- [ ] **E1** `pi-core-firmware check` runs and reports the ESP state. Straight
      after a fresh flash it should report a match (`config.txt` may differ if
      you customised it — that is expected and reported as such).
- [ ] **E2** `pi-core-firmware-check.service` ran at boot and its output is in
      the journal.

**Do not run `pi-core-firmware sync` as part of first acceptance.** There is no
rollback for a bad firmware write. Exercise it only once A–F have passed, when
there is genuine drift, and with the serial console attached.

# Part 3 — manual again

## F. Update and rollback

The safety net for everything else. If F3 fails, the machine is one bad image
away from a reflash, and it should not be trusted with a workload.

- [ ] **F1** `sudo bootc upgrade` completes (use a newer published build; if
      none, push a trivial change and let CI publish one).
- [ ] **F2** After `sudo systemctl reboot`, `bootc status` shows the new image
      as booted and the old one as rollback.
- [ ] **F3** `sudo bootc rollback` + reboot returns to the previous deployment,
      and the machine is fully functional there — re-check D1, D3, D4.
- [ ] **F4** Roll forward again so the Pi ends on the current image.

## G. Resilience (optional, recommended before real use)

- [ ] **G1** Pull the power while idle, restore it: the machine boots unaided.
- [ ] **G2** Pull the power **during** a staged update, restore it: the machine
      boots into a working deployment (either one).

G2 is the scenario an SD card and an unattended box will eventually produce on
their own.

---

## Verdict

**Accepted** = every box in A–F ticked. G is advisory.

Anything less is a partial result: record which check failed, the serial log,
and the relevant `journalctl` output. A failure at A2 or A3 means the boot
chain is wrong and no amount of image work will help.

Record the outcome somewhere durable — the run is only useful if the next
person can compare against it.

## If it fails

| Stopped at | Look at first |
|---|---|
| A1 | The firmware never reached the ESP (built inside a container?); on Pi 5, the wrong serial connector; or, on an old board, an EEPROM predating FAT16 ESP support |
| A2 | `rpi-u-boot.bin` absent or misnamed — `config.txt` must say `kernel=rpi-u-boot.bin` |
| A3 | GRUB/BLS missing — the FCOS install itself did not complete |
| A4–A5 | Kernel or initramfs problem; capture the full serial log |
| B | The deployment did not land; check the console and `bootc status` |
| C | Network, or the image is not anonymously pullable (`just test-supply-chain`) |
| F3 | Bootloader state is not surviving the rollback — stop and investigate before deploying anything |
