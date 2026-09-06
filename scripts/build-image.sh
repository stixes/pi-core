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
# --filesystem xfs: the image declares mount specs in /usr/lib/bootc/install but
#   no root filesystem type, because Fedora CoreOS is installed by
#   coreos-installer and never needed bootc to know. Without this bootc stops
#   with "No root filesystem specified". xfs is what FCOS uses, confirmed on a
#   running Pi.
#
# Note there is no --target-no-signature-verification here, and its absence
# changes nothing: bootc 1.16.7 hides the flag and discards it. `bootc install`
# never verifies a signature in any case, because install_container() pins the
# source to ContainerPolicyAllowInsecure -- the image comes from local
# containers-storage, already pulled and verified out of band. What the install
# does do is record ostree-image-signed: in the deployment origin, because the
# image sets enforce-container-sigpolicy; the signature policy the image ships
# is what makes that record mean something on the first `bootc upgrade`.
sudo podman run --rm --privileged --pid=host \
    --security-opt label=type:unconfined_t \
    -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
    -v "$(pwd):/data:z" -w /data \
    --arch arm64 "${IMAGE}" \
    bootc install to-disk \
        --generic-image \
        --wipe \
        --filesystem xfs \
        --karg console=tty0 \
        --karg video=HDMI-A-1:1280x720@60 \
        --karg video=HDMI-A-2:1280x720@60 \
        "${LOOP}"

# Take the firmware from the image, not from a fresh download.
#
# fetch-firmware.sh pulls Fedora's stock RPMs, but build.sh customises the
# stashed copy (config.txt) inside the image. Downloading again put stock files
# on the ESP while the image carried modified ones: the config.txt changes
# never shipped, and `pi-core-firmware check` reported drift on every fresh
# install by construction. Copying the stash makes the ESP and the image agree,
# which is the whole premise of that check.
#
# `podman cp` reads the container filesystem without executing anything, so
# this works cross-arch with no emulation.
log "extracting the Pi firmware from ${IMAGE}"
rm -rf build/rpi-firmware
FWCID="$(sudo podman create --arch arm64 "${IMAGE}" /bin/true)"
sudo podman cp "${FWCID}:/usr/lib/pi-core/firmware" build/rpi-firmware
sudo podman rm "${FWCID}" >/dev/null
[[ -f build/rpi-firmware/rpi-u-boot.bin ]] || die "no rpi-u-boot.bin in the image's firmware stash"

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

# Tell GRUB which filesystem holds /boot.
#
# The stub grub.cfg on the ESP sources ${config_directory}/bootuuid.cfg for a
# BOOT_UUID and, failing that, falls back to `search --label boot`. Fedora
# CoreOS's bootc config sets skip-boot-uuid = true so bootupd does not write
# that file, because on a CoreOS install the UUIDs are regenerated at first
# boot. Nothing regenerates them here, and bootc's layout has no separate boot
# partition, so nothing is labelled "boot" either: the search finds nothing,
# prefix stays empty and GRUB lands in a rescue prompt.
#
# Stamping the root filesystem's UUID fixes it. The stub already copes with
# /boot living inside root -- it tries ($prefix)/grub2 and then
# ($prefix)/boot/grub2.
ROOTDEV=""
for part in "${LOOP}"p*; do
    [[ -b "${part}" ]] || continue
    if [[ "$(sudo blkid -p -s LABEL -o value "${part}" 2>/dev/null)" == "root" ]]; then
        ROOTDEV="${part}"
        break
    fi
done
[[ -n "${ROOTDEV}" ]] || die "no partition labelled 'root' on ${LOOP}"
ROOT_UUID="$(sudo blkid -p -s UUID -o value "${ROOTDEV}")"
[[ -n "${ROOT_UUID}" ]] || die "could not read the root filesystem UUID from ${ROOTDEV}"
log "root filesystem is ${ROOTDEV} (UUID ${ROOT_UUID})"

MNT="$(mktemp -d)"
sudo mount "${ESP}" "${MNT}"
log "stamping BOOT_UUID into the GRUB stub"
printf 'set BOOT_UUID=%s\n' "${ROOT_UUID}" | sudo tee "${MNT}/EFI/fedora/bootuuid.cfg" >/dev/null
log "copying Pi firmware onto the ESP"
# --ignore-existing: never clobber the bootloader bootc just installed.
sudo rsync -ah --ignore-existing --chown 0:0 build/rpi-firmware/ "${MNT}/"
grep -q "${ROOT_UUID}" "${MNT}/EFI/fedora/bootuuid.cfg" \
    || die "bootuuid.cfg does not carry the root UUID — GRUB would not find /boot"
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
