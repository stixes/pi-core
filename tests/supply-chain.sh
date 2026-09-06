#!/bin/bash
# Tier 1.5 — verify the PUBLISHED image: signature, and that it can be pulled
# with no credentials at all (the Pi's Ignition rebase depends on that).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh
# shellcheck disable=SC1091
set -a; source ./pi-core.env; set +a

REPO_ORGANIZATION="${REPO_ORGANIZATION:-$(./scripts/repo-owner.sh)}"
REPO="${REPO_ORGANIZATION}/${IMAGE_NAME}"
# CI verifies the tag the run just published; locally this checks :stable,
# which is what a flashed card actually tracks.
VERIFY_TAG="${VERIFY_TAG:-${DEFAULT_TAG}}"
REMOTE="ghcr.io/${REPO}:${VERIFY_TAG}"

head_ "signature"
if [[ -r cosign.pub ]]; then
    if cosign verify --key cosign.pub "$REMOTE" >/tmp/cv.out 2>&1; then
        pass "cosign verify against cosign.pub"
    else
        fail "cosign verify failed"; sed 's/^/      /' /tmp/cv.out | tail -5
    fi
else
    fail "cosign.pub missing from the repo"
fi

head_ "anonymous pullability"
# No credentials: exactly what the Pi has during the first-boot rebase.
TOKEN=$(curl -fsS --max-time 20 "https://ghcr.io/token?scope=repository:${REPO}:pull&service=ghcr.io" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)
CODE=$(curl -s -o /tmp/mf.json -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json" \
    "https://ghcr.io/v2/${REPO}/manifests/${VERIFY_TAG}")
if [[ "$CODE" == "200" ]]; then pass "unauthenticated manifest fetch returns 200"; else fail "unauthenticated fetch returned HTTP $CODE (package private?)"; fi

head_ "published image config"
if [[ "$CODE" == "200" ]]; then
    CFG=$(python3 -c 'import json;print(json.load(open("/tmp/mf.json"))["config"]["digest"])' 2>/dev/null || true)
    if [[ -n "$CFG" ]]; then
        curl -sL --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
            "https://ghcr.io/v2/${REPO}/blobs/${CFG}" > /tmp/cfg.json || true
        A=$(python3 -c 'import json;d=json.load(open("/tmp/cfg.json"));print(d.get("architecture"))' 2>/dev/null || echo "?")
        B=$(python3 -c 'import json;d=json.load(open("/tmp/cfg.json"));print((d.get("config",{}).get("Labels") or {}).get("ostree.bootable"))' 2>/dev/null || echo "?")
        if [[ "$A" == "arm64" ]]; then pass "published architecture is arm64"; else fail "published architecture is $A"; fi
        if [[ "$B" == "1" ]]; then pass "published image is ostree.bootable"; else fail "ostree.bootable is '$B'"; fi
    else
        fail "could not read config digest from the manifest"
    fi
else
    skip "config checks (manifest unavailable)"
fi

summary "tier 1.5"
