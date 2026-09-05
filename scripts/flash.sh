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

# Whole disks backing this machine's own filesystems — never flash candidates.
#
# Checking only `/` is not enough: on an ostree/composefs host (Fedora Atomic,
# and this very workstation) `findmnt -no SOURCE /` returns the string
# "composefs", not a block device, so the guard silently protects nothing.
# Check the mountpoints that are backed by real devices too, and strip the
# "[/subvol]" suffix findmnt appends.
system_disks() {
    local mp src parent
    for mp in / /sysroot /boot /var /home; do
        src="$(findmnt -no SOURCE "${mp}" 2>/dev/null | head -1 || true)"
        src="${src%%[*}"
        [[ -n "${src}" && "${src}" == /dev/* ]] || continue
        parent="$(lsblk -no PKNAME "${src}" 2>/dev/null | head -1 || true)"
        if [[ -n "${parent}" ]]; then
            echo "/dev/${parent}"
        else
            echo "${src}"
        fi
    done | sort -u
    # Must not return non-zero: under `set -e` a failing command substitution
    # in an assignment aborts the caller, silently.
    return 0
}

is_system_disk() {
    local candidate="$1" d
    while read -r d; do
        [[ -n "$d" && "$d" == "$candidate" ]] && return 0
    done < <(system_disks)
    return 1
}

usage() {
    local sysdisks; sysdisks="$(system_disks || true)"
    cat <<EOF
Usage: just flash /dev/sdX          (or: scripts/flash.sh /dev/sdX [config.ign])

Writes Fedora CoreOS ${FCOS_STREAM} (aarch64) to the card, adds the Raspberry Pi
firmware and U-Boot to its EFI partition, and leaves a pi-core.conf there for
headless setup. THIS ERASES THE TARGET DEVICE.

Run 'just ignition' first if you have not already.

EOF
    local found=0
    echo "Removable / hotplug devices — the likely candidates:"
    while read -r name size tran model; do
        grep -qxF "/dev/${name}" <<<"${sysdisks}" && continue
        printf '  %-12s %-9s %-6s %s\n' "/dev/${name}" "${size}" "${tran:--}" "${model:-}"
        found=1
    done < <(lsblk -dn -o NAME,SIZE,TYPE,HOTPLUG,TRAN,MODEL 2>/dev/null \
             | grep -vE '^(zram|loop|sr)' | awk '$3=="disk" && $4=="1" {tran=$5; $1=$1; printf "%s %s %s ", $1, $2, tran; for(i=6;i<=NF;i++) printf "%s ", $i; print ""}')
    if [[ "${found}" -eq 0 ]]; then
        echo "  (none detected — is the card inserted?)"
    fi
    echo
    echo "Fixed disks on this machine (NOT candidates):"
    while read -r name size model; do
        local marker=""
        grep -qxF "/dev/${name}" <<<"${sysdisks}" && marker="  <-- THIS MACHINE"
        printf '  %-12s %-9s %s%s\n' "/dev/${name}" "${size}" "${model:-}" "${marker}"
    done < <(lsblk -dn -o NAME,SIZE,TYPE,HOTPLUG,MODEL 2>/dev/null \
             | grep -vE '^(zram|loop|sr)' | awk '$3=="disk" && $4=="0" {printf "%s %s ", $1, $2; for(i=5;i<=NF;i++) printf "%s ", $i; print ""}')
    echo
    echo "Confirm the size and model match the card before running."
}

if [[ -z "${DISK}" || "${DISK}" == "-h" || "${DISK}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ -f /run/.toolboxenv || -f /run/.containerenv ]]; then
    die "refusing to run inside a container — see the header of this script"
fi

[[ -b "${DISK}" ]]  || die "${DISK} is not a block device"

# Guard against nuking this workstation's own disk. This comes before every
# other check: if the target is this machine, that is what the user needs to be
# told, not that some prerequisite is missing.
if is_system_disk "${DISK}"; then
    die "${DISK} backs a filesystem of THIS machine — refusing"
fi

[[ -r "${IGN}" ]]   || die "no ignition config at ${IGN} (run scripts/render-ignition.sh)"

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
