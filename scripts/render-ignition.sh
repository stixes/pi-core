#!/bin/bash
# Render ignition/pi.bu.in -> build/pi.ign using the butane container.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./pi-core.env

SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_rsa.pub}"
HOSTNAME_="${PI_HOSTNAME:-pi-core}"
REPO_ORGANIZATION="${REPO_ORGANIZATION:-$(./scripts/repo-owner.sh)}"
IMAGE="ghcr.io/${REPO_ORGANIZATION}/${IMAGE_NAME}:${DEFAULT_TAG}"

[[ -r "${SSH_PUBKEY_FILE}" ]] || { echo "no SSH pubkey at ${SSH_PUBKEY_FILE}" >&2; exit 1; }
PUBKEY="$(< "${SSH_PUBKEY_FILE}")"

# A console password is optional but strongly recommended when you have no
# serial console: without it the only way in is SSH, so a machine that boots
# but does not reach the network is undiagnosable even with a monitor attached.
#   just password-hash      # or: mkpasswd -m yescrypt
PASSWORD_HASH="${PI_PASSWORD_HASH:-}"
if [[ -n "${PASSWORD_HASH}" ]]; then
    PASSWORD_LINE="      password_hash: \"${PASSWORD_HASH}\""
else
    PASSWORD_LINE=""
fi

mkdir -p build
sed -e "s|@SSH_PUBKEY@|${PUBKEY}|g" \
    -e "s|@HOSTNAME@|${HOSTNAME_}|g" \
    -e "s|@IMAGE@|${IMAGE}|g" \
    ignition/pi.bu.in > build/pi.bu.tmp
if [[ -n "${PASSWORD_LINE}" ]]; then
    sed -e "s|@PASSWORD_LINE@|${PASSWORD_LINE}|" build/pi.bu.tmp > build/pi.bu
else
    sed -e "/@PASSWORD_LINE@/d" build/pi.bu.tmp > build/pi.bu
fi
rm -f build/pi.bu.tmp

podman run --rm -i quay.io/coreos/butane:release --strict < build/pi.bu > build/pi.ign

echo "wrote build/pi.ign"
echo "  hostname : ${HOSTNAME_}"
echo "  rebase to: ${IMAGE}"
echo "  ssh key  : ${SSH_PUBKEY_FILE}"
if [[ -n "${PASSWORD_HASH}" ]]; then
    echo "  console  : password login enabled for user 'core'"
else
    echo "  console  : SSH ONLY - no console login."
    echo "             With no serial console this leaves a non-networking boot"
    echo "             undiagnosable. Set PI_PASSWORD_HASH=\$(just password-hash)."
fi
