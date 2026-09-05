#!/bin/bash
# Tier 0 — static checks. No image, no registry, no hardware.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh
# Load config here too: running this script directly gets none of just's
# dotenv-load exports, and the checks below need them.
# shellcheck disable=SC1091
set -a; source ./pi-core.env; set +a

head_ "shellcheck"
# Run the pinned container rather than whatever shellcheck the host has:
# a version difference between a laptop and CI means green locally, red in CI.
mapfile -t SCRIPTS < <(printf '%s\n' scripts/*.sh build_files/*.sh tests/*.sh system_files/usr/bin/pi-core-firmware)
SHELLCHECK_IMAGE="docker.io/koalaman/shellcheck:v0.11.0"
for s in "${SCRIPTS[@]}"; do
    if podman run --rm -v "$PWD:/mnt:ro,z" -w /mnt "$SHELLCHECK_IMAGE" -x "$s" >/tmp/sc.out 2>&1; then
        pass "$s"
    else
        fail "$s"; sed 's/^/      /' /tmp/sc.out | head -20
    fi
done

head_ "actionlint (workflow syntax + action refs)"
if podman run --rm -v "$PWD:/repo:z" -w /repo docker.io/rhysd/actionlint:latest -color >/tmp/al.out 2>&1; then
    pass "workflows lint clean"
else
    fail "actionlint reported problems"; sed 's/^/      /' /tmp/al.out | head -20
fi

head_ "pi-core.env format"
# The file is read by just's dotenv parser, by `source` in scripts/, and by
# `>> \$GITHUB_ENV` in CI. Quotes and inline comments break at least one of
# them, so require bare KEY=value. See CLAUDE.md.
BAD=$(grep -nE '^[A-Za-z_][A-Za-z0-9_]*=' pi-core.env | grep -vE '^[0-9]+:[A-Za-z_][A-Za-z0-9_]*=[^"'"'"'#[:space:]]*$' || true)
if [[ -z "$BAD" ]]; then
    pass "all assignments are bare KEY=value"
else
    fail "quoted / commented / spaced assignments found:"; printf '      %s\n' "$BAD"
fi

head_ "pi-core.env parses identically three ways"
KEYS=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' pi-core.env)
( set -a; . ./pi-core.env; set +a; for k in $KEYS; do printf '%s=%s\n' "$k" "${!k}"; done ) | sort > /tmp/env.source
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' pi-core.env | sort > /tmp/env.ci
just _print-env 2>/dev/null | sort > /tmp/env.just
if diff -q /tmp/env.source /tmp/env.ci >/dev/null; then pass "shell source == CI \$GITHUB_ENV filter"
else fail "shell source != CI filter"; diff /tmp/env.source /tmp/env.ci | sed 's/^/      /'; fi
if diff -q /tmp/env.source /tmp/env.just >/dev/null; then pass "shell source == just dotenv"
else fail "shell source != just dotenv"; diff /tmp/env.source /tmp/env.just | sed 's/^/      /'; fi

head_ "the image build passes the console kargs"
# These moved from the Ignition config to bootc install --karg. Nothing in the
# built image records them, so this is the only place the promise can be guarded.
for karg in 'console=tty0' 'video=HDMI-A-1:1280x720' 'video=HDMI-A-2:1280x720'; do
    if grep -q -- "$karg" scripts/build-image.sh; then
        pass "passes $karg"
    else
        fail "build-image.sh no longer passes $karg"
    fi
done
if grep -q 'bootc install to-disk' scripts/build-image.sh; then
    pass "installs with bootc (image is pi-core, not an installer)"
else
    fail "build-image.sh does not use bootc install to-disk"
fi

summary "tier 0"
