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

mkdir -p build
sed -e "s|@SSH_PUBKEY@|${PUBKEY}|g" \
    -e "s|@HOSTNAME@|${HOSTNAME_}|g" \
    -e "s|@IMAGE@|${IMAGE}|g" \
    ignition/pi.bu.in > build/pi.bu

podman run --rm -i quay.io/coreos/butane:release --strict < build/pi.bu > build/pi.ign

echo "wrote build/pi.ign"
echo "  hostname : ${HOSTNAME_}"
echo "  rebase to: ${IMAGE}"
echo "  ssh key  : ${SSH_PUBKEY_FILE}"
