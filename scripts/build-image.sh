#!/bin/bash
# Build a flashable Raspberry Pi disk image: Fedora CoreOS (aarch64) with our
# Ignition config embedded and the Pi firmware + U-Boot on its ESP.
#
# This builds the artifact published on the releases page — the only supported
# way to install pi-core. It is NOT a departure from "rebase, not a disk image"
# (docs/design-decisions.md):
# the bytes still come from coreos-installer applying stock FCOS, customisation
# still lives in the Containerfile, and the machine still rebases onto the
# pi-core image on first boot. Only the delivery changes.
#
# Needs root (loop devices, mounting the ESP, privileged podman). Safe: it only
# ever writes to the image file and the loop device backing it.
#
# MUST be run on the host, NOT inside a Toolbx/distrobox container: container
# root maps to a different UID and corrupts ownership on the ESP.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./pi-core.env

IGN="${IGN:-build/pi.ign}"
OUT="${OUT:-build/pi-core-${FCOS_STREAM}-$(date +%Y%m%d).img}"
COMPRESS="${COMPRESS:-1}"
CACHE="build/fcos"

die() { echo "build-image: $*" >&2; exit 1; }
log() { echo ":: $*"; }

LOOP=""
cleanup() {
    [[ -n "${MNT:-}" ]] && sudo umount "${MNT}" 2>/dev/null
    [[ -n "${LOOP}" ]] && sudo losetup -d "${LOOP}" 2>/dev/null
    [[ -n "${MNT:-}" && -d "${MNT}" ]] && rmdir "${MNT}" 2>/dev/null
    return 0
}
trap cleanup EXIT

if [[ -f /run/.toolboxenv || -f /run/.containerenv ]]; then
    die "refusing to run inside a container — see the header of this script"
fi

[[ -r "${IGN}" ]] || die "no ignition config at ${IGN} (run: just ignition)"

mkdir -p "${CACHE}"

# Fetch the stock image first, rootlessly, for one reason beyond caching: its
# uncompressed size is the size the backing file must be. Sizing the file up
# front makes coreos-installer lay down a GPT whose backup header is already at
# the end of the disk. Growing a scratch file and trimming it afterwards is the
# obvious alternative and it does not work — truncating strands the backup GPT,
# and `sfdisk --relocate gpt-bak-std` destroys the partition entries repairing
# it. Do not reintroduce that.
RAW_XZ="$(find "${CACHE}" -maxdepth 1 -name '*metal*.raw.xz' -print -quit)"
if [[ -z "${RAW_XZ}" ]]; then
    log "downloading Fedora CoreOS ${FCOS_STREAM} (aarch64)"
    podman run --rm -v "$(pwd):/data:z" -w /data \
        quay.io/coreos/coreos-installer:release \
        download -a aarch64 -p metal -f raw.xz -s "${FCOS_STREAM}" -C "${CACHE}"
    RAW_XZ="$(find "${CACHE}" -maxdepth 1 -name '*metal*.raw.xz' -print -quit)"
fi
[[ -n "${RAW_XZ}" ]] || die "no metal image in ${CACHE} after download"
# coreos-installer verifies the detached signature and refuses without it. Fail
# here rather than after we have built a loop device around a 3 GB file.
[[ -r "${RAW_XZ}.sig" ]] || die "no signature beside ${RAW_XZ} — run 'rm -rf ${CACHE}' and retry to re-download both"
# The cache is never invalidated: a build kept here stays the one we use even
# after the stream moves on. That is deliberate — reflashing a fleet from one
# known image beats silently drifting. `rm -rf build/fcos` to pick up a newer one.
log "using $(basename "${RAW_XZ}")"

# Field 5 of `xz --robot --list`'s "file" line is the uncompressed size.
RAW_BYTES="$(xz --robot --list "${RAW_XZ}" | awk -F'\t' '$1=="file" {print $5}')"
[[ "${RAW_BYTES}" =~ ^[0-9]+$ ]] || die "could not read the uncompressed size of ${RAW_XZ}"
log "image is $(numfmt --to=iec --suffix=B "${RAW_BYTES}") uncompressed"

TMP="${OUT}.tmp"
rm -f "${TMP}"
truncate -s "${RAW_BYTES}" "${TMP}"

log "attaching ${TMP} to a loop device"
LOOP="$(sudo losetup --find --show --partscan "${TMP}")"
[[ -b "${LOOP}" ]] || die "losetup did not give us a block device"

log "installing Fedora CoreOS ${FCOS_STREAM} (aarch64)"
sudo podman run --pull=newer --rm --privileged \
    -v /dev:/dev -v /run/udev:/run/udev \
    -v "$(pwd):/data:z" -w /data \
    quay.io/coreos/coreos-installer:release \
    install --offline -f "${RAW_XZ}" -i "${IGN}" "${LOOP}"

log "fetching Raspberry Pi firmware"
./scripts/fetch-firmware.sh build/rpi-firmware

# Re-attach before looking for partitions. --partscan only scans at attach
# time, and at attach time this file was all zeros: coreos-installer wrote the
# partition table afterwards, so the kernel never saw it and no ${LOOP}pN
# devices exist. Detaching and re-attaching is what makes them appear.
sudo losetup -d "${LOOP}"
LOOP="$(sudo losetup --find --show --partscan "${TMP}")"
[[ -b "${LOOP}" ]] || die "losetup did not give us a block device on re-attach"
sudo udevadm settle
sudo partprobe "${LOOP}" 2>/dev/null || true

ESP="$(sudo lsblk "${LOOP}" -J -o LABEL,PATH \
       | jq -r '.blockdevices[] | .. | objects | select(.label=="EFI-SYSTEM") | .path' \
       | head -1)"
if [[ -z "${ESP}" ]]; then
    echo "build-image: no EFI-SYSTEM partition on ${LOOP}. lsblk sees:" >&2
    sudo lsblk "${LOOP}" -o NAME,LABEL,FSTYPE,SIZE >&2 || true
    die "could not find the EFI-SYSTEM partition on ${LOOP}"
fi

MNT="$(mktemp -d)"
sudo mount "${ESP}" "${MNT}"
log "copying firmware onto the ESP"
# --ignore-existing: never clobber what coreos-installer put there (EFI/, grub).
sudo rsync -ah --ignore-existing --chown 0:0 build/rpi-firmware/ "${MNT}/"

sudo sync
sudo umount "${MNT}"
rmdir "${MNT}"; MNT=""

sudo sfdisk --verify "${LOOP}" >/dev/null || die "the image's partition table does not verify"

sudo losetup -d "${LOOP}"; LOOP=""
mv "${TMP}" "${OUT}"

log "wrote ${OUT} ($(numfmt --to=iec --suffix=B "${RAW_BYTES}"))"

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
  2. Boot the Pi. Expect 20-30 s of blank screen, then two reboots as Ignition
     rebases onto ghcr.io/$(./scripts/repo-owner.sh)/pi-core:stable.
  3. Log in as core / core, at the console or over SSH once it has an address:
         ssh core@${PI_HOSTNAME:-pi-core}.local
     Everything else - password, hostname, keys, timezone - is configured
     after that login.
EOF
