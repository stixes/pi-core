#!/bin/bash
# Flash Fedora CoreOS (aarch64) to an SD card / USB disk for a Raspberry Pi,
# then drop the Pi firmware + U-Boot onto its ESP.
#
# After first boot the Ignition config rebases the machine onto our pi-core
# image. This script does NOT write the pi-core image itself.
#
# DESTRUCTIVE. Everything on the target device is erased.
#
# MUST be run on the host, NOT inside a Toolbx/distrobox container: root in the
# container maps to a different UID than root on the host, which corrupts
# ownership on the ESP and can leave an unbootable disk.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./pi-core.env

DISK="${1:-}"
IGN="${2:-build/pi.ign}"

die() { echo "flash: $*" >&2; exit 1; }

[[ -n "${DISK}" ]] || die "usage: scripts/flash.sh /dev/sdX [ignition.ign]"

if [[ -f /run/.toolboxenv || -f /run/.containerenv ]]; then
    die "refusing to run inside a container — see the header of this script"
fi

[[ -b "${DISK}" ]]  || die "${DISK} is not a block device"
[[ -r "${IGN}" ]]   || die "no ignition config at ${IGN} (run scripts/render-ignition.sh)"

# Guard against nuking the workstation's own disk.
ROOTDEV="$(findmnt -no SOURCE / || true)"
ROOTPARENT="$(lsblk -no PKNAME "${ROOTDEV}" 2>/dev/null || true)"
[[ -n "${ROOTPARENT}" && "${DISK}" == "/dev/${ROOTPARENT}" ]] && die "${DISK} hosts the running root filesystem"

echo
lsblk -o NAME,SIZE,TYPE,RM,MODEL,MOUNTPOINTS "${DISK}"
echo
echo "This ERASES ${DISK} and installs Fedora CoreOS ${FCOS_STREAM} (aarch64)."
read -rp "Type the device name to confirm (${DISK}): " confirm
[[ "${confirm}" == "${DISK}" ]] || die "aborted"

# Unmount anything currently mounted from the target.
while read -r part; do
    if [[ -n "${part}" ]]; then
        sudo umount "${part}" 2>/dev/null || true
    fi
done < <(lsblk -nlo PATH "${DISK}" | tail -n +2)

echo ":: installing Fedora CoreOS"
sudo podman run --pull=newer --rm --privileged \
    -v /dev:/dev -v /run/udev:/run/udev \
    -v "$(pwd):/data:z" -w /data \
    quay.io/coreos/coreos-installer:release \
    install -a aarch64 -s "${FCOS_STREAM}" -i "${IGN}" "${DISK}"

echo ":: fetching Raspberry Pi firmware"
./scripts/fetch-firmware.sh build/rpi-firmware

echo ":: settling udev"
sudo udevadm settle
sleep 2

ESP="$(lsblk "${DISK}" -J -o LABEL,PATH | jq -r '.blockdevices[] | .. | objects | select(.label=="EFI-SYSTEM") | .path' | head -1)"
[[ -n "${ESP}" ]] || die "could not find the EFI-SYSTEM partition on ${DISK}"

MNT="$(mktemp -d)"
sudo mount "${ESP}" "${MNT}"
echo ":: copying firmware onto ${ESP}"
# --ignore-existing: never clobber what coreos-installer put there (EFI/, grub).
sudo rsync -avh --ignore-existing --chown 0:0 build/rpi-firmware/ "${MNT}/"

# Leave a headless-setup template on the card, DietPi-style: the FAT partition
# is the one mountable in any laptop, so this is where per-device settings go.
if [[ ! -e "${MNT}/pi-core.conf" ]]; then
    sudo cp provisioning/pi-core.conf.example "${MNT}/pi-core.conf"
    sudo chown 0:0 "${MNT}/pi-core.conf"
    echo ":: wrote pi-core.conf to the boot partition (edit it before first boot)"
fi
sudo sync
sudo umount "${MNT}"
rmdir "${MNT}"

echo
echo "Done. Move ${DISK} to the Pi and boot."
echo "Expect 20-30 s of blank screen before anything appears, then two reboots"
echo "as Ignition rebases onto the pi-core image."
echo
echo "The image has no mDNS responder, so ${PI_HOSTNAME:-pi-core}.local will NOT"
echo "resolve. Find the address in your DHCP leases, then: ssh core@<address>"
echo "See INSTALL.md for the serial-console fallback."
echo
echo "Headless setup: edit pi-core.conf on the FAT partition of the card before"
echo "first boot - hostname, SSH key, password hash, timezone, tailscale key."
