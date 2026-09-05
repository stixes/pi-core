# Installing pi-core on a Raspberry Pi

Download an image, flash it, boot it, log in. That is the whole install, and it
is the only one supported: there is no build-time configuration and nothing to
edit on the card. Everything about a machine is set after you log into it.

## Supported models

| Model | Status | Notes |
|---|---|---|
| **Pi 5 / 500** | primary target | **SD card only** — see storage below. Serial console differs (§7) |
| **Pi 4 / CM4 / 400** | supported | The model Fedora CoreOS documents; boots from USB too |
| Pi 3 / Zero 2 W | not a target | Firmware and DTBs ship, but 1 GB (or less) RAM is below what FCOS plus containers wants. May work; untested, unsupported |

> **Untested on hardware.** Every step below is derived from the Fedora CoreOS
> Raspberry Pi 4 documentation and from what the built image actually contains,
> but no one has run it end to end on a real Pi yet. Expect to debug.

## 0. What you need

- A Raspberry Pi 5 or 4
- SD card, 16 GB or more — plus a second, throwaway card for the EEPROM update
- A card reader, and any imaging tool: Raspberry Pi Imager, balenaEtcher,
  Rufus, or `dd`
- **Recommended: a USB-to-serial (3.3 V TTL) adapter.** If the Pi fails before
  networking comes up, this is the only way to see why.

You do not need this repository, or podman, or `just`. Those are for building
the image, not installing it.

### Storage

ostree deployments are write-heavy and none of this is write-tuned, so an SD
card will wear out faster than you would like.

- **Pi 4:** prefer an SSD over USB. It boots from USB with a current EEPROM.
- **Pi 5: SD card only.** U-Boot 2026.04 has no BCM2712 PCIe support, so NVMe
  is not a boot option, and USB boot is not working in Fedora's Pi 5 support
  either. Use a good endurance-rated card and expect to replace it.

## 1. Update the Pi's EEPROM (one-time, per Pi)

**This is not optional.** Older EEPROMs cannot read the FAT16 EFI partition that
Fedora CoreOS creates, and the Pi will simply not boot.

Flash the Raspberry Pi *bootloader* image to the throwaway card (Raspberry Pi
Imager → Misc utility images → Bootloader → SD Card Boot), put it in the Pi,
and power on. The activity LED flashes rapidly and the screen goes green when
the update is done — roughly ten seconds. Power off and remove the card.

## 2. Flash the image

Download `pi-core-*.img.xz` from the [releases page](../../releases) and write
it to the card. Raspberry Pi Imager: "Use custom", pick the file. Rufus needs
DD/raw mode. Or:

```bash
xzcat pi-core-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Check the download first if you like — `cosign.pub` is in this repository:

```bash
cosign verify-blob --key cosign.pub --signature SHA256SUMS.sig SHA256SUMS
sha256sum -c SHA256SUMS
```

## 3. First boot

Put the card in the Pi and power on. Then wait — the Pi does a lot here:

1. **20–30 seconds of nothing.** No output at all. This is normal.
2. U-Boot starts, GRUB appears, Fedora CoreOS boots.
3. Ignition applies the built-in config.
4. `pi-core-autorebase.service` pulls `ghcr.io/<owner>/pi-core:stable` and
   reboots. **This downloads a multi-gigabyte image** — on a slow card and a
   slow link it can take a long while. The Pi looks idle; it is not.
5. The Pi comes back up running pi-core.

The whole sequence is two reboots. Do not pull the power because it seems stuck;
watch the serial console if you want to see what it is actually doing.

The root filesystem grows to fill the card on that first boot.

## 4. Log in

```
user: core
password: core
```

That is the login for every pi-core machine, and it stays that way until you
change it.

At the console with a monitor and keyboard, or over SSH once it has an address:

```bash
ssh core@pi-core.local
```

mDNS is best-effort: some networks block multicast, and a few consumer APs drop
it between wireless and wired clients. If `.local` does not answer, get the
address from your router's DHCP lease table and `ssh core@<address>` — nothing
else depends on mDNS.

## 5. Recommended next steps

Nothing here is enforced; the machine is a working Fedora CoreOS host as it
stands.

- Change the password — `passwd`.
- Add your SSH key to `~/.ssh/authorized_keys`.
- Once that key works, set `PasswordAuthentication no` in
  `/etc/ssh/sshd_config.d/10-pi-core-passwords.conf` and restart `sshd`.
- Give it its own hostname — every pi-core arrives as `pi-core` and they
  collide over mDNS.
- Set the timezone, and bring up tailscale if you use it.

## 6. Day-to-day

```bash
sudo bootc upgrade          # pull a new image; applies on reboot
sudo systemctl reboot

sudo bootc rollback         # go back to the previous deployment
```

Updates are staged automatically by `rpm-ostreed-automatic.timer` and take
effect when you reboot.

**Firmware is separate and manual.** `bootc upgrade` does not touch the Pi
firmware, device trees or U-Boot — `bootupd` only manages `/boot/efi/EFI`, while
the Pi needs its files at the root of the EFI partition. Each image carries a
copy, and `pi-core-firmware-check.service` reports drift into the journal at
boot. When you want to update it:

```bash
sudo pi-core-firmware sync
sudo systemctl reboot
```

This is deliberately not automatic: a bad firmware write bricks the boot and
there is no rollback for it. Your `config.txt` is preserved.

## 7. Serial console

Worth wiring up before you need it — **and the wiring differs by model.** This
is not interchangeable; the device trees disagree about which UART is the
console:

| Model | DTB `stdout-path` | Connect to | Kernel console |
|---|---|---|---|
| **Pi 5 / 500** | `serial10` | the dedicated 3-pin **debug UART connector** (next to the USB-C socket) | `ttyAMA10` |
| **Pi 4** | `serial0` | GPIO header: GND pin 6, adapter RX to pin 8 (GPIO14/TX), adapter TX to pin 10 (GPIO15/RX) | `ttyAMA0` |

Do **not** connect the adapter's 5 V line. Then:

```bash
screen /dev/ttyUSB0 115200      # or: picocom -b 115200 /dev/ttyUSB0
```

`enable_uart=1` is already set in Fedora's `config.txt`, and U-Boot reads
`stdout-path` from the firmware-provided device tree, so it passes the right
console through to the kernel without extra configuration.

## 8. If it goes wrong

| Symptom | Likely cause |
|---|---|
| No output at all, ever | EEPROM not updated (step 1) |
| Rainbow screen, then nothing | Firmware loaded but `rpi-u-boot.bin` is missing or unreadable |
| Boots FCOS but no login | Ignition failed — check the serial console |
| Login works, still plain uCore | Rebase failed; `journalctl -u pi-core-autorebase.service` |
| `core` / `core` rejected | You already changed it — try the console, or your own password |
| `.local` does not resolve | Multicast blocked on that network; use the DHCP lease address |
| Nothing on serial, Pi 5 | Wrong UART — Pi 5 uses the debug connector, not GPIO 14/15 (§7) |
| Pi 5 will not boot from USB/NVMe | Expected; Pi 5 is SD-only here |

Boot chain, for orientation:

```
EEPROM -> config.txt (kernel=rpi-u-boot.bin) -> U-Boot -> U-Boot EFI
       -> GRUB -> BLS entry -> ostree deployment
```
