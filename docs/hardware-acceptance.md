# Hardware acceptance checklist

The automated tiers (`just test`, `just test-supply-chain`) prove the image is
*well-formed*. They cannot prove it **boots**: the chain from EEPROM through
`config.txt`, U-Boot, GRUB and into the ostree deployment is exercised only on
real hardware. This checklist is that gate.

Run it end to end on the first hardware attempt, and again whenever the base
image, kernel, firmware payload or boot configuration changes.

> This checklist has itself never been run. Expect to correct it on first use —
> that is part of the first run's output.

## Before you start

Attach the **serial console** (INSTALL.md §8). It is not optional for
acceptance: checks A1–A3 are invisible without it, and a failure before
networking leaves no other evidence.

**Check you are on the right UART for the model** — Pi 5 uses the dedicated
debug connector (`ttyAMA10`), Pi 4 uses GPIO 14/15 (`ttyAMA0`). Silence on the
wrong one looks exactly like a dead board.

Log the whole session to a file so a failure is diagnosable afterwards:

```bash
screen -L -Logfile boot-$(date +%Y%m%d-%H%M).log /dev/ttyUSB0 115200
```

Record the baseline before powering on:

| Field | How |
|---|---|
| Pi model + board revision | printed on the board / `cat /proc/cpuinfo` later |
| Which UART was used | debug connector (Pi 5) or GPIO header (Pi 4) |
| Boot medium | SD card or USB SSD, make and size |
| EEPROM version | shown during the update in INSTALL.md §1 |
| Image digest | `skopeo inspect docker://ghcr.io/<owner>/pi-core:stable \| jq -r .Digest` |
| Card written at | timestamp |

---

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

## B. First-boot provisioning

- [ ] **B1** Ignition ran without error —
      `journalctl -b 0 -u ignition-files.service -u ignition-fetch.service`
      shows no failures.
- [ ] **B2** The `core` user exists with your key, and `/etc/hostname` is what
      you set.
- [ ] **B3** `systemctl is-enabled zincati.service` reports `masked`.

## C. Autorebase

This is the step with the longest silent stretch — it pulls a multi-gigabyte
image. Do not intervene early; watch the unit rather than the screen.

- [ ] **C1** `journalctl -u pi-core-autorebase.service` shows the rebase
      starting.
- [ ] **C2** The machine reboots on its own and comes back up.
- [ ] **C3** `/etc/pi-core-autorebase/done` exists and the unit is now disabled
      (it must not run on every boot).

Record: wall-clock time for the pull, and the link speed if known.

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
| A1 | EEPROM not updated; the firmware never reached the ESP (card flashed inside a container?); or, on Pi 5, the wrong serial connector |
| A2 | `rpi-u-boot.bin` absent or misnamed — `config.txt` must say `kernel=rpi-u-boot.bin` |
| A3 | GRUB/BLS missing — the FCOS install itself did not complete |
| A4–A5 | Kernel or initramfs problem; capture the full serial log |
| B | Ignition rejected the config — usually a malformed SSH key |
| C | Network, or the image is not anonymously pullable (`just test-supply-chain`) |
| F3 | Bootloader state is not surviving the rollback — stop and investigate before deploying anything |
