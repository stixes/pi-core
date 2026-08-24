#!/bin/bash
# Runs INSIDE the built image. Bind-mounted there by tests/image.sh.
set -uo pipefail
source /tests/lib.sh

FW=/usr/lib/pi-core/firmware

head_ "architecture"
ARCH=$(rpm -E '%{_arch}')
if [[ "$ARCH" == "aarch64" ]]; then pass "rpm arch is aarch64"; else fail "rpm arch is $ARCH, expected aarch64"; fi

head_ "firmware stash"
for f in rpi-u-boot.bin start4.elf fixup4.dat config.txt bcm2711-rpi-4-b.dtb overlays .versions; do
    if [[ -e "$FW/$f" ]]; then pass "$f present"; else fail "$f MISSING from $FW"; fi
done
# Fedora's config.txt points the firmware at U-Boot under this exact name; if
# upstream ever renames it the Pi will not boot.
if grep -q '^kernel=rpi-u-boot.bin' "$FW/config.txt" 2>/dev/null; then
    pass "config.txt sets kernel=rpi-u-boot.bin"
else
    fail "config.txt does not set kernel=rpi-u-boot.bin"
fi

head_ "kernel device trees (Pi 3 / 4 / 5 coverage)"
shopt -s nullglob
MODDIRS=(/usr/lib/modules/*/)
KVER=$(basename "${MODDIRS[0]:-none}")
for dtb in bcm2837-rpi-3-b-plus.dtb bcm2711-rpi-4-b.dtb bcm2712-rpi-5-b.dtb; do
    if [[ -e "/usr/lib/modules/$KVER/dtb/broadcom/$dtb" ]]; then pass "$dtb"; else fail "$dtb missing from kernel $KVER"; fi
done

head_ "bootc hygiene"
BOOTCONTENT=$(find /boot -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)
if [[ -z "$BOOTCONTENT" ]]; then pass "/boot is empty"; else fail "/boot is not empty: $BOOTCONTENT"; fi

head_ "our additions"
check "pi-core-firmware is executable" test -x /usr/bin/pi-core-firmware
check "pi-core-provision is executable" test -x /usr/bin/pi-core-provision
check "firmware-check unit is enabled" test -L /etc/systemd/system/multi-user.target.wants/pi-core-firmware-check.service
check "provision unit is enabled"    test -L /etc/systemd/system/multi-user.target.wants/pi-core-provision.service
check "sshd is enabled" test -L /etc/systemd/system/multi-user.target.wants/sshd.service

head_ "expected runtime"
for b in bootc rpm-ostree docker podman tailscale; do
    check "$b present" command -v "$b"
done

head_ "documented assumptions"
# INSTALL.md tells the user <host>.local will NOT resolve. If someone adds an
# mDNS responder, this fails so the docs get updated with it.
if rpm -q avahi >/dev/null 2>&1 || rpm -q nss-mdns >/dev/null 2>&1; then
    fail "avahi/nss-mdns present — INSTALL.md says .local does not resolve; update the docs"
else
    pass "no mDNS responder (matches INSTALL.md)"
fi

summary "tier 1 (in-image)"
