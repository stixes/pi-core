# pi-core — installer image for Raspberry Pi

**This is an installer, not pi-core itself.** It is stock Fedora CoreOS
(aarch64) with the Raspberry Pi firmware and U-Boot on its EFI partition, plus
a config that installs pi-core on first boot: it pulls the pi-core container
(~2.5 GB), rebases onto it, and reboots. After that it is an ordinary bootc
host and nothing is downloaded again until you update.

Two consequences worth knowing before you start:

- **First boot needs a working network**, and takes as long as that download
  takes. The Pi looks idle throughout.
- **Until the install finishes, the machine is plain Fedora CoreOS.** Log in
  by IP address, not `pi-core.local` — the mDNS responder is part of pi-core
  and is not there yet.

**Pi 5 and Pi 4.** Pi 3 and Zero 2 W are excluded on RAM, not enablement.

## Flash it

Download `pi-core-installer-*.img.xz`, then write it to an SD card with Raspberry Pi
Imager (choose "Use custom"), balenaEtcher, Rufus in DD/raw mode, or:

```bash
xzcat pi-core-installer-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Move the card to the Pi and power on. Expect 20–30 seconds of blank screen,
then two reboots while it rebases. The root filesystem grows to fill the card.

## First login

Wait for the two reboots first — the second one is the machine coming up as
pi-core.

```
user: core
password: core
```

Nothing forces you to change it. Leaving it alone on a network you control is a
legitimate choice; read the section below before making it.

Log in over SSH once the Pi has an address:

```bash
ssh core@<address>            # from your DHCP leases
ssh core@pi-core.local        # mDNS — only after the first-boot rebase finishes
```

`.local` depends on a responder that arrives with the pi-core image, so it does
not answer until the first-boot rebase has completed. The address always works.

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

## Status — read this first

**This image has never been booted on a real Raspberry Pi.**

It builds, it lints clean, it is signed, and an automated suite checks what the
image *contains*. None of that exercises the boot chain — EEPROM → U-Boot →
GRUB → ostree — which is the part most likely to fail, and no automated test
can reach it. The install steps are derived from Fedora CoreOS's Raspberry Pi 4
documentation, not from a Pi that booted.

So: expect to debug, keep a serial adapter or a monitor handy, and do not put
this on anything you care about yet. If it fails, please open an issue with the
Pi model and whatever the console showed — that is exactly the missing data.
