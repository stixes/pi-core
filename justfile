# pi-core — see CLAUDE.md for the rules that constrain this project.

set dotenv-load := true
set dotenv-filename := "pi-core.env"
set shell := ["bash", "-euo", "pipefail", "-c"]

# List available recipes
default:
    @just --list --unsorted

# Build the image locally for aarch64 (qemu on x86; slow but works)
build:
    podman build --platform="$PLATFORM" \
        --build-arg BASE_IMAGE="$BASE_IMAGE" \
        --build-arg BASE_TAG="$BASE_TAG" \
        --build-arg FEDORA_RELEASE="$FEDORA_RELEASE" \
        -t "$IMAGE_NAME:$DEFAULT_TAG" .

# Show what the built image contains
inspect:
    podman run --rm --platform="$PLATFORM" --entrypoint /bin/bash \
        "$IMAGE_NAME:$DEFAULT_TAG" -c '\
        echo "== arch =="; rpm -E %{_arch}; \
        echo "== os =="; . /etc/os-release && echo "$PRETTY_NAME"; \
        echo "== firmware stash =="; ls -1 /usr/lib/pi-core/firmware; \
        echo "== versions =="; cat /usr/lib/pi-core/firmware/.versions'

# Download the Raspberry Pi firmware payload
firmware:
    ./scripts/fetch-firmware.sh

# Build the flashable pi-core .img that gets published
image:
    ./scripts/build-image.sh

# Push the locally built image (needs podman login ghcr.io)
push:
    owner="${REPO_ORGANIZATION:-$(./scripts/repo-owner.sh)}"; \
    podman push "$IMAGE_NAME:$DEFAULT_TAG" \
        "ghcr.io/$owner/$IMAGE_NAME:$DEFAULT_TAG"

# Building locally means emulated dnf under qemu: ~25 minutes on x86. So the
# default gate skips anything needing a built image and CI does that instead,
# on a native arm64 runner, in well under a minute.

# The fast local gate (~5 s, no image build) — run this while editing
test: test-static

# Everything runnable locally; needs `just build` first, so expect a wait on x86
test-all: test-static test-image

# Tier 0: linting, config validation, env-file format (seconds)
test-static:
    ./tests/static.sh

# Tier 1: assertions against the locally built image
test-image:
    ./tests/image.sh

# Tier 1.5: verify the *published* image's signature and public pullability
test-supply-chain:
    ./tests/supply-chain.sh

# Tier 3: assertions against a booted Pi over SSH (read-only)
test-hardware HOST:
    ./tests/hardware.sh "{{HOST}}"

# Push this branch and watch CI run the full build + image assertions (~90 s)
ci:
    #!/usr/bin/env bash
    set -euo pipefail
    branch="$(git rev-parse --abbrev-ref HEAD)"
    git push -u origin "$branch"
    # Dispatch explicitly: the workflow's push trigger only covers main, so a
    # branch push alone would run nothing. publish_image stays false, so this
    # builds and tests without cutting a release.
    gh workflow run "Build pi-core" --ref "$branch"
    for _ in $(seq 1 30); do
        id="$(gh run list --workflow 'Build pi-core' --branch "$branch" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
        [[ -n "$id" ]] && break
        sleep 2
    done
    [[ -n "${id:-}" ]] || { echo "no run appeared for $branch" >&2; exit 1; }
    gh run watch "$id" --exit-status

# Used by tests/static.sh to check dotenv parsing agrees with the others
_print-env:
    @for k in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' pi-core.env); do \
        printf '%s=%s\n' "$k" "${!k}"; \
    done

# Check the justfile itself parses and is formatted
check:
    just --fmt --check --unstable

clean:
    rm -rf build
