#!/bin/bash
# Render ignition/pi.bu.in -> build/pi.ign using the butane container.
#
# There is one config: the one baked into the published image. It carries no
# SSH key and nothing per-device, because the only supported install is to
# flash the published image and configure the machine after logging in.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./pi-core.env

HOSTNAME_="${PI_HOSTNAME:-pi-core}"
REPO_ORGANIZATION="${REPO_ORGANIZATION:-$(./scripts/repo-owner.sh)}"
IMAGE="ghcr.io/${REPO_ORGANIZATION}/${IMAGE_NAME}:${DEFAULT_TAG}"
DEFAULT_PASSWORD="${PI_DEFAULT_PASSWORD:-core}"

# Hashed at render time rather than committed, so the repository never contains
# something shaped like a credential. The password itself is public either way.
if command -v mkpasswd >/dev/null 2>&1; then
    PASSWORD_HASH="$(mkpasswd -m yescrypt "${DEFAULT_PASSWORD}")"
else
    # No mkpasswd on a stock GitHub runner. SHA-512 is weaker than yescrypt but
    # shadow understands it everywhere, and it guards a published password.
    PASSWORD_HASH="$(openssl passwd -6 "${DEFAULT_PASSWORD}")"
fi

mkdir -p build
# Hashes and image refs contain no "|", so plain sed is safe here.
sed -e "s|@HOSTNAME@|${HOSTNAME_}|g" \
    -e "s|@IMAGE@|${IMAGE}|g" \
    -e "s|@PASSWORD_HASH@|${PASSWORD_HASH}|g" \
    ignition/pi.bu.in > build/pi.bu

podman run --rm -i quay.io/coreos/butane:release --strict < build/pi.bu > build/pi.ign

echo "wrote build/pi.ign"
echo "  hostname : ${HOSTNAME_}"
echo "  rebase to: ${IMAGE}"
echo "  login    : core / ${DEFAULT_PASSWORD}"
echo "             Password auth is on and the image publishes mDNS, so these"
echo "             credentials are reachable by anything on the LAN for as"
echo "             long as they are left in place."
