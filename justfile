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

# Render build/pi.ign from the butane template
ignition:
    ./scripts/render-ignition.sh

# Generate a password hash for console login (PI_PASSWORD_HASH)
password-hash:
    @mkpasswd -m yescrypt

# Download the Raspberry Pi firmware payload
firmware:
    ./scripts/fetch-firmware.sh

# DESTRUCTIVE: flash Fedora CoreOS + firmware to a card. No argument = show
# usage and list candidate devices.
flash DISK="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{DISK}}" ]]; then
        exec ./scripts/flash.sh
    fi
    just ignition
    ./scripts/flash.sh "{{DISK}}"

# Push the locally built image (needs podman login ghcr.io)
push:
    owner="${REPO_ORGANIZATION:-$(./scripts/repo-owner.sh)}"; \
    podman push "$IMAGE_NAME:$DEFAULT_TAG" \
        "ghcr.io/$owner/$IMAGE_NAME:$DEFAULT_TAG"

# Everything that can run without hardware or a registry
test: test-static test-provision test-image

# Tier 0: linting, config validation, env-file format (seconds)
test-static:
    ./tests/static.sh

# Unit tests for the headless provisioner's config parsing (no image needed)
test-provision:
    ./tests/provision.sh

# Show what a pi-core.conf would do, without applying it
provision-dry-run CONF:
    PI_CORE_ESP_DIR="$(dirname "{{CONF}}")" bash system_files/usr/bin/pi-core-provision --dry-run

# Tier 1: assertions against the locally built image
test-image:
    ./tests/image.sh

# Tier 1.5: verify the *published* image's signature and public pullability
test-supply-chain:
    ./tests/supply-chain.sh

# Tier 3: assertions against a booted Pi over SSH (read-only)
test-hardware HOST:
    ./tests/hardware.sh "{{HOST}}"

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
