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

# Override Makefile.inc.
CTR_IMAGE_RUST = rust:1.82.0-alpine3.20
CTR_IMAGE_RUST_SHA256 = $(shell echo -n $(CTR_IMAGE_RUST) | sha256sum | awk '{print $$1}')
DOCKER_INPUTS_SHA256 = $(shell echo -n $(UID_SHA256)$(GID_SHA256)$(CTR_IMAGE_RUST_SHA256)$(DOCKERFILE_SHA256) | \
	sha256sum | awk '{print $$1}' | cut -c 1-40)

$(HAS_IMAGE_LOCAL): $(HAS_COMMAND_DOCKER) | $(DIR_OUT)/dockerbuild/
	@docker build \
		--build-arg FROM=$(CTR_IMAGE_RUST) \
		--build-arg GID=$(GID) \
		--build-arg UID=$(UID) \
		-f $(DIR_ROOT)/Dockerfile.build \
		-t $(CTR_IMAGE_LOCAL) \
		$(DIR_OUT)/dockerbuild
	@touch $(HAS_IMAGE_LOCAL)
# End override.

DIR_RELEASE = $(DIR_OUT)/release

EASYTO_ASSETS_RELEASES = https://github.com/cloudboss/easyto-assets/releases/download
EASYTO_ASSETS_VERSION = v0.3.0
EASYTO_ASSETS_BUILD = easyto-assets-build-$(EASYTO_ASSETS_VERSION)
EASYTO_ASSETS_BUILD_ARCHIVE = $(EASYTO_ASSETS_BUILD).tar.gz
EASYTO_ASSETS_BUILD_URL = $(EASYTO_ASSETS_RELEASES)/$(EASYTO_ASSETS_VERSION)/$(EASYTO_ASSETS_BUILD_ARCHIVE)

RUST_TARGET = x86_64-unknown-linux-musl

.DEFAULT_GOAL = release

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

$(DIR_STG_INIT)/$(DIR_ET)/sbin/init: \
		$(DIR_OUT)/target/$(RUST_TARGET)/release/init | $(DIR_STG_INIT)/$(DIR_ET)/sbin/
	@install -m 0755 $(DIR_OUT)/target/$(RUST_TARGET)/release/init $(DIR_STG_INIT)/$(DIR_ET)/sbin/init

$(DIR_OUT)/target/$(RUST_TARGET)/release/init: \
		$(HAS_IMAGE_LOCAL) \
		Cargo.toml \
		$(shell find src -type f -path '*.rs') \
		| $(DIR_OUT)/cargo-home/registry/
	@docker run --rm -t \
		-v $(DIR_ROOT):/code \
		-v $(CURDIR)/$(DIR_OUT)/cargo-home/registry:/usr/local/cargo/registry \
		-e CARGO_TARGET_DIR=$(DIR_OUT)/target \
		-w /code \
		$(CTR_IMAGE_LOCAL) /bin/sh -c "cargo build --target $(RUST_TARGET) --release"

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

test: $(HAS_IMAGE_LOCAL) | $(DIR_OUT)/cargo-home/registry/
	@docker run --rm -t \
		-v $(DIR_ROOT):/code \
		-v $(CURDIR)/$(DIR_OUT)/cargo-home/registry:/usr/local/cargo/registry \
		-e CARGO_TARGET_DIR=$(DIR_OUT)/target \
		-w /code \
		$(CTR_IMAGE_LOCAL) /bin/sh -ec "cargo clippy -- -Dwarnings; cargo test"

release: $(DIR_RELEASE)/easyto-init-$(VERSION).tar.gz

clean:
	@rm -rf $(DIR_OUT)

.PHONY: test release clean
