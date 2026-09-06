# pi-core — uCore derivative for Raspberry Pi (aarch64)
#
# Built for linux/arm64 only. On an x86_64 host this needs qemu-user-static
# binfmt registered (Fedora Atomic desktops generally already have it).

# These must be declared before the first FROM to be usable in a FROM line.
ARG BASE_IMAGE=ghcr.io/ublue-os/ucore-minimal
ARG BASE_TAG=stable
ARG FEDORA_RELEASE=44
# The GHCR namespace, derived by scripts/repo-owner.sh. The signing policy is
# scoped to ghcr.io/<owner>/pi-core and containers-policy has no wildcard for a
# path segment, so the owner has to be materialised at build time.
ARG REPO_ORGANIZATION=
# The release tag on a release ("v1.20260906"), otherwise `git describe`
# ("v1.20260906-3-g2850264", three commits past it). The banner shows this, so
# a machine can say which build it is running.
ARG PI_CORE_VERSION=unknown
FROM scratch AS ctx
COPY build_files /build_files
COPY system_files /system_files
# The public half of the signing key, so the image can verify its own updates.
COPY cosign.pub /cosign.pub

FROM ${BASE_IMAGE}:${BASE_TAG}

# Re-declare inside this stage: an ARG from before the first FROM is not
# automatically in scope here.
ARG FEDORA_RELEASE
ARG REPO_ORGANIZATION
ARG PI_CORE_VERSION
# The digest of the base this was actually built from. BASE_TAG floats, so two
# builds of one commit are not the same image; recording the digest is what
# lets the weekly rebuild tell "upstream moved" from "nothing to do".
ARG BASE_DIGEST=unknown

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    FEDORA_RELEASE=${FEDORA_RELEASE} \
    REPO_ORGANIZATION=${REPO_ORGANIZATION} \
    PI_CORE_VERSION=${PI_CORE_VERSION} /ctx/build_files/build.sh

RUN ["bootc", "container", "lint"]

# So `skopeo inspect` and the registry UI can say which build a digest is.
LABEL org.opencontainers.image.version="${PI_CORE_VERSION}"
LABEL org.opencontainers.image.base.digest="${BASE_DIGEST}"
