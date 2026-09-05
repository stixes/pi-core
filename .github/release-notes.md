# pi-core — flashable Raspberry Pi image

Fedora CoreOS (aarch64) with the Raspberry Pi firmware and U-Boot already on
its EFI partition. On first boot it rebases itself onto the pi-core bootc
image and reboots twice; after that it is an ordinary bootc host.

**Pi 5 and Pi 4.** Pi 3 and Zero 2 W are excluded on RAM, not enablement.

## Flash it

Download `pi-core-*.img.xz`, then write it to an SD card with Raspberry Pi
Imager (choose "Use custom"), balenaEtcher, Rufus in DD/raw mode, or:

```bash
xzcat pi-core-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Move the card to the Pi and power on. Expect 20–30 seconds of blank screen,
then two reboots while it rebases. The root filesystem grows to fill the card.

## First login

```
user: core
password: core
```

Nothing forces you to change it. Leaving it alone on a network you control is a
legitimate choice; read the section below before making it.

Log in over SSH once the Pi has an address:

```bash
ssh core@pi-core.local        # mDNS; or use the address from your DHCP leases
```

A monitor and USB keyboard work too, if you would rather not wait for the
network.

## Read this before putting it on a network you share

This image is built for the case where all you have is a flashed card and an
Ethernet cable, and that convenience has a price:

- **SSH password authentication is enabled.** Stock Fedora CoreOS disables it;
  pi-core turns it back on so a headless first login is possible at all.
- **The password is public** — it is written above, and in the source.
- **The host advertises itself over mDNS**, so anything on the LAN can find it
  by name without scanning.

For as long as those credentials stay in place, this machine is reachable by
anyone on the same network who knows this page exists. On a home network you
control that is a reasonable trade — it is the same one DietPi and Raspberry Pi
OS have always offered. On a shared, guest, student or office network it is not:
change the password from the console before you plug in the Ethernet cable.

To take away the shared credential entirely, add your SSH key and set
`PasswordAuthentication no` in `/etc/ssh/sshd_config.d/10-pi-core-passwords.conf`
once you are in.

## Verify the download

```bash
cosign verify-blob --key cosign.pub --signature SHA256SUMS.sig SHA256SUMS
sha256sum -c SHA256SUMS
```

`cosign.pub` is in the repository root.

## Status

The boot chain — EEPROM → U-Boot → GRUB → ostree — has limited hardware
mileage. If it fails to boot, please open an issue with the model of Pi and
whatever the console showed.
