#!/bin/bash
# Build the flashable pi-core disk image.
#
# This is pi-core itself, not an installer for it: `bootc install to-disk`
# deploys the pi-core container straight onto the image, so a flashed card
# boots the finished system. Nothing is downloaded on first boot, which is why
# there is no Ignition config, no autorebase unit, and no dependency on the
# network, the clock or the registry before the machine is usable.
#
# The Pi firmware and U-Boot still go on the ESP afterwards; bootc has no
# reason to know about them.
#
# Needs root (loop devices, mounting the ESP, privileged podman) and an aarch64
# host or working qemu-user binfmt: `bootc install` runs the target image's own
# bootc binary.
#
# MUST be run on the host, NOT inside a Toolbx/distrobox container: container
# root maps to a different UID and corrupts ownership on the ESP.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./pi-core.env

REPO_ORGANIZATION="${REPO_ORGANIZATION:-$(./scripts/repo-owner.sh)}"
IMAGE="${IMAGE:-ghcr.io/${REPO_ORGANIZATION}/${IMAGE_NAME}:${DEFAULT_TAG}}"
OUT="${OUT:-build/pi-core-$(date +%Y%m%d).img}"
COMPRESS="${COMPRESS:-1}"
# Only has to be big enough to install into: pi-core-growfs.service resizes the
# root filesystem to fill the card on first boot.
SIZE="${SIZE:-6G}"

die() { echo "build-image: $*" >&2; exit 1; }
log() { echo ":: $*"; }

LOOP=""
MNT=""
cleanup() {
    [[ -n "${MNT}" ]] && sudo umount "${MNT}" 2>/dev/null
    [[ -n "${LOOP}" ]] && sudo losetup -d "${LOOP}" 2>/dev/null
    [[ -n "${MNT}" && -d "${MNT}" ]] && rmdir "${MNT}" 2>/dev/null
    return 0
}
trap cleanup EXIT

if [[ -f /run/.toolboxenv || -f /run/.containerenv ]]; then
    die "refusing to run inside a container — see the header of this script"
fi

mkdir -p build
TMP="${OUT}.tmp"
rm -f "${TMP}"
truncate -s "${SIZE}" "${TMP}"

log "attaching ${TMP} to a loop device"
LOOP="$(sudo losetup --find --show --partscan "${TMP}")"
[[ -b "${LOOP}" ]] || die "losetup did not give us a block device"

log "pulling ${IMAGE}"
sudo podman pull --arch arm64 "${IMAGE}"

log "installing it to ${LOOP} with bootc"
# --generic-image: the disk is going to an unknown machine, so do not record
#   this build host's firmware or boot entries in it.
# --karg: what the Ignition config used to set. console=tty0 keeps an attached
#   monitor alive once the kernel starts; the video= caps stop the console
#   rendering at panel-native resolution (320 columns on a 1440p screen).
# --target-no-signature-verification: the image's own bootc config sets
#   enforce-container-sigpolicy, and the policy shipped in it does not yet carry
#   our cosign key. We verify the image out of band instead; wiring the key into
#   policy.json is the follow-up that lets this flag go away.
sudo podman run --rm --privileged --pid=host \
    --security-opt label=type:unconfined_t \
    -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
    -v "$(pwd):/data:z" -w /data \
    --arch arm64 "${IMAGE}" \
    bootc install to-disk \
        --generic-image \
        --wipe \
        --target-no-signature-verification \
        --karg console=tty0 \
        --karg video=HDMI-A-1:1280x720@60 \
        --karg video=HDMI-A-2:1280x720@60 \
        "${LOOP}"

log "fetching Raspberry Pi firmware"
./scripts/fetch-firmware.sh build/rpi-firmware

# Re-attach so the kernel reads the partition table bootc just wrote:
# --partscan only scans at attach time, and at attach time this file was empty.
sudo losetup -d "${LOOP}"
LOOP="$(sudo losetup --find --show --partscan "${TMP}")"
[[ -b "${LOOP}" ]] || die "losetup did not give us a block device on re-attach"
sudo partprobe "${LOOP}" 2>/dev/null || true
sudo udevadm settle

# Probe partitions directly. lsblk reports LABEL out of udev's database, which
# is populated asynchronously and has already returned a blank label here for a
# partition that was perfectly fine. `blkid -p` reads the device and cannot race.
ESP=""
for part in "${LOOP}"p*; do
    [[ -b "${part}" ]] || continue
    if [[ "$(sudo blkid -p -s LABEL -o value "${part}" 2>/dev/null)" == "EFI-SYSTEM" ]]; then
        ESP="${part}"
        break
    fi
done
if [[ -z "${ESP}" ]]; then
    echo "build-image: no EFI-SYSTEM partition on ${LOOP}. Partitions probe as:" >&2
    for part in "${LOOP}"p*; do
        [[ -b "${part}" ]] || continue
        printf '  %-16s %s\n' "${part}" "$(sudo blkid -p -o export "${part}" 2>/dev/null | tr '\n' ' ')" >&2
    done
    die "could not find the EFI-SYSTEM partition on ${LOOP}"
fi
log "ESP is ${ESP}"

MNT="$(mktemp -d)"
sudo mount "${ESP}" "${MNT}"
log "copying Pi firmware onto the ESP"
# --ignore-existing: never clobber the bootloader bootc just installed.
sudo rsync -ah --ignore-existing --chown 0:0 build/rpi-firmware/ "${MNT}/"
sudo sync
sudo umount "${MNT}"
rmdir "${MNT}"; MNT=""

sudo sfdisk --verify "${LOOP}" >/dev/null || die "the image's partition table does not verify"

sudo losetup -d "${LOOP}"; LOOP=""
mv "${TMP}" "${OUT}"
log "wrote ${OUT} ($(du -h "${OUT}" | cut -f1))"

if [[ "${COMPRESS}" == "1" ]]; then
    log "compressing (this takes a few minutes)"
    rm -f "${OUT}.xz"
    xz -T0 -6 --keep "${OUT}"
    log "wrote ${OUT}.xz ($(du -h "${OUT}.xz" | cut -f1))"
fi

cat <<EOF

Next:
  1. Flash ${OUT}$([[ "${COMPRESS}" == "1" ]] && echo " (or the .xz)") to a card.
     Rufus: pick the image, DD/raw mode. balenaEtcher and dd also work.
  2. Boot the Pi. One boot, no rebase, no download - it comes up as pi-core.
     The root filesystem grows to fill the card on that first boot.
  3. Log in as core / core, at the console or over SSH:
         ssh core@${PI_HOSTNAME:-pi-core}.local
EOF
