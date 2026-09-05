#!/bin/bash
# Build a flashable Raspberry Pi disk image: Fedora CoreOS (aarch64) with our
# Ignition config embedded and the Pi firmware + U-Boot on its ESP.
#
# This is scripts/flash.sh writing to a loop-mounted file instead of a card, so
# the result can be handed to Rufus, balenaEtcher or `dd` on any machine. It is
# NOT a departure from "rebase, not a disk image" (docs/design-decisions.md):
# the bytes still come from coreos-installer applying stock FCOS, customisation
# still lives in the Containerfile, and the machine still rebases onto the
# pi-core image on first boot. Only the delivery changes.
#
# Needs root (loop devices, mounting the ESP, privileged podman). Safe: it only
# ever writes to the image file and the loop device backing it.
#
# MUST be run on the host, NOT inside a Toolbx/distrobox container — same UID
# mapping problem that makes flash.sh corrupt ESP ownership.
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

sudo udevadm settle
sudo partprobe "${LOOP}" 2>/dev/null || true

ESP="$(sudo lsblk "${LOOP}" -J -o LABEL,PATH \
       | jq -r '.blockdevices[] | .. | objects | select(.label=="EFI-SYSTEM") | .path' \
       | head -1)"
[[ -n "${ESP}" ]] || die "could not find the EFI-SYSTEM partition on ${LOOP}"

MNT="$(mktemp -d)"
sudo mount "${ESP}" "${MNT}"
log "copying firmware onto the ESP"
# --ignore-existing: never clobber what coreos-installer put there (EFI/, grub).
sudo rsync -ah --ignore-existing --chown 0:0 build/rpi-firmware/ "${MNT}/"

if [[ ! -e "${MNT}/pi-core.conf" ]]; then
    sudo cp provisioning/pi-core.conf.example "${MNT}/pi-core.conf"
    sudo chown 0:0 "${MNT}/pi-core.conf"
    log "wrote pi-core.conf to the boot partition"
fi
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
  1. Flash ${OUT}$([[ "${COMPRESS}" == "1" ]] && echo "(.xz)") to the card.
     Rufus: pick the image, DD/raw mode. balenaEtcher and dd also work.
  2. Re-insert the card. The FAT partition mounts on any OS, Windows included.
  3. Edit pi-core.conf on it — hostname, and PI_PASSWORD_HASH from:
         just password-hash
     Without a password hash a machine that boots but never reaches the
     network cannot be logged into at all; there is no serial console here.
  4. Boot the Pi. Expect 20-30 s of blank screen, then two reboots as Ignition
     rebases onto ghcr.io/$(./scripts/repo-owner.sh)/pi-core:stable.

${PI_HOSTNAME:-pi-core}.local will NOT resolve — the image has no mDNS
responder. Find the address in your DHCP leases, then: ssh core@<address>
EOF
