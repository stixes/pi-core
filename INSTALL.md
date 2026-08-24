# Installing pi-core on a Raspberry Pi 4

From a Pi and a blank SD card to a running, self-updating pi-core host.

Everything up to first boot happens on your workstation; the Pi is only powered
on twice.

> **Untested on hardware.** Every step below is derived from the Fedora CoreOS
> Raspberry Pi 4 documentation and from what the built image actually contains,
> but no one has run it end to end on a real Pi yet. Expect to debug.

## 0. What you need

- Raspberry Pi 4 (Pi 3 and Pi 5 firmware ships in the image too, but only Pi 4
  is targeted for now)
- SD card, 16 GB or more — plus a second, throwaway card for the EEPROM update
- A card reader on your workstation
- `podman`, `jq`, `rsync`, `make`, and `sudo` on the workstation
- **Strongly recommended: a USB-to-serial (3.3 V TTL) adapter.** If the Pi fails
  before networking comes up, this is the only way to see why.

Storage note: an SSD over USB is a better long-term choice than an SD card —
ostree deployments are write-heavy and none of this is write-tuned. Pi 4 boots
from USB with a current EEPROM. The procedure is identical; just point `DISK=`
at the USB device.

## 1. Update the Pi's EEPROM (one-time, per Pi)

**This is not optional.** Older EEPROMs cannot read the FAT16 EFI partition that
Fedora CoreOS creates, and the Pi will simply not boot.

Flash the Raspberry Pi *bootloader* image to the throwaway card (Raspberry Pi
Imager → Misc utility images → Bootloader → SD Card Boot), put it in the Pi,
and power on. The activity LED flashes rapidly and the screen goes green when
the update is done — roughly ten seconds. Power off and remove the card.

## 2. Configure your install

```bash
git clone git@github.com:stixes/pi-core.git
cd pi-core

export PI_HOSTNAME=pi-core                       # optional, defaults to pi-core
export SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub     # optional, defaults to id_rsa.pub

make ignition
```

This renders `build/pi4.ign`. It creates the `core` user with your key, masks
zincati, and installs the first-boot service that rebases onto
`ghcr.io/stixes/pi-core:stable`.

There is no password login — SSH key only. If you lose the key you reflash.

## 3. Flash the card

Find the device with `lsblk`, and be careful: **this erases it.**

```bash
make flash DISK=/dev/sdX
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
4. `pi-core-autorebase.service` pulls `ghcr.io/stixes/pi-core:stable` and
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

`bootc status` should name `ghcr.io/stixes/pi-core:stable`. If it still says
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

Worth wiring up before you need it. With the Pi powered off, connect the
adapter to the GPIO header:

| Adapter | Pi header |
|---|---|
| GND | pin 6 |
| RX  | pin 8  (GPIO14 / Pi TX) |
| TX  | pin 10 (GPIO15 / Pi RX) |

Do **not** connect the adapter's 5 V line. Then:

```bash
screen /dev/ttyUSB0 115200      # or: picocom -b 115200 /dev/ttyUSB0
```

`enable_uart=1` is already set in Fedora's `config.txt`, and U-Boot passes the
console through to the kernel automatically. On a Pi 4 the console is `ttyAMA0`.

## 9. If it goes wrong

| Symptom | Likely cause |
|---|---|
| No output at all, ever | EEPROM not updated (step 1), or the firmware never landed on the EFI partition |
| Rainbow screen, then nothing | Firmware loaded but `rpi-u-boot.bin` is missing or unreadable |
| Boots FCOS but no SSH | Ignition failed — check the serial console; a malformed key is the usual cause |
| SSH works, still plain uCore | Rebase failed; `journalctl -u pi-core-autorebase.service` |
| Card boots on the workstation but not the Pi | Flashed from inside a container (step 3) |

Boot chain, for orientation:

```
EEPROM -> config.txt (kernel=rpi-u-boot.bin) -> U-Boot -> U-Boot EFI
       -> GRUB -> BLS entry -> ostree deployment
```
