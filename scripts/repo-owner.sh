#!/bin/bash
# Print the GHCR namespace to publish to / verify against.
#
# Deliberately derived rather than committed, so a fork builds and verifies
# its own image without editing anything.
#
# Order: explicit override -> GitHub Actions -> the git remote.
set -euo pipefail

if [[ -n "${REPO_ORGANIZATION:-}" ]]; then
    echo "${REPO_ORGANIZATION}"; exit 0
fi

if [[ -n "${GITHUB_REPOSITORY_OWNER:-}" ]]; then
    echo "${GITHUB_REPOSITORY_OWNER}"; exit 0
fi

REMOTE=$(git remote get-url origin 2>/dev/null || true)
if [[ -n "${REMOTE}" ]]; then
    # git@host:owner/repo.git | https://host/owner/repo.git | ssh://host/owner/repo
    OWNER=$(printf '%s' "${REMOTE}" \
        | sed -E 's#^[^:]+://[^/]+/##; s#^[^@]+@[^:]+:##; s#/[^/]+/?$##; s#\.git$##')
    if [[ -n "${OWNER}" && "${OWNER}" != "${REMOTE}" ]]; then
        echo "${OWNER}"; exit 0
    fi
fi

echo "cannot determine the GHCR owner: no REPO_ORGANIZATION, no GITHUB_REPOSITORY_OWNER, no usable git remote" >&2
echo "set it explicitly, e.g.:  REPO_ORGANIZATION=yourname just push" >&2
exit 1
