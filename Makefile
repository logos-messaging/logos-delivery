# Copyright (c) 2022 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

include Nat.mk
include BearSSL.mk

LINK_PCRE := 0
FORMAT_MSG := "\\x1B[95mFormatting:\\x1B[39m"
BUILD_MSG := "Building:"

# Determine the OS
detected_OS := $(shell uname -s)
ifneq (,$(findstring MINGW,$(detected_OS)))
  detected_OS := Windows
endif

REQUIRED_NIMBLE_VERSION := $(shell grep -E '^const RequiredNimbleVersion\s*=' logos_delivery.nimble | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' | tr -d '"')
REQUIRED_NIMBLE_REVISION := $(shell grep -E '^const RequiredNimbleRevision\s*=' logos_delivery.nimble | grep -oE '"[0-9a-f]{40}"' | tr -d '"')

# Put the revision-specific Nimble directory before ~/.nimble/bin.
# `nimble setup` may update package links under ~/.nimble/bin, including
# the `nimble` link. The revision-specific directory is outside that update
# path. Keep ~/.nimble/bin later on PATH for tools such as nph.
NIMBLE_TOOLDIR := $(HOME)/.local/nimble-$(REQUIRED_NIMBLE_REVISION)/bin
export PATH := $(NIMBLE_TOOLDIR):$(HOME)/.nimble/bin:$(PATH)

# NIM binary location
NIM_BINARY := $(shell which nim 2>/dev/null)

NIMBLE := nimble

# Nimble accepts the generated value only in attached --requires:<value>
# form; a separate argument leaves the constraints unapplied.
NIMBLE_TASK_FLAGS = --useSystemNim --requires:"$$(cat requires.generated)"

NIMBLEDEPS_STAMP := nimbledeps/.nimble-setup

# Compilation parameters
#
# NIM_PARAMS is the flag list the build receives. Make assembles it in this
# order, and Nim keeps the last definition of a define, so a later entry wins
# over an earlier one:
#
#   1. NIM_PARAMS from the environment, the caller's own contribution.
#   2. the project's own flags, added through the rest of this file.
#   3. NIMFLAGS from the caller, added at the end, so the caller wins.
#
# This file exports NIM_PARAMS, and several targets recurse: test, audit-deps,
# the C library rebuilds, Android and iOS. A sub-make inherits the assembled
# value, so appending to it again would add every project flag a second time.
#
# NIM_PARAMS_CALLER records step 1 alone. It is set only when it does not
# already exist, so the first make captures the caller's value and every
# sub-make inherits that same value rather than the assembled one. NIM_PARAMS
# is then rebuilt from it, discarding whatever a sub-make inherited. Assembly
# is therefore idempotent: a sub-make computes the same list as its parent, at
# any depth.
#
# It is set with := and guarded by origin rather than written ?=, because ?=
# creates a recursively expanded variable.
#
# A NIM_PARAMS on the make command line is unaffected by this. Make gives a
# command line variable precedence over every assignment in this file, so it
# replaces the whole list, the project's own flags included.
ifeq ($(origin NIM_PARAMS_CALLER),undefined)
  NIM_PARAMS_CALLER := $(NIM_PARAMS)
endif
export NIM_PARAMS_CALLER
NIM_PARAMS := $(NIM_PARAMS_CALLER)

# V selects verbosity. Callers pass V=1. Nat.mk uses HANDLE_OUTPUT to
# silence the sub-makes.
V := 0
NIM_PARAMS := $(NIM_PARAMS) --verbosity:$(V)
HANDLE_OUTPUT :=
ifeq ($(V), 0)
  NIM_PARAMS := $(NIM_PARAMS) --hints:off
  HANDLE_OUTPUT := >/dev/null
endif

# The Jenkins jobs expose LOG_LEVEL as a build parameter.
ifdef LOG_LEVEL
  NIM_PARAMS := $(NIM_PARAMS) -d:chronicles_log_level="$(LOG_LEVEL)"
endif

ifeq ($(detected_OS),Windows)
  MINGW_PATH = /mingw64
  NIM_PARAMS += --passC:"-I$(MINGW_PATH)/include"
  NIM_PARAMS += --passL:"-L$(MINGW_PATH)/lib"
  LIBS = -lws2_32 -lbcrypt -liphlpapi -luserenv -lntdll -lpq
  NIM_PARAMS += $(foreach lib,$(LIBS),--passL:"$(lib)")
  NIM_PARAMS += --passL:"-Wl,--allow-multiple-definition"
  export PATH := /c/msys64/usr/bin:/c/msys64/mingw64/bin:/c/msys64/usr/lib:/c/msys64/mingw64/lib:$(PATH)
endif

##########
## Main ##
##########
# The Makefile automatically bootstraps dependency setup when needed for build and test targets.
.PHONY: all test clean examples deps nimble install-nim install-nimble print-nimble-path

# default target
all: | wakunode2 logosdeliverynode liblogosdelivery

examples: | example2 chat2 chat2bridge

test_file := $(word 2,$(MAKECMDGOALS))
define test_name
$(shell echo '$(MAKECMDGOALS)' | cut -d' ' -f3-)
endef

test:
ifeq ($(strip $(test_file)),)
	$(MAKE) testcommon
	$(MAKE) testwaku
else
	$(MAKE) compile-test TEST_FILE="$(test_file)" TEST_NAME="$(call test_name)"
endif

# `make test <file> [name]` passes the file and the name as extra goals. Absorb
# them here so make does not look for targets by those names. Any other unknown
# target must still fail, or a stale invocation succeeds while doing nothing.
ifeq ($(firstword $(MAKECMDGOALS)),test)
%:
	@true
endif

logos_delivery.nims:
	ln -s logos_delivery.nimble $@

# Generate supplemental requirements for `nimble setup` from:
# - package versions and revisions recorded in nimble.lock;
# - URLs already declared in logos_delivery.nimble, which are omitted from
#   the generated string to avoid adding a second constraint; and
# - registry URL and version-tag refs observed by the generator.
#
# When the registry URL and version tag both match the lock entry, the
# generator emits "name == version" (e.g. chronos == 4.2.4). Otherwise it
# emits "url#revision" (e.g. nim-secp256k1: no usable version tag).
#
# This ignored file is regenerated when absent or older than a listed
# prerequisite. `make clean` removes it. CI invokes the generator directly
# on every dependency-setup run.
requires.generated: nimble.lock logos_delivery.nimble nix/deps.nix scripts/gen_requires.nims | install-nimble
	nim e --hints:off scripts/gen_requires.nims

$(NIMBLEDEPS_STAMP): requires.generated logos_delivery.nimble | install-nimble build-nph logos_delivery.nims
	# Options come after the command: Nimble reads pre-command options on
	# custom tasks as compilation options. --useSystemNim uses the Nim
	# compiler on PATH and omits Nim from the local dependency installation.
	# Custom task invocations use the same option through NIMBLE_TASK_FLAGS.
	$(NIMBLE) setup --localdeps -y --useSystemNim --requires:"$$(cat requires.generated)"

	$(MAKE) audit-deps

	touch $@

# Compare the installed package set and vcsRevision metadata with
# nimble.lock. This detects the observed Nimble 0.24.1 case where a
# solve exits successfully after selecting a different special revision.
# The setup rule runs it after `nimble setup`, and CI runs it again after
# the build and test steps, because custom tasks also solve and can
# install. See scripts/audit_deps.nims for the matching rules.
.PHONY: audit-deps
audit-deps:
	nim e --hints:off scripts/audit_deps.nims

# Must be phony so the recipe always runs and the sub-make re-evaluates
# BEARSSL_NIMBLEDEPS_DIR / NAT_TRAVERSAL_NIMBLEDEPS_DIR (parse-time variables)
# after nimble setup has populated nimbledeps/.
.PHONY: build-deps
build-deps: | $(NIMBLEDEPS_STAMP)
	$(MAKE) rebuild-bearssl-nimbledeps rebuild-nat-libs-nimbledeps

clean:
	rm -f requires.generated observed.generated 2> /dev/null || true
	rm -rf build 2> /dev/null || true
	rm -rf nimbledeps 2> /dev/null || true
	rm -fr nimcache 2> /dev/null || true
	rm nimble.paths 2> /dev/null || true
	nimble clean

REQUIRED_NIM_VERSION    := $(shell grep -E '^const RequiredNimVersion\s*=' logos_delivery.nimble | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' | tr -d '"')

install-nim:
ifneq ($(detected_OS),Windows)
	scripts/install_nim.sh $(REQUIRED_NIM_VERSION)
endif

install-nimble: install-nim
	scripts/install_nimble.sh $(REQUIRED_NIMBLE_VERSION) $(REQUIRED_NIMBLE_REVISION)

build:
	mkdir -p build

nimble: install-nimble

# The build system puts NIMBLE_TOOLDIR first on PATH for its own invocations.
# Print it so a shell can use the same Nimble.
print-nimble-path:
	@echo "$(NIMBLE_TOOLDIR)"

## Possible values: prod; debug
TARGET ?= prod

## Git version
GIT_VERSION ?= $(shell git describe --abbrev=6 --always --tags)
NIM_PARAMS := $(NIM_PARAMS) -d:git_version=\"$(GIT_VERSION)\"

## Heaptracker options
HEAPTRACKER ?= 0
HEAPTRACKER_INJECT ?= 0
ifeq ($(HEAPTRACKER), 1)
TARGET := debug-with-heaptrack
ifeq ($(HEAPTRACKER_INJECT), 1)
HEAPTRACK_PARAMS := -d:heaptracker -d:heaptracker_inject
NIM_PARAMS := $(NIM_PARAMS) -d:heaptracker -d:heaptracker_inject
else
HEAPTRACK_PARAMS := -d:heaptracker
NIM_PARAMS := $(NIM_PARAMS) -d:heaptracker
endif
endif

# Debug/Release mode
ifeq ($(DEBUG), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:release -d:lto_incremental -d:strip
else
NIM_PARAMS := $(NIM_PARAMS) -d:debug
endif

NIM_PARAMS := $(NIM_PARAMS) -d:disable_libbacktrace

# enable experimental exit is dest feature in libp2p mix
NIM_PARAMS := $(NIM_PARAMS) -d:libp2p_mix_experimental_exit_is_dest

# enable libp2p's QUIC transport
NIM_PARAMS := $(NIM_PARAMS) -d:libp2p_quic_support

ifeq ($(POSTGRES), 1)
NIM_PARAMS := $(NIM_PARAMS) -d:postgres -d:nimDebugDlOpen
endif

ifeq ($(DEBUG_DISCV5), 1)
NIM_PARAMS := $(NIM_PARAMS) -d:debugDiscv5
endif

# Callers set NIMFLAGS. The README, the workflows, the Jenkinsfiles and the
# Dockerfiles use it. Only NIM_PARAMS reaches the build, so add NIMFLAGS to it
# here, after the defines it may conflict with. Nim uses the last
# definition of a define.
NIM_PARAMS := $(NIM_PARAMS) $(NIMFLAGS)

# Export NIM_PARAMS so nimble can access it
export NIM_PARAMS

##################
## Dependencies ##
##################
.PHONY: deps

FOUNDRY_VERSION := 1.5.0
PNPM_VERSION := 10.23.0

rustup:
ifeq (, $(shell which cargo))
	curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable
endif

rln-deps: rustup
	./scripts/install_rln_tests_dependencies.sh $(FOUNDRY_VERSION) $(PNPM_VERSION)

deps: | nimble

##################
##     RLN      ##
##################
.PHONY: librln

LIBRLN_BUILDDIR := $(CURDIR)/vendor/zerokit
LIBRLN_VERSION := v2.0.2

ifeq ($(detected_OS),Windows)
LIBRLN_FILE ?= rln.lib
else
LIBRLN_FILE ?= librln_$(LIBRLN_VERSION).a
endif

$(LIBRLN_FILE):
	git submodule update --init vendor/zerokit
	echo -e $(BUILD_MSG) "$@" && \
		bash scripts/build_rln.sh $(LIBRLN_BUILDDIR) $(LIBRLN_VERSION) $(LIBRLN_FILE)

librln: | $(LIBRLN_FILE)
	$(eval NIM_PARAMS += --passL:$(LIBRLN_FILE) --passL:-lm)

clean-librln:
	cargo clean --manifest-path vendor/zerokit/rln/Cargo.toml
	rm -f $(LIBRLN_FILE)

clean: | clean-librln

#################
## Waku Common ##
#################
.PHONY: testcommon

testcommon: | build-deps build
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) testcommon $(NIMBLE_TASK_FLAGS)

##########
## Waku ##
##########
.PHONY: testwaku wakunode2 logosdeliverynode testwakunode2 example2 chat2 chat2bridge liteprotocoltester

testwaku: | build-deps build rln-deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) test $(NIMBLE_TASK_FLAGS)

# Windows: build with nim directly — `nimble <task>` re-clones git deps every
# build and they intermittently hang on the MSYS2 runner. Flags mirror logos_delivery.nimble.
wakunode2: | build-deps build deps librln
ifeq ($(detected_OS),Windows)
	echo -e $(BUILD_MSG) "build/$@" && \
		nim c --out:build/wakunode2 --mm:refc --cpu:amd64 -d:chronicles_log_level=TRACE $(NIM_PARAMS) apps/wakunode2/wakunode2.nim
else
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) wakunode2 $(NIMBLE_TASK_FLAGS)
endif

# Windows: build with nim directly — `nimble <task>` re-clones git deps every
# build and they intermittently hang on the MSYS2 runner. Flags mirror logos_delivery.nimble.
logosdeliverynode: | build-deps build deps librln
ifeq ($(detected_OS),Windows)
	echo -e $(BUILD_MSG) "build/$@" && \
		nim c --out:build/logosdeliverynode --mm:refc --cpu:amd64 -d:chronicles_log_level=TRACE $(NIM_PARAMS) apps/logos_delivery_node/logosdeliverynode.nim
else
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) logosdeliverynode $(NIMBLE_TASK_FLAGS)
endif

benchmarks: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) benchmarks $(NIMBLE_TASK_FLAGS)

testwakunode2: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) testwakunode2 $(NIMBLE_TASK_FLAGS)

example2: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) example2 $(NIMBLE_TASK_FLAGS)

chat2: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) chat2 $(NIMBLE_TASK_FLAGS)

chat2mix: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) chat2mix $(NIMBLE_TASK_FLAGS)

rln-db-inspector: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) rln_db_inspector $(NIMBLE_TASK_FLAGS)

chat2bridge: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) chat2bridge $(NIMBLE_TASK_FLAGS)

liteprotocoltester: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) liteprotocoltester $(NIMBLE_TASK_FLAGS)

lightpushwithmix: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) lightpushwithmix $(NIMBLE_TASK_FLAGS)

api_example: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nim api_example $(NIM_PARAMS) logos_delivery.nims

build/%: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$*" && \
		$(NIMBLE) buildone $* $(NIMBLE_TASK_FLAGS)

compile-test: | build-deps build deps librln
	echo -e $(BUILD_MSG) "$(TEST_FILE)" "\"$(TEST_NAME)\"" && \
		$(NIMBLE) buildTest $(NIMBLE_TASK_FLAGS) $(TEST_FILE) && \
		$(NIMBLE) execTest $(NIMBLE_TASK_FLAGS) $(TEST_FILE) "\"$(TEST_NAME)\""

################
## Waku tools ##
################
.PHONY: tools wakucanary networkmonitor

tools: networkmonitor wakucanary

wakucanary: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) wakucanary $(NIMBLE_TASK_FLAGS)

networkmonitor: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) networkmonitor $(NIMBLE_TASK_FLAGS)

############
## Format ##
############
.PHONY: build-nph install-nph print-nph-path

build-nph: | build deps
ifneq ($(detected_OS),Windows)
	if command -v nph > /dev/null 2>&1; then \
		echo "nph already installed, skipping"; \
	else \
		echo "Installing nph globally"; \
		(cd /tmp && nimble install nph@0.7.0 --accept -g); \
	fi
	command -v nph
else
	echo "Skipping nph build on Windows (nph is only used on Unix-like systems)"
endif

GIT_PRE_COMMIT_HOOK := .git/hooks/pre-commit

install-nph: build-nph
ifeq ("$(wildcard $(GIT_PRE_COMMIT_HOOK))","")
	cp ./scripts/git_pre_commit_format.sh $(GIT_PRE_COMMIT_HOOK)
else
	echo "$(GIT_PRE_COMMIT_HOOK) already present, will NOT override"
	exit 1
endif

nph/%: | build-nph
	echo -e $(FORMAT_MSG) "nph/$*" && \
		"$$(command -v nph)" $*

print-nph-path:
	@command -v nph

clean:

###################
## Documentation ##
###################
.PHONY: docs coverage

docs: | build-deps build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) doc --run --index:on --project --out:.gh-pages logos-delivery/logos-delivery.nim logos_delivery.nims $(NIMBLE_TASK_FLAGS)

coverage: | build-deps build rln-deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		LIBRLN_FILE=$(LIBRLN_FILE) ./scripts/run_cov.sh -y

#####################
## Container image ##
#####################
DOCKER_IMAGE_NIMFLAGS ?= -d:chronicles_colors:none -d:insecure -d:postgres

docker-image: MAKE_TARGET ?= wakunode2
docker-image: DEBUG ?= 0
docker-image: DOCKER_IMAGE_TAG ?= $(MAKE_TARGET)-$(GIT_VERSION)
docker-image: DOCKER_IMAGE_NAME ?= wakuorg/nwaku:$(DOCKER_IMAGE_TAG)
docker-image:
	docker build \
		--build-arg="MAKE_TARGET=$(MAKE_TARGET)" \
		--build-arg="NIMFLAGS=$(DOCKER_IMAGE_NIMFLAGS)" \
		--build-arg="DEBUG=$(DEBUG)" \
		--build-arg="LOG_LEVEL=$(LOG_LEVEL)" \
		--build-arg="HEAPTRACK_BUILD=$(HEAPTRACKER)" \
		--label="commit=$(shell git rev-parse HEAD)" \
		--label="version=$(GIT_VERSION)" \
		--target $(TARGET) \
		--tag $(DOCKER_IMAGE_NAME) .

docker-quick-image: MAKE_TARGET ?= wakunode2
docker-quick-image: DOCKER_IMAGE_TAG ?= $(MAKE_TARGET)-$(GIT_VERSION)
docker-quick-image: DOCKER_IMAGE_NAME ?= wakuorg/nwaku:$(DOCKER_IMAGE_TAG)
docker-quick-image: NIM_PARAMS := $(NIM_PARAMS) -d:chronicles_colors:none -d:insecure -d:postgres --passL:$(LIBRLN_FILE) --passL:-lm
docker-quick-image: | build librln wakunode2
	docker build \
		--build-arg="MAKE_TARGET=$(MAKE_TARGET)" \
		--tag $(DOCKER_IMAGE_NAME) \
		--target $(TARGET) \
		--file docker/binaries/Dockerfile.bn.local \
		.

docker-push:
	docker push $(DOCKER_IMAGE_NAME)

####################################
## Container lite-protocol-tester ##
####################################
DOCKER_LPT_NIMFLAGS ?= -d:chronicles_colors:none -d:insecure

docker-liteprotocoltester: DOCKER_LPT_TAG ?= latest
docker-liteprotocoltester: DOCKER_LPT_NAME ?= wakuorg/liteprotocoltester:$(DOCKER_LPT_TAG)
docker-liteprotocoltester:
	docker build \
		--build-arg="MAKE_TARGET=liteprotocoltester" \
		--build-arg="NIMFLAGS=$(DOCKER_LPT_NIMFLAGS)" \
		--label="commit=$(shell git rev-parse HEAD)" \
		--label="version=$(GIT_VERSION)" \
		--target $(if $(filter deploy,$(DOCKER_LPT_TAG)),deployment_lpt,standalone_lpt) \
		--tag $(DOCKER_LPT_NAME) \
		--file apps/liteprotocoltester/Dockerfile.liteprotocoltester.compile \
		.

docker-quick-liteprotocoltester: DOCKER_LPT_TAG ?= latest
docker-quick-liteprotocoltester: DOCKER_LPT_NAME ?= wakuorg/liteprotocoltester:$(DOCKER_LPT_TAG)
docker-quick-liteprotocoltester: | liteprotocoltester
	docker build \
		--tag $(DOCKER_LPT_NAME) \
		--file apps/liteprotocoltester/Dockerfile.liteprotocoltester \
		.

docker-liteprotocoltester-push:
	docker push $(DOCKER_LPT_NAME)

################
## C Bindings ##
################
.PHONY: cbindings cwaku_example liblogosdelivery liblogosdelivery_example

detected_OS ?= Linux
ifeq ($(OS),Windows_NT)
detected_OS := Windows
else
detected_OS := $(shell uname -s)
endif

BUILD_COMMAND ?= Dynamic
STATIC ?= 0
ifeq ($(STATIC), 1)
	BUILD_COMMAND = Static
endif

ifeq ($(detected_OS),Windows)
	BUILD_COMMAND := $(BUILD_COMMAND)Windows
else ifeq ($(detected_OS),Darwin)
	BUILD_COMMAND := $(BUILD_COMMAND)Mac
else ifeq ($(detected_OS),Linux)
	BUILD_COMMAND := $(BUILD_COMMAND)Linux
endif

# Windows: build with nim directly (see wakunode2) — `nimble <task>` re-clones
# git deps every build and they intermittently hang on the MSYS2 runner. Flags
# mirror logos_delivery.nimble's dynamic-windows task.
# DISABLE_RLN=true links liblogosdelivery without zerokit: no librln, no Rust,
# no submodule. A node whose config enables RLN then fails to start.
DISABLE_RLN ?= false
ifeq ($(DISABLE_RLN),true)
    LIBLOGOSDELIVERY_RLN_DEP :=
    # Target-specific, so `make DISABLE_RLN=true all` cannot compile the stubs
    # into wakunode2, which still links the real librln.
    liblogosdelivery: NIM_PARAMS += -d:disable_rln
else
    LIBLOGOSDELIVERY_RLN_DEP := librln
endif

liblogosdelivery: | build-deps $(LIBLOGOSDELIVERY_RLN_DEP)
ifeq ($(detected_OS),Windows)
	nim c --out:build/liblogosdelivery.dll --threads:on --app:lib --opt:speed --noMain --mm:refc --header -d:metrics --nimMainPrefix:liblogosdelivery --skipParentCfg:off -d:discv5_protocol_id=d5waku --cpu:amd64 $(NIM_PARAMS) library/liblogosdelivery.nim
else
	$(NIMBLE) --verbose liblogosdelivery$(BUILD_COMMAND) logos_delivery.nimble $(NIMBLE_TASK_FLAGS)
endif

logosdelivery_example: | build liblogosdelivery
	@echo -e $(BUILD_MSG) "build/$@"
ifeq ($(detected_OS),Darwin)
	gcc -o build/$@ \
		library/examples/logosdelivery_example.c \
		library/examples/json_utils.c \
		-I./library \
		-L./build \
		-llogosdelivery \
		-Wl,-rpath,./build
else ifeq ($(detected_OS),Linux)
	gcc -o build/$@ \
		library/examples/logosdelivery_example.c \
		library/examples/json_utils.c \
		-I./library \
		-L./build \
		-llogosdelivery \
		-Wl,-rpath,'$$ORIGIN'
else ifeq ($(detected_OS),Windows)
	gcc -o build/$@.exe \
		library/examples/logosdelivery_example.c \
		library/examples/json_utils.c \
		-I./library \
		-L./build \
		-llogosdelivery \
		-lws2_32
endif

cwaku_example: | build liblogosdelivery
	echo -e $(BUILD_MSG) "build/$@" && \
		cc -o "build/$@" \
		./examples/cbindings/waku_example.c \
		./examples/cbindings/base64.c \
		-llogosdelivery -Lbuild/ \
		-pthread -ldl -lm

cppwaku_example: | build liblogosdelivery
	echo -e $(BUILD_MSG) "build/$@" && \
		g++ -o "build/$@" \
		./examples/cpp/waku.cpp \
		./examples/cpp/base64.cpp \
		-llogosdelivery -Lbuild/ \
		-pthread -ldl -lm

nodejswaku: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		node-gyp build --directory=examples/nodejs/

#####################
## Mobile Bindings ##
#####################
.PHONY: liblogosdelivery-android \
		liblogosdelivery-android-precheck \
		liblogosdelivery-android-arm64 \
		liblogosdelivery-android-amd64 \
		liblogosdelivery-android-x86 \
		liblogosdelivery-android-arm

ANDROID_TARGET ?= 30
ifeq ($(detected_OS),Darwin)
	ANDROID_TOOLCHAIN_DIR := $(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/darwin-x86_64
else
	ANDROID_TOOLCHAIN_DIR := $(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/linux-x86_64
endif

liblogosdelivery-android-precheck:
ifndef ANDROID_NDK_HOME
	$(error ANDROID_NDK_HOME is not set)
endif

# librln and the NDK-built nat-libs must exist before the nim link consumes
# them. PORTABLE_NAT_MARCH is host-derived and invalid for the arm targets.
build-liblogosdelivery-for-android-arch:
	mkdir -p $(CURDIR)/build/android/$(ABIDIR)/
	git submodule update --init vendor/zerokit
	./scripts/build_rln_android.sh $(CURDIR)/build $(LIBRLN_BUILDDIR) $(LIBRLN_VERSION) $(CROSS_TARGET) $(ABIDIR)
	$(MAKE) rebuild-nat-libs-nimbledeps CC=$(ANDROID_TOOLCHAIN_DIR)/bin/$(ANDROID_COMPILER) PORTABLE_NAT_MARCH=
	CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_ARCH=$(ANDROID_ARCH) ANDROID_COMPILER=$(ANDROID_COMPILER) ANDROID_TOOLCHAIN_DIR=$(ANDROID_TOOLCHAIN_DIR) $(NIMBLE) libLogosDeliveryAndroid $(NIMBLE_TASK_FLAGS)

liblogosdelivery-android-arm64: ANDROID_ARCH=aarch64-linux-android
liblogosdelivery-android-arm64: CPU=arm64
liblogosdelivery-android-arm64: ABIDIR=arm64-v8a
liblogosdelivery-android-arm64: | liblogosdelivery-android-precheck build deps build-deps
	$(MAKE) build-liblogosdelivery-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

liblogosdelivery-android-amd64: ANDROID_ARCH=x86_64-linux-android
liblogosdelivery-android-amd64: CPU=amd64
liblogosdelivery-android-amd64: ABIDIR=x86_64
liblogosdelivery-android-amd64: | liblogosdelivery-android-precheck build deps build-deps
	$(MAKE) build-liblogosdelivery-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

liblogosdelivery-android-x86: ANDROID_ARCH=i686-linux-android
liblogosdelivery-android-x86: CPU=i386
liblogosdelivery-android-x86: ABIDIR=x86
liblogosdelivery-android-x86: | liblogosdelivery-android-precheck build deps build-deps
	$(MAKE) build-liblogosdelivery-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

liblogosdelivery-android-arm: ANDROID_ARCH=armv7a-linux-androideabi
liblogosdelivery-android-arm: CPU=arm
liblogosdelivery-android-arm: ABIDIR=armeabi-v7a
liblogosdelivery-android-arm: | liblogosdelivery-android-precheck build deps build-deps
	$(MAKE) build-liblogosdelivery-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=armv7-linux-androideabi CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

liblogosdelivery-android:
	$(MAKE) liblogosdelivery-android-amd64
	$(MAKE) liblogosdelivery-android-arm64
	$(MAKE) liblogosdelivery-android-x86

#################
## iOS Bindings #
#################
.PHONY: liblogosdelivery-ios-precheck \
		liblogosdelivery-ios-device \
		liblogosdelivery-ios-simulator \
		liblogosdelivery-ios

IOS_DEPLOYMENT_TARGET ?= 18.0

define get_ios_sdk_path
$(shell xcrun --sdk $(1) --show-sdk-path 2>/dev/null)
endef

liblogosdelivery-ios-precheck:
ifeq ($(detected_OS),Darwin)
	@command -v xcrun >/dev/null 2>&1 || { echo "Error: Xcode command line tools not installed"; exit 1; }
else
	$(error iOS builds are only supported on macOS)
endif

build-liblogosdelivery-for-ios-arch:
	IOS_SDK=$(IOS_SDK) IOS_ARCH=$(IOS_ARCH) IOS_SDK_PATH=$(IOS_SDK_PATH) IOS_DEPLOYMENT_TARGET=$(IOS_DEPLOYMENT_TARGET) $(NIMBLE) libLogosDeliveryIOS $(NIMBLE_TASK_FLAGS)

liblogosdelivery-ios-device: IOS_ARCH=arm64
liblogosdelivery-ios-device: IOS_SDK=iphoneos
liblogosdelivery-ios-device: IOS_SDK_PATH=$(call get_ios_sdk_path,iphoneos)
liblogosdelivery-ios-device: | liblogosdelivery-ios-precheck build-deps build deps
	$(MAKE) build-liblogosdelivery-for-ios-arch IOS_ARCH=$(IOS_ARCH) IOS_SDK=$(IOS_SDK) IOS_SDK_PATH=$(IOS_SDK_PATH)

liblogosdelivery-ios-simulator: IOS_ARCH=arm64
liblogosdelivery-ios-simulator: IOS_SDK=iphonesimulator
liblogosdelivery-ios-simulator: IOS_SDK_PATH=$(call get_ios_sdk_path,iphonesimulator)
liblogosdelivery-ios-simulator: | liblogosdelivery-ios-precheck build-deps build deps
	$(MAKE) build-liblogosdelivery-for-ios-arch IOS_ARCH=$(IOS_ARCH) IOS_SDK=$(IOS_SDK) IOS_SDK_PATH=$(IOS_SDK_PATH)

liblogosdelivery-ios:
	$(MAKE) liblogosdelivery-ios-device
	$(MAKE) liblogosdelivery-ios-simulator

###################
# Release Targets #
###################

release-notes:
	docker run \
		-it \
		--rm \
		-v $${PWD}:/opt/sv4git/repo:z \
		-u $(shell id -u) \
		docker.io/wakuorg/sv4git:latest \
			release-notes |\
			sed -E 's@#([0-9]+)@[#\1](https://github.com/logos-messaging/logos-delivery/issues/\1)@g'
