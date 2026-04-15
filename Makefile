.PHONY: help build run stop rm-container clean

CONTAINER_RUNTIME ?= docker
IMAGE_NAME ?= windrose-server
IMAGE_TAG ?= latest
IMAGE_REF := $(IMAGE_NAME):$(IMAGE_TAG)
CONTAINER_NAME ?= windrose-server
CONTAINERFILE ?= container/Containerfile
BUILD_CONTEXT ?= container
ENV_FILE ?=
PORT_ARGS ?=
VOLUME_ARGS ?=
RUN_ARGS ?=

help:
	@printf '%s\n' \
		'make build        Build the container image' \
		'make run          Run the container image' \
		'make stop         Stop the running container if present' \
		'make rm-container Remove the named container if present' \
		'make clean        Remove the container and image' \
		'' \
		'Overrides:' \
		'  CONTAINER_RUNTIME=docker|podman' \
		'  IMAGE_NAME=windrose-server IMAGE_TAG=latest' \
		'  CONTAINER_NAME=windrose-server' \
		'  ENV_FILE=.env' \
		'  PORT_ARGS="-p 2456:2456/udp -p 2457:2457/udp"' \
		'  VOLUME_ARGS="-v $$PWD/data:/home/steam/windrose"' \
		'  RUN_ARGS="--rm -it"'

build:
	$(CONTAINER_RUNTIME) build \
		-f $(CONTAINERFILE) \
		-t $(IMAGE_REF) \
		$(BUILD_CONTEXT)

run:
	$(CONTAINER_RUNTIME) run \
		--name $(CONTAINER_NAME) \
		$(if $(ENV_FILE),--env-file $(ENV_FILE),) \
		$(PORT_ARGS) \
		$(VOLUME_ARGS) \
		$(RUN_ARGS) \
		$(IMAGE_REF)

stop:
	-$(CONTAINER_RUNTIME) stop $(CONTAINER_NAME)

rm-container:
	-$(CONTAINER_RUNTIME) rm -f $(CONTAINER_NAME)

clean: rm-container
	-$(CONTAINER_RUNTIME) rmi $(IMAGE_REF)
