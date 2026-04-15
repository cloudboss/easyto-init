PROJECT = $(shell basename ${PWD})
OS = $(shell uname | tr [:upper:] [:lower:])
VERSION =
DIR_OUT = _output

DIR_STG = $(DIR_OUT)/staging
DIR_STG_INIT = $(DIR_STG)/init
DIRS_STG_CLEAN = $(DIR_STG_INIT)

ifneq ($(MAKECMDGOALS), clean)
include $(DIR_OUT)/Makefile.inc
endif

# Override Makefile.inc for Zig build.
ZIG_VERSION = 0.15.2
CTR_IMAGE_BASE = ghcr.io/cloudboss/docker.io/library/alpine:3.23.2
CTR_IMAGE_BASE_SHA256 = $(shell echo -n $(CTR_IMAGE_BASE) | sha256sum | awk '{print $$1}')
ZIG_VERSION_SHA256 = $(shell echo -n $(ZIG_VERSION) | sha256sum | awk '{print $$1}')
DOCKERFILE_SHA256 = $(shell sha256sum Dockerfile.build | awk '{print $$1}')
DOCKER_INPUTS_SHA256 = $(shell echo -n $(UID_SHA256)$(GID_SHA256)$(CTR_IMAGE_BASE_SHA256)$(ZIG_VERSION_SHA256)$(DOCKERFILE_SHA256) | \
	sha256sum | awk '{print $$1}' | cut -c 1-40)
CTR_IMAGE_LOCAL = $(PROJECT):$(DOCKER_INPUTS_SHA256)
HAS_IMAGE_LOCAL = $(DIR_OUT)/.image-local-$(DOCKER_INPUTS_SHA256)

$(HAS_IMAGE_LOCAL): $(HAS_COMMAND_DOCKER) | $(DIR_OUT)/dockerbuild/
	@docker build \
		--build-arg FROM=$(CTR_IMAGE_BASE) \
		--build-arg GID=$(GID) \
		--build-arg UID=$(UID) \
		--build-arg ZIG_VERSION=$(ZIG_VERSION) \
		-f $(DIR_ROOT)/Dockerfile.build \
		-t $(CTR_IMAGE_LOCAL) \
		$(DIR_OUT)/dockerbuild
	@touch $(HAS_IMAGE_LOCAL)
# End override.

CTR_IMAGE_LOCALSTACK = ghcr.io/cloudboss/docker.io/localstack/localstack:4.14.0

DIR_RELEASE = $(DIR_OUT)/release

EASYTO_ASSETS_RELEASES = https://github.com/cloudboss/easyto-assets/releases/download
EASYTO_ASSETS_VERSION = v0.5.1
EASYTO_ASSETS_BUILD = easyto-assets-build-$(EASYTO_ASSETS_VERSION)
EASYTO_ASSETS_BUILD_ARCHIVE = $(EASYTO_ASSETS_BUILD).tar.gz
EASYTO_ASSETS_BUILD_URL = $(EASYTO_ASSETS_RELEASES)/$(EASYTO_ASSETS_VERSION)/$(EASYTO_ASSETS_BUILD_ARCHIVE)

EASYTO_ASSETS_RUNTIME = easyto-assets-runtime-$(EASYTO_ASSETS_VERSION)
EASYTO_ASSETS_RUNTIME_ARCHIVE = $(EASYTO_ASSETS_RUNTIME).tar.gz
EASYTO_ASSETS_RUNTIME_URL = $(EASYTO_ASSETS_RELEASES)/$(EASYTO_ASSETS_VERSION)/$(EASYTO_ASSETS_RUNTIME_ARCHIVE)

.DEFAULT_GOAL = build

FORCE:

$(DIR_OUT):
	@mkdir -p $(DIR_OUT)

$(DIR_OUT)/Makefile.inc: FORCE $(DIR_OUT)/$(EASYTO_ASSETS_BUILD_ARCHIVE)
	@tar -zx --xform "s|^$(EASYTO_ASSETS_BUILD)/./|$(DIR_OUT)/tmp-|" \
		-f $(DIR_OUT)/$(EASYTO_ASSETS_BUILD_ARCHIVE) \
		$(EASYTO_ASSETS_BUILD)/./Makefile.inc
	@cmp -s $(DIR_OUT)/tmp-Makefile.inc $(DIR_OUT)/Makefile.inc 2>/dev/null && \
		rm -f $(DIR_OUT)/tmp-Makefile.inc || \
		mv $(DIR_OUT)/tmp-Makefile.inc $(DIR_OUT)/Makefile.inc

$(DIR_OUT)/$(EASYTO_ASSETS_BUILD_ARCHIVE): | $(HAS_COMMAND_CURL) $(DIR_OUT)
	@curl -L -o $(DIR_OUT)/$(EASYTO_ASSETS_BUILD_ARCHIVE) $(EASYTO_ASSETS_BUILD_URL)

$(DIR_OUT)/$(EASYTO_ASSETS_RUNTIME_ARCHIVE): | $(HAS_COMMAND_CURL) $(DIR_OUT)
	@curl -L -o $(DIR_OUT)/$(EASYTO_ASSETS_RUNTIME_ARCHIVE) $(EASYTO_ASSETS_RUNTIME_URL)

$(DIR_OUT)/$(EASYTO_ASSETS_RUNTIME)/: $(DIR_OUT)/$(EASYTO_ASSETS_RUNTIME_ARCHIVE)
	@tar -zxf $(DIR_OUT)/$(EASYTO_ASSETS_RUNTIME_ARCHIVE) -C $(DIR_OUT)

$(DIR_OUT)/vmlinuz: $(DIR_OUT)/$(EASYTO_ASSETS_RUNTIME)/
	@tar -xf $(DIR_OUT)/$(EASYTO_ASSETS_RUNTIME)/kernel.tar -C $(DIR_OUT) --strip-components=2 ./boot/ && \
		mv $$(ls $(DIR_OUT)/vmlinuz-*) $(DIR_OUT)/vmlinuz

$(DIR_STG_INIT)/$(DIR_ET)/sbin/init: \
		$(DIR_OUT)/zig-out-release/bin/init | $(DIR_STG_INIT)/$(DIR_ET)/sbin/
	@install -m 0755 $(DIR_OUT)/zig-out-release/bin/init $(DIR_STG_INIT)/$(DIR_ET)/sbin/init

ZIG_BUILD_FLAGS = --cache-dir $(DIR_OUT)/zig-cache --global-cache-dir $(DIR_OUT)/zig-cache

ZIG_SOURCES = build.zig build.zig.zon $(shell find src -type f -name '*.zig')

$(DIR_OUT)/zig-out/bin/init: $(HAS_IMAGE_LOCAL) $(ZIG_SOURCES)
	@docker run --rm -t \
		-v $(DIR_ROOT):/code:Z \
		-w /code \
		$(CTR_IMAGE_LOCAL) /bin/sh -cx "zig build -Doptimize=ReleaseSafe $(ZIG_BUILD_FLAGS) --prefix $(DIR_OUT)/zig-out"

$(DIR_OUT)/zig-out-release/bin/init: $(HAS_IMAGE_LOCAL) $(ZIG_SOURCES)
	@docker run --rm -t \
		-v $(DIR_ROOT):/code:Z \
		-w /code \
		$(CTR_IMAGE_LOCAL) /bin/sh -cx "zig build -Doptimize=ReleaseFast $(ZIG_BUILD_FLAGS) --prefix $(DIR_OUT)/zig-out-release"

build: $(DIR_OUT)/zig-out/bin/init

$(DIR_OUT)/init.tar: \
		$(DIR_STG_INIT)/$(DIR_ET)/sbin/init \
		| $(HAS_COMMAND_FAKEROOT) $(DIR_STG_ASSETS)/
	@cd $(DIR_STG_INIT) && fakeroot tar cf $(DIR_ROOT)/$(DIR_OUT)/init.tar .

$(DIR_RELEASE)/easyto-init-$(VERSION).tar.gz: \
		$(DIR_OUT)/init.tar \
		| $(HAS_COMMAND_FAKEROOT) $(DIR_RELEASE)/
	@[ -n "$(VERSION)" ] || (echo "VERSION is required"; exit 1)
	@[ $$(echo $(VERSION) | cut -c 1) = v ] || (echo "VERSION must begin with a 'v'"; exit 1)
	@cd $(DIR_OUT) && \
		fakeroot tar -cz \
		--xform "s|^|easyto-init-$(VERSION)/|" \
		-f $(DIR_ROOT)/$(DIR_RELEASE)/easyto-init-$(VERSION).tar.gz init.tar

test: $(HAS_IMAGE_LOCAL)
	@docker run --rm -t \
		-v $(DIR_ROOT):/code:Z \
		-w /code \
		$(CTR_IMAGE_LOCAL) /bin/sh -cx "zig build test $(ZIG_BUILD_FLAGS)"

DOCKER_GID = $(shell getent group docker | cut -d: -f3)
KVM_GID = $(shell getent group kvm | cut -d: -f3)

test-integration: \
		$(HAS_IMAGE_LOCAL) \
		$(DIR_OUT)/zig-out/bin/init \
		$(DIR_OUT)/$(EASYTO_ASSETS_RUNTIME)/ \
		$(DIR_OUT)/vmlinuz
	@docker run --rm -t \
		-v $(DIR_ROOT):/code:Z \
		-v /var/run/docker.sock:/var/run/docker.sock \
		--group-add $(DOCKER_GID) \
		--security-opt label=type:container_runtime_t \
		-e INIT_BINARY=$(DIR_OUT)/zig-out/bin/init \
		-e CTR_IMAGE_LOCALSTACK=$(CTR_IMAGE_LOCALSTACK) \
		-e CTR_IMAGE_ALPINE=$(CTR_IMAGE_BASE) \
		-e EASYTO_ASSETS_VERSION=$(EASYTO_ASSETS_VERSION) \
		-e VERBOSE=$(VERBOSE) \
		-e SCENARIO=$(SCENARIO) \
		-e KEEP_LOGS=$(KEEP_LOGS) \
		-w /code \
		$(CTR_IMAGE_LOCAL) /bin/sh -c "./tests/integration/run.sh"

test-integration-kvm: \
		$(HAS_IMAGE_LOCAL) \
		$(DIR_OUT)/zig-out/bin/init \
		$(DIR_OUT)/$(EASYTO_ASSETS_RUNTIME)/ \
		$(DIR_OUT)/vmlinuz
	@docker run --rm -t \
		-v $(DIR_ROOT):/code:Z \
		-v /var/run/docker.sock:/var/run/docker.sock \
		--group-add $(DOCKER_GID) \
		--group-add $(KVM_GID) \
		--security-opt label=type:container_runtime_t \
		--device=/dev/kvm \
		-e INIT_BINARY=$(DIR_OUT)/zig-out/bin/init \
		-e CTR_IMAGE_LOCALSTACK=$(CTR_IMAGE_LOCALSTACK) \
		-e CTR_IMAGE_ALPINE=$(CTR_IMAGE_BASE) \
		-e EASYTO_ASSETS_VERSION=$(EASYTO_ASSETS_VERSION) \
		-e VERBOSE=$(VERBOSE) \
		-e SCENARIO=$(SCENARIO) \
		-e KEEP_LOGS=$(KEEP_LOGS) \
		-w /code \
		$(CTR_IMAGE_LOCAL) /bin/sh -c "./tests/integration/run.sh"

release: $(DIR_RELEASE)/easyto-init-$(VERSION).tar.gz

clean:
	@rm -rf $(DIR_OUT)

.PHONY: build test test-integration test-integration-kvm release clean
