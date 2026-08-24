# shellcheck shell=bash
# Shared assertion helpers. Sourced by the tier scripts.
# Every check records pass/fail and the script exits non-zero if any failed.
FAILED=0
PASSED=0

pass() { PASSED=$((PASSED+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { FAILED=$((FAILED+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
skip() { printf '  \033[33mskip\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

check() {  # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# expect <desc> <regex> <text> — assert text matches; dump it on failure.
expect() {
    local desc="$1" pat="$2" text="$3"
    if grep -qE -- "$pat" <<<"$text"; then
        pass "$desc"
    else
        fail "$desc"
        printf '%s\n' "$text" | sed 's/^/      /' | head -12
    fi
}

# expect_not <desc> <regex> <text>
expect_not() {
    local desc="$1" pat="$2" text="$3"
    if grep -qE -- "$pat" <<<"$text"; then
        fail "$desc"
        printf '%s\n' "$text" | sed 's/^/      /' | head -12
    else
        pass "$desc"
    fi
}

summary() {
    printf '\n%s: %d passed, %d failed\n' "${1:-tests}" "$PASSED" "$FAILED"
    [[ "$FAILED" -eq 0 ]]
}
