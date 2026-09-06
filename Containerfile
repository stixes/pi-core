# pi-core — uCore derivative for Raspberry Pi (aarch64)
#
# Built for linux/arm64 only. On an x86_64 host this needs qemu-user-static
# binfmt registered (Fedora Atomic desktops generally already have it).

# These must be declared before the first FROM to be usable in a FROM line.
ARG BASE_IMAGE=ghcr.io/ublue-os/ucore-minimal
ARG BASE_TAG=stable
ARG FEDORA_RELEASE=44
FROM scratch AS ctx
COPY build_files /build_files
COPY system_files /system_files

FROM ${BASE_IMAGE}:${BASE_TAG}

# Re-declare inside this stage: an ARG from before the first FROM is not
# automatically in scope here.
ARG FEDORA_RELEASE

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/tmp \
    FEDORA_RELEASE=${FEDORA_RELEASE} /ctx/build_files/build.sh

RUN ["bootc", "container", "lint"]
