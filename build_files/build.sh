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
# `pi-core-firmware sync`. See docs/research.md §4.
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

### 3. Enable units
systemctl enable pi-core-firmware-check.service

### 4. Cleanup
# Beyond the usual: dnf leaves /run/dnf (nonempty-run-tmp) and per-repo
# `countme` state under /var/lib/dnf/repos with no tmpfiles.d entry
# (var-tmpfiles). Both trip bootc container lint.
dnf5 clean all
rm -rf /var/cache/* /var/log/* /tmp/* /run/dnf /var/lib/dnf/repos || true

echo "::: pi-core build complete; firmware stash:"
find "${FW_STASH}" -maxdepth 1 -printf '%f\n' | sort | head -20
