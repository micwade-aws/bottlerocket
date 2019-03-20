.DEFAULT_GOAL := all

OS := thar
TOPDIR := $(strip $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST)))))
SPEC2VAR ?= $(TOPDIR)/bin/spec2var
SPEC2PKG ?= $(TOPDIR)/bin/spec2pkg

SPECS = $(wildcard packages/*/*.spec)
VARS = $(SPECS:.spec=.makevar)
PKGS = $(SPECS:.spec=.makepkg)

OUTPUT ?= $(TOPDIR)/build
OUTVAR := $(shell mkdir -p $(OUTPUT))
DATE := $(shell date --rfc-3339=date)

ARCHES := x86_64 aarch64

DOCKER ?= docker

BUILDKIT_VER = v0.4.0
BUILDKITD_ADDR ?= tcp://127.0.0.1:1234
BUILDCTL_DOCKER_RUN = $(DOCKER) run --rm -ti --entrypoint /usr/bin/buildctl --user $(shell id -u):$(shell id -g) --volume $(TOPDIR):$(TOPDIR) --workdir $(TOPDIR) --network host moby/buildkit:$(BUILDKIT_VER)
BUILDCTL ?= $(BUILDCTL_DOCKER_RUN) --addr $(BUILDKITD_ADDR)
BUILDCTL_ARGS := --progress=plain
BUILDCTL_ARGS += --frontend=dockerfile.v0
BUILDCTL_ARGS += --local context=.
BUILDCTL_ARGS += --local dockerfile=.

define build_rpm
	$(eval HASH:= $(shell sha1sum $3 /dev/null | sha1sum - | awk '{printf $$1}'))
	$(eval RPMS:= $(shell echo $3 | tr ' ' '\n' | awk '/.rpm$$/' | tr '\n' ' '))
	@$(BUILDCTL) build \
		--frontend-opt target=rpm \
		--frontend-opt build-arg:PACKAGE=$(1) \
		--frontend-opt build-arg:ARCH=$(2) \
		--frontend-opt build-arg:HASH=$(HASH) \
		--frontend-opt build-arg:RPMS="$(RPMS)" \
		--frontend-opt build-arg:DATE=$(DATE) \
		--exporter=local \
		--exporter-opt output=$(OUTPUT) \
		$(BUILDCTL_ARGS)
endef

define build_image
	$(eval HASH:= $(shell sha1sum $(2) /dev/null | sha1sum - | awk '{print $$1}'))
	@$(BUILDCTL) build \
		--frontend-opt target=builder \
		--frontend-opt build-arg:PACKAGE=$(OS)-$(1)-release \
		--frontend-opt build-arg:ARCH=$(1) \
		--frontend-opt build-arg:HASH=$(HASH) \
		--frontend-opt build-arg:DATE=$(DATE) \
		--exporter=docker \
		--exporter-opt name=$(OS)-builder:$(1) \
		--exporter-opt output=build/$(OS)-$(1)-builder.tar \
		$(BUILDCTL_ARGS)
	@$(DOCKER) load < build/$(OS)-$(1)-builder.tar
	@$(DOCKER) run -t -v /dev:/dev -v $(OUTPUT):/local/output --privileged \
		$(OS)-builder:$(1) \
			--image-name=$(OS)-$(1).img \
			--package-dir=/local/rpms \
			--output-dir=/local/output
endef

empty :=
space := $(empty) $(empty)
comma := ,
list = $(subst $(space),$(comma),$(1))

%.makevar : %.spec $(SPEC2VAR)
	@set -e; $(SPEC2VAR) --spec=$< --arches=$(call list,$(ARCHES)) > $@

%.makepkg : %.spec $(SPEC2PKG)
	@set -e; $(SPEC2PKG) --spec=$< --arches=$(call list,$(ARCHES)) > $@

-include $(VARS)
-include $(PKGS)

.PHONY: all $(ARCHES)

.SECONDEXPANSION:
$(ARCHES): $$($(OS)-$$(@)-release)
	$(eval PKGS:= $(wildcard $(OUTPUT)/$(OS)-$(@)-*.rpm))
	$(call build_image,$@,$(PKGS))

all: $(ARCHES)

.PHONY: clean
clean:
	@rm -f $(OUTPUT)/*.rpm

include $(TOPDIR)/hack/rules.mk