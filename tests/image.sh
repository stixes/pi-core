#!/bin/bash
# Tier 1 — assertions against the locally built image.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh
# shellcheck disable=SC1091
set -a; source ./pi-core.env; set +a

IMAGE="${IMAGE_NAME}:${DEFAULT_TAG}"

if ! podman image exists "$IMAGE"; then
    echo "no local image '$IMAGE' — run: just build" >&2
    exit 1
fi

head_ "image metadata"
ARCH=$(podman image inspect "$IMAGE" --format '{{.Architecture}}')
if [[ "$ARCH" == "arm64" ]]; then pass "manifest architecture is arm64"; else fail "manifest architecture is $ARCH"; fi
for label in ostree.bootable containers.bootc; do
    V=$(podman image inspect "$IMAGE" --format "{{index .Labels \"$label\"}}")
    if [[ "$V" == "1" ]]; then pass "label $label=1"; else fail "label $label is '$V', expected 1"; fi
done
# The weekly rebuild decides whether upstream moved by comparing this label on
# the published image with the base's current digest. If it goes missing the
# comparison cannot be made, and the job releases every week regardless.
BASED=$(podman image inspect "$IMAGE" --format '{{index .Labels "org.opencontainers.image.base.digest"}}')
if [[ "$BASED" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    pass "the base image digest is recorded: ${BASED:0:19}…"
else
    fail "label org.opencontainers.image.base.digest is '$BASED', not a digest"
fi
summary "tier 1 (metadata)" || exit 1

# Everything else runs inside the image, in one go: each podman run is slow
# under emulation.
podman run --rm --platform="$PLATFORM" \
    -v "$PWD/tests:/tests:ro,z" \
    --entrypoint /bin/bash "$IMAGE" /tests/image-assertions.sh
