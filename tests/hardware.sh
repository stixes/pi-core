#!/bin/bash
# Tier 3 (automated half) — assertions against a BOOTED Pi, over SSH.
#
# Everything before SSH works is a manual test at the console; see
# docs/hardware-acceptance.md Part 1. Run this once you can log in.
#
#   just test-hardware 192.168.1.42
#   just test-hardware core@pi-core
#
# Read-only: it does not upgrade, reboot or touch firmware.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh
# shellcheck disable=SC1091
set -a; source ./pi-core.env; set +a

TARGET="${1:-}"
[[ -n "${TARGET}" ]] || { echo "usage: tests/hardware.sh [user@]host" >&2; exit 2; }
[[ "${TARGET}" == *@* ]] || TARGET="core@${TARGET}"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
# SC2029: the command is assembled locally on purpose — these are fixed
# strings, not user input.
# shellcheck disable=SC2029
rc() { ssh "${SSH_OPTS[@]}" "${TARGET}" "$@" 2>/dev/null; }
# shellcheck disable=SC2029
rq() { ssh "${SSH_OPTS[@]}" "${TARGET}" "$@" >/dev/null 2>&1; }

head_ "connectivity"
if rq true; then pass "ssh to ${TARGET}"; else fail "cannot ssh to ${TARGET}"; summary "tier 3"; exit 1; fi

head_ "identity"
MODEL=$(rc "grep -m1 ^Model /proc/cpuinfo | cut -d: -f2- | xargs" || true)
REV=$(rc "grep -m1 ^Revision /proc/cpuinfo | awk '{print \$3}'" || true)
KERNEL=$(rc "uname -r" || true)
echo "      model:    ${MODEL:-unknown}"
echo "      revision: ${REV:-unknown}"
echo "      kernel:   ${KERNEL:-unknown}"

BOOTED=$(rc "sudo bootc status --json 2>/dev/null | grep -oE '\"?ghcr[^\"middle ]*pi-core[^\" ]*' | head -1" || true)
[[ -z "$BOOTED" ]] && BOOTED=$(rc "sudo bootc status 2>/dev/null | grep -oE 'ghcr\.io/[^ ]*pi-core[^ ]*' | head -1" || true)
if [[ "${BOOTED}" == *"pi-core"* ]]; then
    pass "booted image is pi-core (${BOOTED})"
else
    fail "booted image is not pi-core: '${BOOTED:-<none>}' — did the autorebase run?"
fi

head_ "booted digest matches the published image"
OWNER="${REPO_ORGANIZATION:-$(./scripts/repo-owner.sh)}"
REMOTE_DIGEST=$(skopeo inspect "docker://ghcr.io/${OWNER}/${IMAGE_NAME}:${DEFAULT_TAG}" 2>/dev/null | jq -r .Digest 2>/dev/null || true)
LOCAL_DIGEST=$(rc "sudo bootc status --json 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' | head -1" || true)
if [[ -n "${REMOTE_DIGEST}" && "${LOCAL_DIGEST}" == "${REMOTE_DIGEST}" ]]; then
    pass "running the current published digest"
elif [[ -n "${LOCAL_DIGEST}" ]]; then
    skip "digest ${LOCAL_DIGEST:0:19}… != published ${REMOTE_DIGEST:0:19}… (fine if a newer build landed since)"
else
    fail "could not read the booted digest"
fi

head_ "system state"
STATE=$(rc "systemctl is-system-running" || true)
if [[ "${STATE}" == "running" ]]; then
    pass "systemctl is-system-running = running"
else
    fail "system state is '${STATE}'"
    rc "systemctl --failed --no-legend" | sed 's/^/      /'
fi

head_ "expected runtime"
check "docker works"        rq "sudo docker info"
check "tailscale present"   rq "command -v tailscale"
check "podman present"      rq "command -v podman"
ZINC=$(rc "systemctl is-enabled zincati.service" || true)
if [[ "${ZINC}" == "masked" ]]; then pass "zincati is masked"; else fail "zincati is '${ZINC}', expected masked"; fi

head_ "networking (RP1 on Pi 5)"
if rq "ip -br link show | grep -qE '^(end|eth)'"; then
    pass "an ethernet interface exists"
else
    fail "no ethernet interface — on Pi 5 this means rp1_pci did not bind"
fi
USBC=$(rc "lsusb 2>/dev/null | wc -l" || echo 0)
if [[ "${USBC:-0}" -gt 0 ]]; then pass "USB enumerates (${USBC} devices)"; else skip "no USB devices listed"; fi

head_ "firmware tooling"
check "pi-core-firmware runs" rq "pi-core-firmware check"
if rq "journalctl -b 0 -u pi-core-firmware-check.service --no-pager | grep -q ."; then
    pass "firmware-check unit logged at boot"
else
    fail "no output from pi-core-firmware-check.service this boot"
fi
echo "      --- firmware drift report ---"
rc "pi-core-firmware check" | sed 's/^/      /'

head_ "signature verification (requirements.md R13)"
# The policy only means anything if the origin enforces it.
SIG=$(rc 'sudo bootc status --format json 2>/dev/null | grep -o "\"signature\":\"[a-zA-Z]*\"" | head -1' || true)
if [[ "$SIG" == *containerPolicy* ]]; then
    pass "booted origin enforces the container policy"
else
    fail "booted origin signature is '${SIG:-unknown}' — the policy is bypassed"
fi
# Evaluates the policy against the registry without staging anything. This is
# the check that would catch a policy that looks right and rejects everything.
if rq 'sudo bootc upgrade --check'; then
    pass "bootc upgrade --check passes the policy"
else
    fail "bootc upgrade --check failed — the machine cannot take updates"
fi
# A locally modified policy.json is never replaced by an image update, so a fix
# shipped in a later image would silently never arrive.
if rq 'sudo ostree admin config-diff 2>/dev/null | grep -q containers/policy.json'; then
    fail "policy.json is locally modified — image updates to it will never land"
else
    pass "policy.json is unmodified, so image updates to it will land"
fi
# The only silent failure mode: unattended updates fail into the journal and
# the machine just stops updating.
if rq 'systemctl is-failed --quiet rpm-ostreed-automatic.service'; then
    fail "rpm-ostreed-automatic has failed — unattended updates are not running"
else
    pass "rpm-ostreed-automatic is not in a failed state"
fi

head_ "observations to record"
echo "      uptime:   $(rc uptime -p)"
echo "      thermal:  $(rc 'cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo n/a')"
echo "      memory:   $(rc "free -h | awk '/^Mem:/{print \$2\" total, \"\$3\" used\"}'")"

summary "tier 3 (over ssh)"
