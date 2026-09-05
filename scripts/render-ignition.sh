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

# Generic mode renders the config behind the *published* image: no SSH key of
# anyone's, a documented default password, and that password expired so the
# first login has to replace it. Anything personal must stay out of it.
GENERIC="${PI_GENERIC:-0}"
DEFAULT_PASSWORD="${PI_DEFAULT_PASSWORD:-core}"

hash_password() {
    if command -v mkpasswd >/dev/null 2>&1; then
        mkpasswd -m yescrypt "$1"
    else
        # No mkpasswd on a stock GitHub runner. SHA-512 is weaker than yescrypt
        # but is understood by shadow everywhere, and this hash guards a
        # password that is printed in the README anyway.
        openssl passwd -6 "$1"
    fi
}

if [[ "${GENERIC}" == "1" ]]; then
    PUBKEY=""
    PASSWORD_HASH="${PI_PASSWORD_HASH:-$(hash_password "${DEFAULT_PASSWORD}")}"
else
    [[ -r "${SSH_PUBKEY_FILE}" ]] || { echo "no SSH pubkey at ${SSH_PUBKEY_FILE}" >&2; exit 1; }
    PUBKEY="$(< "${SSH_PUBKEY_FILE}")"
    # A console password is optional but strongly recommended when you have no
    # serial console: without it the only way in is SSH, so a machine that boots
    # but does not reach the network is undiagnosable even with a monitor attached.
    #   just password-hash      # or: mkpasswd -m yescrypt
    PASSWORD_HASH="${PI_PASSWORD_HASH:-}"
fi

if [[ -n "${PUBKEY}" ]]; then
    SSH_KEYS_LINE="      ssh_authorized_keys:"
    SSH_KEY_ITEM="        - \"${PUBKEY}\""
else
    SSH_KEYS_LINE=""
    SSH_KEY_ITEM=""
fi

if [[ -n "${PASSWORD_HASH}" ]]; then
    PASSWORD_LINE="      password_hash: \"${PASSWORD_HASH}\""
else
    PASSWORD_LINE=""
fi

# A user with neither is a machine nobody can log into. Butane will not catch
# it, so catch it here.
if [[ -z "${PUBKEY}" && -z "${PASSWORD_HASH}" ]]; then
    echo "refusing to render a config with no SSH key and no password: nothing could log in" >&2
    exit 1
fi

mkdir -p build

# Each optional placeholder is a line of its own: fill it in, or delete the
# line. Leaving an empty value behind would produce invalid YAML.
# Base64 keys and crypt hashes contain no "|" or "&", so plain sed is safe here.
sub_or_delete() {
    if [[ -n "$2" ]]; then printf 's|%s|%s|\n' "$1" "$2"
    else printf '/%s/d\n' "$1"; fi
}
{
    printf 's|@HOSTNAME@|%s|g\n' "${HOSTNAME_}"
    printf 's|@IMAGE@|%s|g\n' "${IMAGE}"
    sub_or_delete '@SSH_KEYS_LINE@' "${SSH_KEYS_LINE}"
    sub_or_delete '@SSH_KEY_ITEM@'  "${SSH_KEY_ITEM}"
    sub_or_delete '@PASSWORD_LINE@' "${PASSWORD_LINE}"
} > build/pi.sed
sed -f build/pi.sed ignition/pi.bu.in > build/pi.bu
rm -f build/pi.sed

# The published image must force the default password to be replaced. Appended
# rather than templated: it is one more item on the systemd.units list that
# pi.bu.in ends with, and it has no business existing in a personal build.
if [[ "${GENERIC}" == "1" ]]; then
    cat >> build/pi.bu <<'UNIT'

    - name: pi-core-expire-password.service
      enabled: true
      contents: |
        [Unit]
        Description=Expire the default password so the first login must change it
        ConditionPathExists=!/etc/pi-core-password-expired
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/bin/chage -d 0 core
        ExecStart=/usr/bin/touch /etc/pi-core-password-expired
        [Install]
        WantedBy=multi-user.target
UNIT
fi

podman run --rm -i quay.io/coreos/butane:release --strict < build/pi.bu > build/pi.ign

echo "wrote build/pi.ign"
echo "  hostname : ${HOSTNAME_}"
echo "  rebase to: ${IMAGE}"
if [[ "${GENERIC}" == "1" ]]; then
    echo "  mode     : GENERIC (published image)"
    echo "  ssh key  : none - deliberately"
    echo "  login    : core / ${DEFAULT_PASSWORD}, expired on first login"
    echo "             Password auth is on and the image publishes mDNS, so"
    echo "             these credentials are reachable by anything on the LAN"
    echo "             until that first login changes them."
else
    echo "  ssh key  : ${SSH_PUBKEY_FILE}"
    if [[ -n "${PASSWORD_HASH}" ]]; then
        echo "  console  : password login enabled for user 'core'"
    else
        echo "  console  : SSH KEY ONLY - no password login."
        echo "             With no serial console this leaves a non-networking boot"
        echo "             undiagnosable. Set PI_PASSWORD_HASH=\$(just password-hash)."
    fi
fi
