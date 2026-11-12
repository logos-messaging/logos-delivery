# Copyright (c) 2022 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Determine the OS. The includes read detected_OS, so this comes before them. The MINGW and MSYS shells both report a Windows kernel name here.
# The OS environment variable is not consulted: the MSYS2 runtime drops it,
# along with most of the environment, when a program is started from Git Bash.
detected_OS := $(shell uname -s)
ifneq (,$(filter MINGW% MSYS%,$(detected_OS)))
  detected_OS := Windows
endif

include BearSSL.mk
include TinyCbor.mk

LINK_PCRE := 0
FORMAT_MSG := "\\x1B[95mFormatting:\\x1B[39m"
BUILD_MSG := "Building:"

REQUIRED_NIMBLE_PIN := $(shell grep -E '^const RequiredNimblePin\s*=' logos_delivery.nimble | grep -oE '"[^"]+"' | tr -d '"')

NIMBLE_TOOLDIR := $(HOME)/.local/nimble-$(REQUIRED_NIMBLE_PIN)/bin
NIMBLE := $(NIMBLE_TOOLDIR)/nimble
export PATH := $(NIMBLE_TOOLDIR):$(HOME)/.nimble/bin:$(PATH)

# Passed after every Nimble command, so Nimble uses the locked Nim instead of
# downloading the latest one first. Empty until the first setup has installed it.
NIMBLE_TASK_FLAGS = $(if $(NIM),--nim:$(NIM))

# The Nim that `nimble setup` installs for the locked `nim` entry. Recursive,
# so it resolves after setup has populated nimbledeps/.
NIM = $(firstword $(shell ls -1 $(CURDIR)/nimbledeps/pkgs2/nim-*/bin/nim.exe 2>/dev/null) $(shell ls -1 $(CURDIR)/nimbledeps/pkgs2/nim-*/bin/nim 2>/dev/null))

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

# V selects verbosity. Callers pass V=1.
V := 0
NIM_PARAMS := $(NIM_PARAMS) --verbosity:$(V)
ifeq ($(V), 0)
  NIM_PARAMS := $(NIM_PARAMS) --hints:off
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
  # GNU ld scans static archives left-to-right. librln is appended later by the
  # librln target, so repeat its Windows dependencies after that archive.
  RLN_TRAILING_LIBS = $(LIBS)
  NIM_PARAMS += --passL:"-Wl,--allow-multiple-definition"
  # mingw64/bin before usr/bin, as in the MSYS2 MINGW64 shell: nim-leopard needs
  # the mingw64 cmake for its "MSYS Makefiles" generator, which the msys cmake
  # in usr/bin lacks.
  # Inside MSYS2, use the running install: CI's MSYS2 is not at C:\msys64, and
  # mixing two installs fails with exit 127. Git Bash has none, so use C:\msys64.
  ifneq (,$(wildcard /usr/bin/pacman))
    export PATH := /mingw64/bin:/usr/bin:/mingw64/lib:/usr/lib:$(PATH)
  else
    export PATH := /c/msys64/mingw64/bin:/c/msys64/usr/bin:/c/msys64/mingw64/lib:/c/msys64/usr/lib:$(PATH)
  endif
endif

##########
## Main ##
##########
# The Makefile automatically bootstraps dependency setup when needed for build and test targets.
.PHONY: all test clean examples ffi-examples deps nimble install-nimble print-nimble-path print-nim-path

# default target
all: | logosdeliverynode liblogosdelivery

examples: | example2 chat2 chat2bridge

ffi-examples: | cwaku_example cppwaku_example logosdelivery_example

test_file := $(word 2,$(MAKECMDGOALS))
define test_name
$(shell echo '$(MAKECMDGOALS)' | cut -d' ' -f3-)
endef

test:
ifeq ($(strip $(test_file)),)
	$(MAKE) testcommon
	$(MAKE) testwaku
	$(MAKE) testwakuext
	$(MAKE) testlogosdelivery
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

$(NIMBLEDEPS_STAMP): nimble.lock logos_delivery.nimble | install-nimble logos_delivery.nims
	$(NIMBLE) setup --localdeps -y $(NIMBLE_TASK_FLAGS)

	$(MAKE) audit-deps

	touch $@

# This compares the installed packages with nimble.lock and writes nothing.
.PHONY: audit-deps
audit-deps:
	$(NIMBLE) auditdeps $(NIMBLE_TASK_FLAGS)

# Must be phony so the recipe always runs and the sub-make re-evaluates
# BEARSSL_NIMBLEDEPS_DIR (a parse-time variable)
# after nimble setup has populated nimbledeps/.
.PHONY: build-deps
build-deps: | $(NIMBLEDEPS_STAMP)
	$(MAKE) rebuild-bearssl-nimbledeps

	$(MAKE) audit-deps

clean:
	rm -rf build 2> /dev/null || true
	rm -rf nimbledeps 2> /dev/null || true
	rm -fr nimcache 2> /dev/null || true
	rm nimble.paths 2> /dev/null || true
	if [ -x "$(NIMBLE)" ]; then "$(NIMBLE)" clean; fi

install-nimble:
	scripts/install_nimble.sh $(REQUIRED_NIMBLE_PIN) $(NIMBLE_TOOLDIR)

build:
	mkdir -p build

nimble: install-nimble

# This prints the path of the Nim that Nimble installed, for patching it.
print-nim-path:
	@echo "$(NIM)"

# This prints the directory of the Nimble that make runs, for use in a shell.
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

# TODO: native builds are unsupported until nim-leopard builds Leopard-RS through
# Nim; its cmake step ignores Nim's flags and the native .so does not link.
# CPU baseline. The default is the portable build (see config.nims).
#
# MARCH_NATIVE ?= 0
# ifeq ($(MARCH_NATIVE), 1)
# NIM_PARAMS := $(NIM_PARAMS) -d:marchNative
# endif

# Debug/Release mode
ifeq ($(DEBUG), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:release -d:lto_incremental -d:strip
else
NIM_PARAMS := $(NIM_PARAMS) -d:debug
endif

# Build flags only. Feature defines live in config.nims.
NIM_PARAMS := $(NIM_PARAMS) -d:disable_libbacktrace

ifeq ($(POSTGRES), 1)
NIM_PARAMS := $(NIM_PARAMS) -d:postgres -d:nimDebugDlOpen
endif

ifeq ($(DEBUG_DISCV5), 1)
NIM_PARAMS := $(NIM_PARAMS) -d:debugDiscv5
endif

# Symbols for gdb, lldb and libbacktrace. Off by default. 
# Turn it on to read a core from the C and Rust dependencies.
# macOS needs `ulimit -n 1024` for this build, its default of 512 is too low.
# No effect under DEBUG=0: -d:strip links with -s, which discards them again.
ifeq ($(DEBUG_SYMBOLS), 1)
NIM_PARAMS := $(NIM_PARAMS) --debugger:native
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
	$(eval NIM_PARAMS += --passL:$(LIBRLN_FILE) --passL:-lm $(foreach lib,$(RLN_TRAILING_LIBS),--passL:"$(lib)"))

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
.PHONY: testwaku testwakuext testlogosdelivery logosdeliverynode testapp example2 chat2 chat2bridge liteprotocoltester

testwaku: | build-deps build rln-deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) test $(NIMBLE_TASK_FLAGS)

# Split out of testwaku for the same refc cap as testlogosdelivery below. See
# tests/all_tests_waku_ext.nim.
testwakuext: | build-deps build rln-deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) testwakuext $(NIMBLE_TASK_FLAGS)

# Split out of testwaku: refc caps a binary at 3500 GC-traced globals and the
# combined suite had reached it. See tests/all_tests_logos_delivery.nim.
testlogosdelivery: | build-deps build rln-deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) testlogosdelivery $(NIMBLE_TASK_FLAGS)

# Windows: build with nim directly — `nimble <task>` re-clones git deps every
# build and they intermittently hang on the MSYS2 runner. Flags mirror logos_delivery.nimble.
logosdeliverynode: | build-deps build deps librln
ifeq ($(detected_OS),Windows)
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIM) c --out:build/logosdeliverynode --mm:refc --cpu:amd64 -d:chronicles_log_level=TRACE $(NIM_PARAMS) apps/logos_delivery_node/logosdeliverynode.nim
else
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) logosdeliverynode $(NIMBLE_TASK_FLAGS)
endif

benchmarks: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) benchmarks $(NIMBLE_TASK_FLAGS)

testapp: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) testapp $(NIMBLE_TASK_FLAGS)

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
		$(NIM) api_example $(NIM_PARAMS) logos_delivery.nims

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
.PHONY: tools wakucanary networkmonitor rlnkeystore

tools: networkmonitor wakucanary rlnkeystore

wakucanary: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) wakucanary $(NIMBLE_TASK_FLAGS)

networkmonitor: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) networkmonitor $(NIMBLE_TASK_FLAGS)

rlnkeystore: | build-deps build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(NIMBLE) rlnkeystore $(NIMBLE_TASK_FLAGS)

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
		(cd /tmp && $(NIMBLE) install nph@0.7.0 --accept -g); \
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

.PHONY: lint
lint: | build-nph
	scripts/lint.sh

# Builds the node and the library and fails on any compiler warning raised in
# this repo's code. CI runs the same check on every build and test log.
.PHONY: check-warnings
check-warnings:
	scripts/check_compile_warnings.sh

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

docker-image: DEBUG ?= 0
docker-image: DOCKER_IMAGE_TAG ?= logosdeliverynode-$(GIT_VERSION)
docker-image: DOCKER_IMAGE_NAME ?= wakuorg/nwaku:$(DOCKER_IMAGE_TAG)
docker-image:
	docker build \
		--build-arg="NIMFLAGS=$(DOCKER_IMAGE_NIMFLAGS)" \
		--build-arg="DEBUG=$(DEBUG)" \
		--build-arg="LOG_LEVEL=$(LOG_LEVEL)" \
		--build-arg="HEAPTRACK_BUILD=$(HEAPTRACKER)" \
		--label="commit=$(shell git rev-parse HEAD)" \
		--label="version=$(GIT_VERSION)" \
		--target $(TARGET) \
		--tag $(DOCKER_IMAGE_NAME) .

docker-quick-image: DOCKER_IMAGE_TAG ?= logosdeliverynode-$(GIT_VERSION)
docker-quick-image: DOCKER_IMAGE_NAME ?= wakuorg/nwaku:$(DOCKER_IMAGE_TAG)
docker-quick-image: NIM_PARAMS := $(NIM_PARAMS) -d:chronicles_colors:none -d:insecure -d:postgres --passL:$(LIBRLN_FILE) --passL:-lm
docker-quick-image: | build librln logosdeliverynode rlnkeystore
	docker build \
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

# The library builds with plain `nim c`, as an embedder builds it: the build's
# own flags first, then NIM_PARAMS, so the caller wins. No --skipParentCfg, so
# the repository's config.nims applies too: the CPU baseline, LeopardCmakeFlags
# and nimble.paths. That config sets its own nimcache, so -d:ffiOutputDir is
# passed explicitly.
# $(1): output directory, $(2): library file name, $(3): the build's flags.
define compile_liblogosdelivery
mkdir -p "$(1)"
rm -f "$(1)/$(2)"
"$(NIM)" c -d:ffiOutputDir="$(1)/generated" --nimcache:"$(1)/nimcache" $(3) --out:"$(1)/$(2)" $(NIM_PARAMS) library/liblogosdelivery.nim
cp library/*.h "$(1)/"
endef

LIB_DIR := $(CURDIR)/build
ifeq ($(detected_OS),Windows)
  LIB_SHARED := liblogosdelivery.dll
  LIB_STATIC := liblogosdelivery.lib
else ifeq ($(detected_OS),Darwin)
  LIB_SHARED := liblogosdelivery.dylib
  LIB_STATIC := liblogosdelivery.a
else
  LIB_SHARED := liblogosdelivery.so
  LIB_STATIC := liblogosdelivery.a
endif
# DISABLE_RLN=true builds liblogosdelivery without zerokit: no librln, no Rust,
# no submodule. A node whose config enables RLN then fails to start. Only the
# library recipes use LIB_RLN_PARAMS, so `make DISABLE_RLN=true all` cannot
# compile the stubs into logosdeliverynode, which still links the real librln.
DISABLE_RLN ?= false
ifeq ($(DISABLE_RLN),true)
    LIBLOGOSDELIVERY_RLN_DEP :=
    LIB_RLN_PARAMS := -d:disable_rln
else
    LIBLOGOSDELIVERY_RLN_DEP := librln
    LIB_RLN_PARAMS :=
endif

LIB_NIM_PARAMS := --mm:refc -d:chronicles_line_numbers -d:chronicles_log_level=TRACE $(LIB_RLN_PARAMS)

liblogosdelivery: | build-deps $(LIBLOGOSDELIVERY_RLN_DEP)
ifneq ($(STATIC),1)
	$(call compile_liblogosdelivery,$(LIB_DIR),$(LIB_SHARED),--app:lib $(LIB_NIM_PARAMS))
else
	$(call compile_liblogosdelivery,$(LIB_DIR),$(LIB_STATIC),--app:staticlib $(LIB_NIM_PARAMS))
endif

logosdelivery_example: | build liblogosdelivery tinycbor
	@echo -e $(BUILD_MSG) "build/$@"
ifeq ($(detected_OS),Darwin)
	gcc -o build/$@ \
		library/examples/logosdelivery_example.c \
		library/examples/json_utils.c \
		-I./build \
		-I"$(TINYCBOR_VENDOR_DIR)" \
		-L./build \
		-llogosdelivery \
		$(TINYCBOR_LIB) \
		-Wl,-rpath,./build
else ifeq ($(detected_OS),Linux)
	gcc -o build/$@ \
		library/examples/logosdelivery_example.c \
		library/examples/json_utils.c \
		-I./build \
		-I"$(TINYCBOR_VENDOR_DIR)" \
		-L./build \
		-llogosdelivery \
		$(TINYCBOR_LIB) \
		-Wl,-rpath,'$$ORIGIN'
else ifeq ($(detected_OS),Windows)
	gcc -o build/$@.exe \
		library/examples/logosdelivery_example.c \
		library/examples/json_utils.c \
		-I./build \
		-I"$(TINYCBOR_VENDOR_DIR)" \
		-L./build \
		-llogosdelivery \
		$(TINYCBOR_LIB) \
		-lws2_32
endif

cwaku_example: | build liblogosdelivery tinycbor
	echo -e $(BUILD_MSG) "build/$@" && \
		cc -o "build/$@" \
		./examples/cbindings/waku_example.c \
		./examples/cbindings/base64.c \
		-I./build \
		-I"$(TINYCBOR_VENDOR_DIR)" \
		-llogosdelivery -Lbuild/ $(TINYCBOR_LIB) \
		-pthread -ldl -lm

cppwaku_example: | build liblogosdelivery tinycbor
	echo -e $(BUILD_MSG) "build/$@" && \
		g++ -o "build/$@" \
		./examples/cpp/waku.cpp \
		./examples/cpp/base64.cpp \
		-I./build \
		-I"$(TINYCBOR_VENDOR_DIR)" \
		-llogosdelivery -Lbuild/ $(TINYCBOR_LIB) \
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

# cmake runs on the build host, so left alone it hands Leopard-RS the host's
# toolchain. Point it at the NDK's, and define ANDROID so Leopard-RS takes its
# LEO_TARGET_MOBILE path instead of including <tmmintrin.h>. OpenMP is off: the
# NDK's libomp.so would have to ship with the library.
ANDROID_LIB_DIR = $(CURDIR)/build/android/$(ABIDIR)
ANDROID_CC = $(ANDROID_TOOLCHAIN_DIR)/bin/$(ANDROID_COMPILER)
ANDROID_SYSROOT = $(ANDROID_TOOLCHAIN_DIR)/sysroot
ANDROID_NIM_PARAMS = --os:android --cpu:$(CPU) --cc:clang \
	--clang.path:"$(ANDROID_TOOLCHAIN_DIR)/bin" --clang.exe:$(ANDROID_COMPILER) --clang.linkerexe:$(ANDROID_COMPILER) \
	--passC:--sysroot="$(ANDROID_SYSROOT)" --passL:--sysroot="$(ANDROID_SYSROOT)" \
	-d:"LeopardCmakeFlags=-DCMAKE_BUILD_TYPE=Release -DENABLE_OPENMP=off \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCOMPILER_SUPPORTS_MARCH_NATIVE=FALSE -DCMAKE_SYSTEM_NAME=Linux \
	-DCMAKE_C_COMPILER=$(ANDROID_CC) -DCMAKE_CXX_COMPILER=$(ANDROID_CC)++ -DCMAKE_CXX_FLAGS=-DANDROID \
	-DCMAKE_AR=$(ANDROID_TOOLCHAIN_DIR)/bin/llvm-ar -DCMAKE_RANLIB=$(ANDROID_TOOLCHAIN_DIR)/bin/llvm-ranlib" \
	-d:LeopardExtraCompilerFlags=-fno-openmp -d:LeopardExtraLinkerFlags=-fno-openmp \
	$(if $(filter true,$(DISABLE_RLN)),,--passL:-L"$(ANDROID_LIB_DIR)" --passL:-lrln) \
	--mm:refc -d:chronicles_log_level=ERROR $(LIB_RLN_PARAMS)

# librln must exist before the nim link consumes it.
build-liblogosdelivery-for-android-arch:
	mkdir -p $(ANDROID_LIB_DIR)/
ifneq ($(DISABLE_RLN),true)
	git submodule update --init vendor/zerokit
	./scripts/build_rln_android.sh $(CURDIR)/build $(LIBRLN_BUILDDIR) $(LIBRLN_VERSION) $(CROSS_TARGET) $(ABIDIR)
endif
	$(call compile_liblogosdelivery,$(ANDROID_LIB_DIR),liblogosdelivery.so,--app:lib $(ANDROID_NIM_PARAMS))

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

# Simulator objects need the simulator flag, or Xcode refuses to link them.
IOS_TARGET_FLAGS = -arch $(IOS_ARCH) -isysroot $(IOS_SDK_PATH) \
	$(if $(filter iphonesimulator,$(IOS_SDK)),-mios-simulator-version-min,-mios-version-min)=$(IOS_DEPLOYMENT_TARGET)
IOS_NIM_PARAMS = --os:ios --cpu:$(if $(filter arm64,$(IOS_ARCH)),arm64,amd64) --cc:clang \
	--passC:"$(IOS_TARGET_FLAGS)" --passL:"$(IOS_TARGET_FLAGS)" \
	-d:"LeopardCmakeFlags=-DCMAKE_BUILD_TYPE=Release -DENABLE_OPENMP=off -DCOMPILER_SUPPORTS_MARCH_NATIVE=FALSE \
	-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$(IOS_SDK_PATH) -DCMAKE_OSX_ARCHITECTURES=$(IOS_ARCH) \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=$(IOS_DEPLOYMENT_TARGET)" \
	--mm:refc --opt:size -d:chronicles_log_level=ERROR $(LIB_RLN_PARAMS)

build-liblogosdelivery-for-ios-arch:
	$(call compile_liblogosdelivery,$(CURDIR)/build/ios/$(IOS_SDK)-$(IOS_ARCH),liblogosdelivery.a,--app:staticlib $(IOS_NIM_PARAMS))

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
