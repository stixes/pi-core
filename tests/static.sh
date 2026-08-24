#!/bin/bash
# Tier 0 — static checks. No image, no registry, no hardware.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh
# Load config here too: running this script directly gets none of just's
# dotenv-load exports, and the ignition check below needs them.
# shellcheck disable=SC1091
set -a; source ./pi-core.env; set +a

head_ "shellcheck"
mapfile -t SCRIPTS < <(printf '%s\n' scripts/*.sh build_files/*.sh system_files/usr/bin/pi-core-firmware)
if command -v shellcheck >/dev/null; then
    for s in "${SCRIPTS[@]}"; do
        if shellcheck -x "$s" >/tmp/sc.out 2>&1; then pass "$s"; else fail "$s"; sed 's/^/      /' /tmp/sc.out | head -20; fi
    done
else
    skip "shellcheck not installed"
fi

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

head_ "ignition"
if ./scripts/render-ignition.sh >/tmp/ign.out 2>&1; then
    pass "butane --strict renders build/pi4.ign"
    if podman run --rm -i quay.io/coreos/ignition-validate:release - < build/pi4.ign >/tmp/iv.out 2>&1; then
        pass "ignition-validate accepts the output"
    else
        fail "ignition-validate rejected the output"; sed 's/^/      /' /tmp/iv.out | head
    fi
    # The rebase target must match the image this repo publishes.
    # SC2031: these come from the top-level source above, not the subshell
    # used by the three-way parse check.
    # shellcheck disable=SC2031
    WANT="ghcr.io/${REPO_ORGANIZATION:?}/${IMAGE_NAME:?}:${DEFAULT_TAG:?}"
    if grep -q "$WANT" build/pi4.ign; then pass "autorebase targets $WANT"; else fail "autorebase does not target $WANT"; fi
else
    fail "butane render failed"; sed 's/^/      /' /tmp/ign.out | head
fi

summary "tier 0"
