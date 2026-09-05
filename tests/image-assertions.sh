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
check "firmware-check unit is enabled" test -L /etc/systemd/system/multi-user.target.wants/pi-core-firmware-check.service
check "sshd is enabled" test -L /etc/systemd/system/multi-user.target.wants/sshd.service

head_ "expected runtime"
for b in bootc rpm-ostree docker podman tailscale; do
    check "$b present" command -v "$b"
done

head_ "mDNS (INSTALL.md promises <host>.local resolves)"
# The inverse of the guard this repo used to carry: .local resolving is now a
# promise, so losing the responder has to fail the build rather than quietly
# strand every user who was told to ssh core@pi-core.local.
check "avahi installed" rpm -q avahi
check "nss-mdns installed" rpm -q nss-mdns
check "avahi-daemon is enabled" test -L /etc/systemd/system/multi-user.target.wants/avahi-daemon.service
if grep -qE '^hosts:.*mdns4' /etc/nsswitch.conf; then
    pass "nsswitch hosts line consults mdns4"
else
    fail "nsswitch hosts line has no mdns4 — nss-mdns is installed but inert: $(grep -E '^hosts:' /etc/nsswitch.conf)"
fi
if grep -q '<service name="mdns"/>' /etc/firewalld/zones/FedoraServer.xml 2>/dev/null; then
    pass "firewalld default zone opens mdns"
else
    fail "firewalld default zone does not open mdns — avahi would be unreachable"
fi

head_ "default credentials are reachable on purpose"
# The published image ships core/core and relies on SSH password auth. sshd
# takes the FIRST value for a keyword and reads sshd_config.d in lexical order,
# so our file only works while it sorts before FCOS's 40-disable-passwords.conf.
PWCONF=/etc/ssh/sshd_config.d/10-pi-core-passwords.conf
check "password-auth drop-in present" test -f "$PWCONF"
if grep -qE '^\s*PasswordAuthentication\s+yes' "$PWCONF" 2>/dev/null; then
    pass "drop-in enables PasswordAuthentication"
else
    fail "$PWCONF does not enable PasswordAuthentication"
fi
FIRST=$(find /etc/ssh/sshd_config.d -name '*.conf' -printf '%f\n' 2>/dev/null | sort | head -1)
if [[ "$FIRST" == "10-pi-core-passwords.conf" ]]; then
    pass "it sorts first, so it wins over 40-disable-passwords.conf"
else
    fail "$FIRST sorts before ours — password auth would stay disabled"
fi

# cockpit-ws would put a PAM web login on :9090, turning the documented default
# password into a second, browser-shaped front door. Keep it out deliberately.
if rpm -q cockpit-ws >/dev/null 2>&1; then
    fail "cockpit-ws present — core/core would be usable from a browser on :9090"
else
    pass "no cockpit-ws (default password stays SSH/console only)"
fi

summary "tier 1 (in-image)"
