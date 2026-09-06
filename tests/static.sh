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

head_ "nothing carries an owner (requirements.md R15)"
# A fork must publish, verify and link to itself without edits. The banner URLs
# were hardcoded once; this is why they are not now.
if grep -rnE 'github\.com/[A-Za-z0-9_-]+/pi-core|ghcr\.io/[A-Za-z0-9_-]+/pi-core' build_files/ system_files/ scripts/ 2>/dev/null \
   | grep -v 'REPO_ORGANIZATION' | grep -q .; then
    fail "a hardcoded owner is baked into the image:"
    grep -rnE 'github\.com/[A-Za-z0-9_-]+/pi-core|ghcr\.io/[A-Za-z0-9_-]+/pi-core' build_files/ system_files/ scripts/ 2>/dev/null \
        | grep -v 'REPO_ORGANIZATION' | sed 's/^/      /' | head -5
else
    pass "no hardcoded owner in build_files, system_files or scripts"
fi

head_ "signing key and policy scope (requirements.md R13)"
check "cosign.pub present" test -f cosign.pub
if grep -q 'BEGIN PUBLIC KEY' cosign.pub 2>/dev/null; then
    pass "it is a PEM public key"
else
    fail "cosign.pub is not a PEM public key"
fi
# The policy is scoped to ghcr.io/<owner>/pi-core and containers-policy has no
# wildcard for a path segment, so the owner must reach the build.
if grep -q 'build-arg REPO_ORGANIZATION' justfile && grep -q 'build-arg REPO_ORGANIZATION' .github/workflows/build.yml; then
    pass "REPO_ORGANIZATION reaches both the local and CI build"
else
    fail "REPO_ORGANIZATION is not passed to the build — the policy scope would be empty"
fi

head_ "the build can compute a version"
# `git describe --tags` needs tags and history in the *build* job. Without them
# it falls back to a bare sha and the banner ships without a release version --
# which happened, because the edit adding this was a silent no-op.
if awk '/^  build:/,/^  release-image:/' .github/workflows/build.yml | grep -q 'fetch-tags: true'; then
    pass "the build job's checkout fetches tags"
else
    fail "the build job checkout has no fetch-tags — the version would be a bare sha"
fi

head_ "release stream (only a tag moves :stable)"
# :stable is what flashed cards track and what the flashable image is built
# from. If main started publishing it again, every commit would reach every
# device immediately, which is the thing the split exists to prevent.
# shellcheck disable=SC2016  # grepping for the literal ${...} text, not expanding it
if grep -q 'PUBLISH_TAG=${DEFAULT_TAG}' .github/workflows/build.yml \
   && grep -q 'PUBLISH_TAG=${TESTING_TAG}' .github/workflows/build.yml; then
    pass "the workflow chooses between :stable and :testing"
else
    fail "the workflow no longer distinguishes the two tags"
fi
# shellcheck disable=SC2016
if grep -q 'IMAGE_REGISTRY}/${IMAGE_NAME}:${PUBLISH_TAG}' .github/workflows/build.yml; then
    pass "it pushes the chosen tag, not a fixed one"
else
    fail "the push target is not PUBLISH_TAG — main could be publishing :stable"
fi

head_ "documented bootc switch keeps verification on"
# --enforce-container-sigpolicy is opt-in on `switch`: without it the new
# deployment records no policy and the machine silently stops verifying
# updates. Proven on a Pi 4 -- a plain switch staged with signature: None.
BAD=$(grep -rn 'bootc switch' --include='*.md' . 2>/dev/null \
      | grep -v '^\./build/' | grep -v -- '--enforce-container-sigpolicy' || true)
if [[ -n "${BAD}" ]]; then
    fail "a documented 'bootc switch' omits --enforce-container-sigpolicy:"
    printf '      %s\n' "${BAD}" | head -3
else
    pass "every documented switch enforces the signature policy"
fi

head_ "first boot needs no network (requirements.md R3)"
# The installer model pulled a container on first boot and made the network,
# the clock and a registry into boot dependencies. Each of those failed on real
# hardware. This fails the build if one comes back.
if grep -rnE 'rpm-ostree rebase|autorebase' build_files/ system_files/ 2>/dev/null | grep -q .; then
    fail "the image carries a first-boot rebase again — R3 says first boot must not need a registry"
else
    pass "no first-boot rebase in the image"
fi

summary "tier 0"
