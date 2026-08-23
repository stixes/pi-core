#!/bin/bash
# Download + extract the Raspberry Pi firmware payload the ESP needs.
#
# bcm283x-firmware Requires bcm2711/bcm2712/bcm2835-firmware and
# bcm283x-overlays, so --resolve gives us Pi 3, 4 and 5 firmware in one go.
# Fedora's stock config.txt already sets `kernel=rpi-u-boot.bin`, which is why
# we rename u-boot.bin to match.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./pi-core.env

OUT="${1:-build/rpi-firmware}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo ":: downloading firmware RPMs for Fedora ${FEDORA_RELEASE} (aarch64)"
podman run --rm -v "${WORK}:/out:z" "registry.fedoraproject.org/fedora:${FEDORA_RELEASE}" \
    dnf download --resolve --releasever="${FEDORA_RELEASE}" --forcearch=aarch64 \
        --destdir=/out bcm283x-firmware uboot-images-armv8

echo ":: extracting"
mkdir -p "${WORK}/x"
for rpm in "${WORK}"/*.rpm; do
    ( cd "${WORK}/x" && rpm2cpio "${rpm}" | cpio -idm --quiet )
done

mkdir -p "${OUT}"
cp -a "${WORK}/x/boot/efi/." "${OUT}/"
cp -P "${WORK}/x/usr/share/uboot/rpi_arm64/u-boot.bin" "${OUT}/rpi-u-boot.bin"

echo ":: firmware payload ready in ${OUT}"
ls -1 "${OUT}"
