#!/bin/bash
# pi-core image build. Runs inside the container build.
set -oue pipefail

FEDORA_RELEASE="${FEDORA_RELEASE:-44}"
FW_STASH=/usr/lib/pi-core/firmware

echo "::: pi-core build on $(rpm -E '%{_arch}'), Fedora $(rpm -E '%fedora')"

# Fail loudly rather than silently producing an x86 image.
if [[ "$(rpm -E '%{_arch}')" != "aarch64" ]]; then
    echo "FATAL: pi-core is aarch64-only, got $(rpm -E '%{_arch}'). Build with --platform=linux/arm64." >&2
    exit 1
fi

### 1. Overlay static files
cp -avf /ctx/system_files/. /

### 2. Stash the Raspberry Pi firmware + U-Boot inside the image
#
# bootc/bootupd only manage /boot/efi/EFI, but a Pi needs firmware, DTBs,
# config.txt and u-boot.bin at the *root* of the ESP. Until bootupd grows
# support (coreos/bootupd#766, PR #935 still open), we keep a copy of the
# firmware in /usr/lib and reconcile it to the ESP by hand via
# `pi-core-firmware sync`. See docs/design-decisions.md.
#
# bcm283x-firmware Requires bcm2711/bcm2712/bcm2835-firmware + overlays, so
# this single payload covers Pi 3, 4 and 5.
dnf5 install -y bcm283x-firmware uboot-images-armv8

mkdir -p "${FW_STASH}"
cp -a /boot/efi/. "${FW_STASH}/"
# Fedora's config.txt says `kernel=rpi-u-boot.bin`, so match that name.
cp -P /usr/share/uboot/rpi_arm64/u-boot.bin "${FW_STASH}/rpi-u-boot.bin"

# Record what we shipped so the on-device checker can compare versions.
rpm -q bcm283x-firmware bcm2711-firmware bcm2712-firmware bcm2835-firmware \
       bcm283x-overlays uboot-images-armv8 > "${FW_STASH}/.versions"

# Drop the packages again; only the stash should survive into the image.
dnf5 remove -y bcm283x-firmware bcm2711-firmware bcm2712-firmware \
                bcm2835-firmware bcm283x-overlays uboot-images-armv8

# /boot must be completely empty in a bootc image — it is populated at install
# time. The firmware packages created /boot/efi; take the directory with it,
# or `bootc container lint` warns nonempty-boot.
rm -rf /boot/efi

### 3. mDNS, so <hostname>.local resolves on the LAN
#
# The published image is meant to be reachable with nothing but a flashed card:
# no serial console, no per-device config, no DHCP-lease archaeology. That needs
# a responder (avahi publishes), and nss-mdns so this host can resolve other
# .local names too. Firewalld's zone override in system_files opens 5353.
dnf5 install -y avahi nss-mdns

# nss-mdns only takes effect once mdns4_minimal is in nsswitch's hosts line,
# which authselect owns. Use its feature flag so a later `authselect apply`
# on the device does not quietly drop it; fall back to editing the file if no
# profile is selected in the build container.
if authselect enable-feature with-mdns4; then
    echo "::: mdns4 enabled via authselect"
else
    echo "::: no authselect profile; patching /etc/nsswitch.conf directly"
    sed -i 's/^\(hosts:.*\)resolve/\1mdns4_minimal [NOTFOUND=return] resolve/' /etc/nsswitch.conf
fi
grep -E '^hosts:' /etc/nsswitch.conf

### 4. Enable units
systemctl enable pi-core-firmware-check.service
systemctl enable avahi-daemon.service

### 5. Cleanup
# Beyond the usual: dnf leaves /run/dnf (nonempty-run-tmp) and per-repo
# `countme` state under /var/lib/dnf/repos with no tmpfiles.d entry
# (var-tmpfiles). Both trip bootc container lint.
dnf5 clean all
# authselect records a checksum under /var, which trips bootc's var-tmpfiles
# lint (a plain file in /var with no tmpfiles.d entry). The nsswitch.conf it
# generated lives in /etc and survives; only the bookkeeping goes.
rm -rf /var/cache/* /var/log/* /tmp/* /run/dnf /var/lib/dnf/repos /var/lib/authselect || true

echo "::: pi-core build complete; firmware stash:"
find "${FW_STASH}" -maxdepth 1 -printf '%f\n' | sort | head -20
