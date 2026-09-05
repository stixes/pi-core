#!/bin/bash
# pi-core image build. Runs inside the container build.
set -oue pipefail

FEDORA_RELEASE="${FEDORA_RELEASE:-44}"
FW_STASH=/usr/lib/pi-core/firmware

echo "::: pi-core build on $(rpm -E '%{_arch}'), Fedora $(rpm -E '%fedora')"

# Fail loudly rather than silently producing an x86 image.
if [[ "$(rpm -E '%{_arch}')" != "aarch64" ]]; then
    echo "FATAL: pi-core is aarch64-only, got $(rpm -E '%{_arch}'). Build with --platform=linux/arm64." >&2
    exit 1
fi

### 1. Overlay static files
cp -avf /ctx/system_files/. /

### 2. Stash the Raspberry Pi firmware + U-Boot inside the image
#
# bootc/bootupd only manage /boot/efi/EFI, but a Pi needs firmware, DTBs,
# config.txt and u-boot.bin at the *root* of the ESP. Until bootupd grows
# support (coreos/bootupd#766, PR #935 still open), we keep a copy of the
# firmware in /usr/lib and reconcile it to the ESP by hand via
# `pi-core-firmware sync`. See docs/design-decisions.md.
#
# bcm283x-firmware Requires bcm2711/bcm2712/bcm2835-firmware + overlays, so
# this single payload covers Pi 3, 4 and 5.
dnf5 install -y bcm283x-firmware uboot-images-armv8

mkdir -p "${FW_STASH}"
cp -a /boot/efi/. "${FW_STASH}/"
# Fedora's config.txt says `kernel=rpi-u-boot.bin`, so match that name.
cp -P /usr/share/uboot/rpi_arm64/u-boot.bin "${FW_STASH}/rpi-u-boot.bin"

# Let config.txt have a say in the display, which is where a Pi user expects to
# find it. Fedora sets disable_fw_kms_setup=1, which stops the firmware setting
# up the display and passing a mode to the kernel.
#
# Expect this to change the U-Boot and GRUB screens but NOT the kernel console:
# the firmware passes its mode by appending video= to the kernel command line,
# and GRUB builds that line itself from the BLS entry. Measured on a Pi 4,
# /chosen/bootargs is byte-identical to /proc/cmdline and carries GRUB's
# BOOT_IMAGE=, so GRUB is what writes it. The video= kargs stay in place for
# that reason; see docs/design-decisions.md for how to test which one wins.
sed -i 's/^disable_fw_kms_setup=1/#disable_fw_kms_setup=1  # pi-core: let config.txt drive the display/' \
    "${FW_STASH}/config.txt"
cat >> "${FW_STASH}/config.txt" <<'CFGEOF'

# pi-core: keep the boot-time framebuffer readable on 1440p and 4K panels.
# Edit these for custom hardware; they take effect from the next boot.
framebuffer_width=1280
framebuffer_height=720
CFGEOF

# Record what we shipped so the on-device checker can compare versions.
rpm -q bcm283x-firmware bcm2711-firmware bcm2712-firmware bcm2835-firmware \
       bcm283x-overlays uboot-images-armv8 > "${FW_STASH}/.versions"

# Drop the packages again; only the stash should survive into the image.
dnf5 remove -y bcm283x-firmware bcm2711-firmware bcm2712-firmware \
                bcm2835-firmware bcm283x-overlays uboot-images-armv8

# /boot must be completely empty in a bootc image — it is populated at install
# time. The firmware packages created /boot/efi; take the directory with it,
# or `bootc container lint` warns nonempty-boot.
rm -rf /boot/efi

### 3. mDNS, so <hostname>.local resolves on the LAN
#
# The published image is meant to be reachable with nothing but a flashed card:
# no serial console, no per-device config, no DHCP-lease archaeology. That needs
# a responder (avahi publishes), and nss-mdns so this host can resolve other
# .local names too. Firewalld's zone override in system_files opens 5353.
dnf5 install -y avahi nss-mdns

# nss-mdns only takes effect once mdns4_minimal is in nsswitch's hosts line,
# which authselect owns. Use its feature flag so a later `authselect apply`
# on the device does not quietly drop it; fall back to editing the file if no
# profile is selected in the build container.
if authselect enable-feature with-mdns4; then
    echo "::: mdns4 enabled via authselect"
else
    echo "::: no authselect profile; patching /etc/nsswitch.conf directly"
    sed -i 's/^\(hosts:.*\)resolve/\1mdns4_minimal [NOTFOUND=return] resolve/' /etc/nsswitch.conf
fi
grep -E '^hosts:' /etc/nsswitch.conf

### 4. The core user
#
# Ignition created this on the old installer image. A pre-rebased image has no
# Ignition, so the account has to exist in the image itself. Declared in
# sysusers.d rather than by useradd: a bare /etc/passwd entry trips
# `bootc container lint`. systemd-sysusers materialises it here so the account
# is in the image, not created on first boot.
#
# No home directory: /home is a symlink to /var/home, /var is not part of a
# bootc image, and writing into it trips the lint too. tmpfiles.d creates it.
#
# The password is the published default and is meant to be. chpasswd hashes it
# with the system default (yescrypt), so no hashing tool is needed at build
# time and no credential-shaped string is committed.
DEFAULT_PASSWORD="${PI_DEFAULT_PASSWORD:-core}"
systemd-sysusers /usr/lib/sysusers.d/pi-core.conf
echo "core:${DEFAULT_PASSWORD}" | chpasswd
echo "::: created user core (password: ${DEFAULT_PASSWORD})"

### 5. Drop device trees for boards this image excludes
#
# The kernel ships 2386 DTBs covering every aarch64 board Fedora supports, and
# every one of them is copied into /boot for each deployment. That is 56-83 MB
# a deployment out of a 384 MB boot partition that bootc does not let us
# resize, and it is why a real Pi failed to stage an update with
#   Installing kernel: Copying rk3588-armsom-sige7.dtb: No space left on device
# Keeping only Broadcom brings a deployment down to about 110 MB, so two fit.
#
# Safe because this image is Pi-only by design; tests/image-assertions.sh still
# requires the Pi 3/4/5 DTBs, which fails loudly if this prunes too much.
for dtbdir in /usr/lib/modules/*/dtb; do
    [[ -d "${dtbdir}" ]] || continue
    before=$(du -sm "${dtbdir}" | cut -f1)
    find "${dtbdir}" -mindepth 1 -maxdepth 1 ! -name broadcom -exec rm -rf {} +
    after=$(du -sm "${dtbdir}" | cut -f1)
    echo "::: pruned $(basename "$(dirname "${dtbdir}")") device trees: ${before} MB -> ${after} MB"
done

### 6. Stop CoreOS synthesising a /boot mount that cannot exist
#
# bootc install lays down two partitions, ESP and root, so /boot is a plain
# directory inside the root filesystem and there is nothing to mount. But
# coreos-boot-mount-generator synthesises a /boot mount unit pointing at
# /dev/disk/by-label/boot whenever there is no boot= karg -- and bootc's config
# sets boot-mount-spec = "" precisely so that karg is omitted. No such device
# exists, so boot.mount hangs on the device timeout, local-fs.target fails and
# most of userspace follows it down. Seen on a Pi 4.
#
# The generator exits early if fstab already covers /boot (its line 16), so an
# fstab entry is the documented way out. It has to be a real one: the image's
# own /boot is empty -- bootc container lint requires that -- and the running
# root is a composefs built from the image, so the deployment's /boot is empty
# too. The kernels and BLS entries live in the physical root at /sysroot/boot,
# which on Fedora CoreOS is what the boot partition mount exposes. With no boot
# partition, a bind is what exposes it.
cat > /etc/fstab <<'FSTABEOF'
# bootc install to-disk creates no separate boot partition, so /boot is a
# directory in the physical root and the deployment cannot see it on its own.
# This bind exposes it, and doubles as the fstab entry that stops
# coreos-boot-mount-generator inventing a mount for a LABEL=boot that does not
# exist here. Removing it hangs the boot and leaves /boot empty.
/sysroot/boot /boot none bind 0 0

# /var likewise. It is the stateful half of an ostree system and must be
# writable, but the deployment root is composefs and immutable, so an unmounted
# /var means every write lands on a read-only filesystem: tmpfiles cannot create
# /var/home, NetworkManager cannot store state, and the machine comes up with no
# network. The real thing is in the stateroot; Fedora CoreOS binds it during an
# Ignition firstboot, which is exactly what this image does not have.
/sysroot/ostree/deploy/fedora-coreos/var /var none bind 0 0
FSTABEOF

### 7. Enable units
# Enablement lives in /usr/lib/systemd/system-preset/10-pi-core.preset, not
# here: `systemctl enable` writes to /etc, and the deployment's /etc is
# regenerated from presets at install time, so it would be silently dropped.
#
# Zincati is masked in /usr rather than with `systemctl mask`, for the same
# reason -- mask writes /etc/systemd/system/zincati.service -> /dev/null and
# that would go the same way. A unit symlinked to /dev/null is masked wherever
# the symlink lives. It fights a bootc image and retries forever;
# rpm-ostreed-automatic stages updates instead.
ln -sf /dev/null /usr/lib/systemd/system/zincati.service

### 8. Cleanup
# Beyond the usual: dnf leaves /run/dnf (nonempty-run-tmp) and per-repo
# `countme` state under /var/lib/dnf/repos with no tmpfiles.d entry
# (var-tmpfiles). Both trip bootc container lint.
dnf5 clean all
# authselect records a checksum under /var, which trips bootc's var-tmpfiles
# lint (a plain file in /var with no tmpfiles.d entry). The nsswitch.conf it
# generated lives in /etc and survives; only the bookkeeping goes.
rm -rf /var/cache/* /var/log/* /tmp/* /run/dnf /var/lib/dnf/repos /var/lib/authselect || true

echo "::: pi-core build complete; firmware stash:"
find "${FW_STASH}" -maxdepth 1 -printf '%f\n' | sort | head -20
