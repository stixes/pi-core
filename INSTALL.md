# Installing pi-core on a Raspberry Pi

From a Pi and a blank SD card to a running, self-updating pi-core host.

## Supported models

| Model | Status | Notes |
|---|---|---|
| **Pi 5 / 500** | primary target | **SD card only** — see storage below. Serial console differs (§8) |
| **Pi 4 / CM4 / 400** | supported | The model Fedora CoreOS documents; boots from USB too |
| Pi 3 / Zero 2 W | not a target | Firmware and DTBs ship, but 1 GB (or less) RAM is below what FCOS plus containers wants. May work; untested, unsupported |

Everything below applies to Pi 5 and Pi 4 alike unless a step says otherwise.

Everything up to first boot happens on your workstation; the Pi is only powered
on twice.

> **Untested on hardware.** Every step below is derived from the Fedora CoreOS
> Raspberry Pi 4 documentation and from what the built image actually contains,
> but no one has run it end to end on a real Pi yet. Expect to debug.

## 0. What you need

- A Raspberry Pi 5 or 4
- SD card, 16 GB or more — plus a second, throwaway card for the EEPROM update
- A card reader on your workstation
- `podman`, `jq`, `rsync`, `just`, and `sudo` on the workstation
- **Strongly recommended: a USB-to-serial (3.3 V TTL) adapter.** If the Pi fails
  before networking comes up, this is the only way to see why.

### Storage

ostree deployments are write-heavy and none of this is write-tuned, so an SD
card will wear out faster than you would like.

- **Pi 4:** prefer an SSD over USB. It boots from USB with a current EEPROM;
  the procedure is identical, just point `DISK=` at the USB device.
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

## 2. Configure your install

```bash
git clone <this repo, or your fork>
cd pi-core

export PI_HOSTNAME=pi-core                       # optional, defaults to pi-core
export SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub     # optional, defaults to id_rsa.pub

just ignition
```

This renders `build/pi.ign`. It creates the `core` user with your key, masks
zincati, and installs the first-boot service that rebases onto
`ghcr.io/<owner>/pi-core:stable` — `<owner>` is derived from your git remote,
so a fork points at its own image automatically.

By default there is **no password login** — SSH key only, and if you lose the
key you reflash.

**Set a console password if you have no serial console.** Without one, a
machine that boots but never reaches the network cannot be logged into even
with a monitor and keyboard attached:

```bash
export PI_PASSWORD_HASH=$(just password-hash)
just ignition
```

## 2b. Headless setup via `pi-core.conf`

`just flash` leaves a **`pi-core.conf`** on the card's FAT partition — the one
your laptop mounts automatically. Edit it there, after flashing, before first
boot. This is the DietPi `dietpi.txt` idea: per-device settings live on the
card, so the same image and the same Ignition config serve every device.

```
PI_HOSTNAME=pi-core
PI_SSH_KEY=ssh-ed25519 AAAA... you@host
PI_PASSWORD_HASH=          # just password-hash
PI_TIMEZONE=Europe/Copenhagen
PI_TAILSCALE_AUTHKEY=
PI_WIPE_SECRETS=1
```

Every key is optional; an empty file changes nothing. Check what a card would
do before booting it:

```bash
just provision-dry-run /run/media/$USER/EFI-SYSTEM/pi-core.conf
```

Two caveats worth knowing:

- **It applies on the second boot**, not the first. The provisioner lives in
  the pi-core image, and the first boot is still stock Fedora CoreOS running
  the rebase. Anything needed to *reach* the network (so far: nothing, since
  this is ethernet-only) must still come from the Ignition config.
- **Secrets on the card are plaintext**, readable in any laptop. With
  `PI_WIPE_SECRETS=1` (the default) the password hash and tailscale key are
  blanked from the file once applied.

## 3. Flash the card

Find the device with `lsblk`, and be careful: **this erases it.**

```bash
just flash /dev/sdX
```

Run this **on the host, not inside Toolbx or distrobox** — container root maps
to a different UID and will corrupt ownership on the EFI partition, producing a
card that looks fine and does not boot.

The script asks you to type the device name back before it does anything. It
then downloads Fedora CoreOS (~1 GB), writes it, fetches the Raspberry Pi
firmware, and copies the firmware onto the card's EFI partition.

## 4. First boot

Put the card in the Pi and power on. Then wait — the Pi does a lot here:

1. **20–30 seconds of nothing.** No output at all. This is normal.
2. U-Boot starts, GRUB appears, Fedora CoreOS boots.
3. Ignition applies your config on first boot.
4. `pi-core-autorebase.service` pulls `ghcr.io/<owner>/pi-core:stable` and
   reboots. **This downloads a multi-gigabyte image** — on a slow card and a
   slow link it can take a long while. The Pi looks idle; it is not.
5. The Pi comes back up running pi-core.

The whole sequence is two reboots. Do not pull the power because it seems stuck;
watch the serial console if you want to see what it is actually doing.

## 5. Find it on the network

**`pi-core.local` will not work.** The image has no avahi and no `nss-mdns`, and
systemd-resolved's `MulticastDNS` defaults to `no` — nothing answers mDNS.

Get the address from your router's DHCP lease table, then:

```bash
ssh core@<address>
```

(If you want `.local` to work, add `avahi` and `nss-mdns` to
`build_files/build.sh` and enable `avahi-daemon`. It is not in the image today.)

## 6. Verify

```bash
# Are we actually running our image, not plain uCore?
bootc status

# Is the ESP firmware in step with the image?
pi-core-firmware check
```

`bootc status` should name `ghcr.io/<owner>/pi-core:stable`. If it still says
`ucore-minimal`, the rebase did not run — check
`journalctl -u pi-core-autorebase.service`.

## 7. Day-to-day

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

## 8. Serial console

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

## 9. If it goes wrong

| Symptom | Likely cause |
|---|---|
| No output at all, ever | EEPROM not updated (step 1), or the firmware never landed on the EFI partition |
| Rainbow screen, then nothing | Firmware loaded but `rpi-u-boot.bin` is missing or unreadable |
| Boots FCOS but no SSH | Ignition failed — check the serial console; a malformed key is the usual cause |
| SSH works, still plain uCore | Rebase failed; `journalctl -u pi-core-autorebase.service` |
| Card boots on the workstation but not the Pi | Flashed from inside a container (step 3) |
| Nothing on serial, Pi 5 | Wrong UART — Pi 5 uses the debug connector, not GPIO 14/15 (§8) |
| Pi 5 will not boot from USB/NVMe | Expected; Pi 5 is SD-only here |

Boot chain, for orientation:

```
EEPROM -> config.txt (kernel=rpi-u-boot.bin) -> U-Boot -> U-Boot EFI
       -> GRUB -> BLS entry -> ostree deployment
```
