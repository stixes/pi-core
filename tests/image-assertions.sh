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

# Deliberately diverged from Fedora's config.txt so the firmware sets up the
# display and config.txt can constrain it. If this reverts, the U-Boot and GRUB
# screens go back to panel-native resolution.
if grep -qE '^disable_fw_kms_setup=1' "$FW/config.txt"; then
    fail "disable_fw_kms_setup=1 is active again — config.txt cannot affect the display"
else
    pass "disable_fw_kms_setup is disabled"
fi
for k in framebuffer_width framebuffer_height; do
    check "config.txt sets $k" grep -qE "^${k}=" "$FW/config.txt"
done

head_ "kernel device trees (Pi 3 / 4 / 5 coverage)"
shopt -s nullglob
MODDIRS=(/usr/lib/modules/*/)
KVER=$(basename "${MODDIRS[0]:-none}")
for dtb in bcm2837-rpi-3-b-plus.dtb bcm2711-rpi-4-b.dtb bcm2712-rpi-5-b.dtb; do
    if [[ -e "/usr/lib/modules/$KVER/dtb/broadcom/$dtb" ]]; then pass "$dtb"; else fail "$dtb missing from kernel $KVER"; fi
done

head_ "device trees are pruned to Broadcom"
# 2386 DTBs at ~80 MB per deployment does not fit twice in a 384 MB /boot, and
# bootc install offers no way to make that partition bigger. A real Pi failed
# to stage an update on exactly this.
DTBDIR="/usr/lib/modules/$KVER/dtb"
if [[ -d "$DTBDIR" ]]; then
    OTHER=$(find "$DTBDIR" -mindepth 1 -maxdepth 1 ! -name broadcom | wc -l)
    if [[ "$OTHER" -eq 0 ]]; then
        pass "only broadcom/ remains"
    else
        fail "$OTHER non-Broadcom entries left in $DTBDIR"
    fi
    DTBMB=$(du -sm "$DTBDIR" | cut -f1)
    if [[ "$DTBMB" -lt 15 ]]; then
        pass "device trees are ${DTBMB} MB (two deployments fit in /boot)"
    else
        fail "device trees are ${DTBMB} MB — /boot holds two deployments of this plus a 88 MB initramfs"
    fi
else
    fail "no dtb directory under /usr/lib/modules/$KVER"
fi

head_ "bootc hygiene"
BOOTCONTENT=$(find /boot -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)
if [[ -z "$BOOTCONTENT" ]]; then pass "/boot is empty"; else fail "/boot is not empty: $BOOTCONTENT"; fi

head_ "our additions"
check "pi-core-firmware is executable" test -x /usr/bin/pi-core-firmware
check "sshd is enabled" test -L /etc/systemd/system/multi-user.target.wants/sshd.service

head_ "expected runtime"
for b in bootc rpm-ostree docker podman tailscale; do
    check "$b present" command -v "$b"
done

head_ "the core user (Ignition used to create this; now the image must)"
if getent passwd core >/dev/null 2>&1; then
    pass "core exists"
    UID_=$(id -u core)
    if [[ "$UID_" == "1000" ]]; then pass "uid 1000"; else fail "uid is $UID_"; fi
    for g in wheel sudo docker adm systemd-journal; do
        if id -nG core | tr ' ' '\n' | grep -qx "$g"; then pass "in group $g"; else fail "not in group $g"; fi
    done
    HOME_=$(getent passwd core | cut -d: -f6)
    if [[ "$HOME_" == "/var/home/core" ]]; then pass "home is /var/home/core"; else fail "home is $HOME_"; fi
    # An empty or ! field means no password login at all, which for a published
    # image with no SSH key would mean nothing could log in.
    PW=$(getent shadow core 2>/dev/null | cut -d: -f2)
    if [[ "$PW" == \$* ]]; then pass "has a password hash"; else fail "password field is '${PW:-empty}' — nothing could log in"; fi
else
    fail "no core user — a pre-rebased image has no Ignition to create one"
fi
# /var is not part of a bootc image, so the home directory has to come from
# tmpfiles at boot instead of useradd at build time.
check "tmpfiles creates the home directory" grep -q '/var/home/core' /usr/lib/tmpfiles.d/pi-core.conf

head_ "/boot is not left to coreos-boot-mount-generator"
# Without an fstab entry the generator invents a mount for LABEL=boot, which
# does not exist in bootc's two-partition layout: boot.mount hangs, local-fs
# fails, and most of userspace follows. This hung a Pi 4.
if [[ -f /etc/fstab ]] && grep -qE '^[^#]*[[:space:]]/boot[[:space:]]' /etc/fstab; then
    pass "fstab covers /boot, so the generator stands down"
else
    fail "no /boot entry in /etc/fstab — coreos-boot-mount-generator will hang the boot"
fi
# It must expose the real thing. The image's own /boot is empty by design, so
# binding /boot onto itself stops the hang and still leaves /boot empty, with
# nowhere for bootc to write BLS entries.
if grep -qE '^/sysroot/boot[[:space:]]+/boot[[:space:]]+none[[:space:]]+bind' /etc/fstab; then
    pass "it binds /sysroot/boot, where the kernels actually are"
else
    fail "the /boot entry does not bind /sysroot/boot: $(grep -E '/boot' /etc/fstab | grep -v '^#')"
fi

# An unmounted /var leaves the composefs one in place, which is read-only.
if grep -qE '^/sysroot/ostree/deploy/[^/]+/var[[:space:]]+/var[[:space:]]+none[[:space:]]+bind' /etc/fstab; then
    pass "fstab binds the stateroot's /var"
else
    fail "no /var bind in /etc/fstab — /var would be the read-only composefs copy"
fi
# The stateroot name is baked into that path, so catch it changing under us.
STATEROOT=$(bootc install print-configuration 2>/dev/null | grep -oE '"stateroot":"[^"]+"' | cut -d'"' -f4)
if [[ -z "$STATEROOT" ]]; then
    skip "could not read the stateroot from bootc"
elif grep -qE "^/sysroot/ostree/deploy/${STATEROOT}/var[[:space:]]" /etc/fstab; then
    pass "the bind path matches bootc's stateroot ($STATEROOT)"
else
    fail "fstab does not match bootc's stateroot '$STATEROOT'"
fi

head_ "unit enablement is a preset, not a /etc symlink"
# `systemctl enable` writes /etc, and the deployment's /etc is regenerated from
# presets at install: a build-time enable is silently dropped. A Pi 4 booted
# with pi-core-growfs disabled and an un-grown root because of exactly this.
PRESET=/usr/lib/systemd/system-preset/10-pi-core.preset
check "preset file present" test -f "$PRESET"
for u in pi-core-firmware-check.service pi-core-growfs.service pi-core-hostname.service; do
    if grep -qE "^enable[[:space:]]+${u}\$" "$PRESET" 2>/dev/null; then
        pass "preset enables $u"
    else
        fail "$u is not enabled by preset — it will not be enabled on the installed system"
    fi
done
# Masking via `systemctl mask` writes /etc too, so it must be masked in /usr.
if [[ "$(readlink -f /usr/lib/systemd/system/zincati.service 2>/dev/null)" == /dev/null ]]; then
    pass "zincati masked in /usr (survives the /etc regeneration)"
else
    fail "zincati is not masked in /usr — it retries forever against a bootc image"
fi

head_ "hostname (Ignition used to write /etc/hostname)"
# The image cannot ship /etc/hostname: podman bind-mounts it during a build, so
# it never reaches the image. Written at boot instead -- without it systemd
# falls back to "linux", avahi publishes linux.local, and the
# ssh core@pi-core.local in INSTALL.md does not resolve.
HN_UNIT=/usr/lib/systemd/system/pi-core-hostname.service
check "hostname unit present" test -f "$HN_UNIT"
if grep -q 'ConditionPathExists=!/etc/hostname' "$HN_UNIT" 2>/dev/null; then
    pass "defers to a hostname the owner set"
else
    fail "would overwrite a renamed machine"
fi
if grep -q '/proc/sys/kernel/hostname' "$HN_UNIT" 2>/dev/null; then
    pass "sets the running hostname too, not just the file"
else
    fail "only writes the file — the first boot would still be 'linux' to avahi"
fi

head_ "root growth (Ignition's initramfs used to do this)"
check "pi-core-growfs is executable" test -x /usr/bin/pi-core-growfs
for b in growpart xfs_growfs; do
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
