# pi-core
include pi-core.env
export

IMAGE := $(IMAGE_NAME):$(DEFAULT_TAG)
REMOTE := ghcr.io/$(REPO_ORGANIZATION)/$(IMAGE_NAME):$(DEFAULT_TAG)

.PHONY: help build inspect ignition firmware flash push clean

help:
	@echo "make build      - build $(IMAGE) for $(PLATFORM) locally (qemu)"
	@echo "make inspect    - show what the built image contains"
	@echo "make ignition   - render build/pi4.ign from ignition/pi4.bu.in"
	@echo "make firmware   - download the Pi firmware payload"
	@echo "make flash DISK=/dev/sdX  - flash FCOS + firmware to a card"
	@echo "make push       - push $(REMOTE) (needs podman login ghcr.io)"

build:
	podman build --platform=$(PLATFORM) \
		--build-arg BASE_IMAGE=$(BASE_IMAGE) \
		--build-arg BASE_TAG=$(BASE_TAG) \
		--build-arg FEDORA_RELEASE=$(FEDORA_RELEASE) \
		-t $(IMAGE) .

inspect:
	podman run --rm --platform=$(PLATFORM) --entrypoint /bin/bash $(IMAGE) -c '\
		echo "== arch =="; uname -m; \
		echo "== os =="; . /etc/os-release && echo "$$PRETTY_NAME"; \
		echo "== firmware stash =="; ls -1 /usr/lib/pi-core/firmware; \
		echo "== versions =="; cat /usr/lib/pi-core/firmware/.versions'

ignition:
	./scripts/render-ignition.sh

firmware:
	./scripts/fetch-firmware.sh

flash: ignition
	@test -n "$(DISK)" || { echo "usage: make flash DISK=/dev/sdX"; exit 1; }
	./scripts/flash.sh $(DISK)

push:
	podman push $(IMAGE) $(REMOTE)

clean:
	rm -rf build
