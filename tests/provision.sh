#!/bin/bash
# SC2016: the fixtures here deliberately contain a literal '$' — that is the
# point of the command-substitution safety test and of the password-hash
# format. Do not "fix" them into double quotes. Must sit directly after the
# shebang to apply file-wide.
# shellcheck disable=SC2016
# Tier 0 (unit) — the headless provisioner's config parsing, in --dry-run.
# No hardware, no image, no mutation of this machine.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh

PROV=system_files/usr/bin/pi-core-provision
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# run_conf <file-content> -> output of a dry run against it
run_conf() {
    printf '%s' "$1" > "$WORK/pi-core.conf"
    PI_CORE_ESP_DIR="$WORK" bash "$PROV" --dry-run 2>&1
}

head_ "the shipped example parses cleanly"
OUT=$(PI_CORE_ESP_DIR=provisioning bash -c 'cp provisioning/pi-core.conf.example '"$WORK"'/pi-core.conf; PI_CORE_ESP_DIR='"$WORK"' bash '"$PROV"' --dry-run' 2>&1)
expect_not "no unknown keys — example and script agree" 'unknown key' "$OUT"
expect_not "no malformed lines" 'malformed' "$OUT"

head_ "values are applied"
OUT=$(run_conf 'PI_HOSTNAME=testbox
PI_TIMEZONE=Europe/Copenhagen
PI_SSH_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@example
')
expect "hostname" 'would: hostnamectl set-hostname testbox' "$OUT"
expect "timezone" 'would: timedatectl set-timezone Europe/Copenhagen' "$OUT"
expect "ssh key"  'would: add SSH key' "$OUT"

head_ "an empty or comment-only file is valid"
OUT=$(run_conf '# nothing here
')
expect "no-op, no errors" 'applied=0' "$OUT"

head_ "hostile-ish input is handled, not executed"
OUT=$(run_conf 'PI_HOSTNAME=$(touch '"$WORK"'/PWNED)
NOT_A_KEY=x
this line has no equals sign
')
if [[ -e "$WORK/PWNED" ]]; then fail "SECURITY: value was evaluated"; else pass "command substitution in a value is not executed"; fi
expect "unknown key reported"    "unknown key 'NOT_A_KEY'" "$OUT"
expect "malformed line reported" 'malformed line' "$OUT"

head_ "a plaintext password is refused"
OUT=$(run_conf 'PI_PASSWORD_HASH=hunter2
')
expect "plaintext rejected" 'refusing to set a plaintext password' "$OUT"
OUT=$(run_conf 'PI_PASSWORD_HASH=$y$j9T$abcdefghijklmnop$hash
')
expect "a real hash is accepted" 'would: set console password' "$OUT"

head_ "CRLF from a Windows editor is tolerated"
printf 'PI_HOSTNAME=crlfbox\r\nPI_TIMEZONE=UTC\r\n' > "$WORK/pi-core.conf"
OUT=$(PI_CORE_ESP_DIR="$WORK" bash "$PROV" --dry-run 2>&1)
expect "CR stripped from values" 'would: hostnamectl set-hostname crlfbox' "$OUT"

head_ "dry-run does not mutate"
printf 'PI_PASSWORD_HASH=$y$x$y$z\nPI_WIPE_SECRETS=1\n' > "$WORK/pi-core.conf"
PI_CORE_ESP_DIR="$WORK" bash "$PROV" --dry-run >/dev/null 2>&1
expect "secrets not wiped in dry-run" 'PI_PASSWORD_HASH=\$y' "$(cat "$WORK/pi-core.conf")"
if [[ -e /var/lib/pi-core/provisioned ]]; then skip "sentinel exists on this host"; else pass "no sentinel written"; fi

head_ "a missing config is a no-op, not an error"
rm -f "$WORK/pi-core.conf"
OUT=$(PI_CORE_ESP_DIR="$WORK" bash "$PROV" --dry-run 2>&1); RC=$?
if [[ "$RC" -eq 0 ]]; then pass "exits 0"; else fail "exited $RC"; fi
expect "says so" 'nothing to do' "$OUT"

summary "provisioner unit tests"
