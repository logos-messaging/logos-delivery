# Copyright (c) 2022 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

LINK_PCRE := 0
FORMAT_MSG := "\\x1B[95mFormatting:\\x1B[39m"
BUILD_MSG := "\\x1B[92mBuilding:\\x1B[39m"

# Determine the OS
detected_OS := $(shell uname -s)
ifneq (,$(findstring MINGW,$(detected_OS)))
  detected_OS := Windows
endif

# NIM binary location
NIM_BINARY := $(shell which nim)
NPH := $(shell dirname $(NIM_BINARY))/nph

# Compilation parameters
NIM_PARAMS ?=

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
.PHONY: all test update clean examples deps

# default target
all: | wakunode2 libwaku

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

# this prevents make from erroring on unknown targets
%:
	@true

waku.nims:
	ln -s waku.nimble $@

update: | waku.nims
	git submodule update --init --recursive
	nimble setup -y
	$(MAKE) build-nph

clean:
	rm -rf build
	rm -rf ~/.nimble/pkgs2
	rm -rf ~/.nimble/pkgcache

build:
	mkdir -p build

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
NIM_PARAMS := $(NIM_PARAMS) -d:release
else
NIM_PARAMS := $(NIM_PARAMS) -d:debug
endif

ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:disable_libbacktrace
endif

# enable experimental exit is dest feature in libp2p mix
NIM_PARAMS := $(NIM_PARAMS) -d:libp2p_mix_experimental_exit_is_dest

ifeq ($(POSTGRES), 1)
NIM_PARAMS := $(NIM_PARAMS) -d:postgres -d:nimDebugDlOpen
endif

ifeq ($(DEBUG_DISCV5), 1)
NIM_PARAMS := $(NIM_PARAMS) -d:debugDiscv5
endif

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

# Install nimble dependencies
deps: | build waku.nims
	nimble install -d -y

##################
##     RLN      ##
##################
.PHONY: librln

LIBRLN_BUILDDIR := $(CURDIR)/vendor/zerokit
LIBRLN_VERSION := v0.9.0

ifeq ($(detected_OS),Windows)
LIBRLN_FILE ?= rln.lib
else
LIBRLN_FILE ?= librln_$(LIBRLN_VERSION).a
endif

$(LIBRLN_FILE):
	echo -e $(BUILD_MSG) "$@" && \
		./scripts/build_rln.sh $(LIBRLN_BUILDDIR) $(LIBRLN_VERSION) $(LIBRLN_FILE)

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

testcommon: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble testcommon

##########
## Waku ##
##########
.PHONY: testwaku wakunode2 testwakunode2 example2 chat2 chat2bridge liteprotocoltester

testwaku: | build deps rln-deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble test

wakunode2: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble wakunode2

benchmarks: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble benchmarks

testwakunode2: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble testwakunode2

example2: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble example2

chat2: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble chat2

chat2mix: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble chat2mix

rln-db-inspector: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble rln_db_inspector

chat2bridge: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble chat2bridge

liteprotocoltester: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble liteprotocoltester

lightpushwithmix: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble lightpushwithmix

api_example: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim api_example $(NIM_PARAMS) waku.nims

build/%: | build deps librln
	echo -e $(BUILD_MSG) "build/$*" && \
		nimble buildone $*

compile-test: | build deps librln
	echo -e $(BUILD_MSG) "$(TEST_FILE)" "\"$(TEST_NAME)\"" && \
		nimble buildTest $(TEST_FILE) && \
		nimble execTest $(TEST_FILE) "\"$(TEST_NAME)\""

################
## Waku tools ##
################
.PHONY: tools wakucanary networkmonitor

tools: networkmonitor wakucanary

wakucanary: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble wakucanary

networkmonitor: | build deps librln
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble networkmonitor

############
## Format ##
############
.PHONY: build-nph install-nph clean-nph print-nph-path

build-nph: | build deps
ifeq ("$(wildcard $(NPH))","")
	nimble install nph -y
	echo "nph utility is available"
else
	echo "nph utility already exists at " $(NPH)
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
		$(NPH) $*

clean-nph:
	rm -f $(NPH)

print-nph-path:
	@echo "$(NPH)"

clean: | clean-nph

###################
## Documentation ##
###################
.PHONY: docs coverage

docs: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		nimble doc --run --index:on --project --out:.gh-pages waku/waku.nim waku.nims

coverage:
	echo -e $(BUILD_MSG) "build/$@" && \
		./scripts/run_cov.sh -y

#####################
## Container image ##
#####################
DOCKER_IMAGE_NIMFLAGS ?= -d:chronicles_colors:none -d:insecure -d:postgres
DOCKER_IMAGE_NIMFLAGS := $(DOCKER_IMAGE_NIMFLAGS) $(HEAPTRACK_PARAMS)

docker-image: MAKE_TARGET ?= wakunode2
docker-image: DOCKER_IMAGE_TAG ?= $(MAKE_TARGET)-$(GIT_VERSION)
docker-image: DOCKER_IMAGE_NAME ?= wakuorg/nwaku:$(DOCKER_IMAGE_TAG)
docker-image:
	docker build \
		--build-arg="MAKE_TARGET=$(MAKE_TARGET)" \
		--build-arg="NIMFLAGS=$(DOCKER_IMAGE_NIMFLAGS)" \
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
docker-quick-image: | build deps librln wakunode2
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
		--build-arg="LOG_LEVEL=TRACE" \
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
.PHONY: cbindings cwaku_example libwaku liblogosdelivery liblogosdelivery_example

STATIC ?= 0
LIBWAKU_BUILD_COMMAND ?= libwakuDynamic
LIBLOGOSDELIVERY_BUILD_COMMAND ?= liblogosdeliveryDynamic

ifeq ($(detected_OS),Windows)
	LIB_EXT_DYNAMIC = dll
	LIB_EXT_STATIC = lib
else ifeq ($(detected_OS),Darwin)
	LIB_EXT_DYNAMIC = dylib
	LIB_EXT_STATIC = a
else ifeq ($(detected_OS),Linux)
	LIB_EXT_DYNAMIC = so
	LIB_EXT_STATIC = a
endif

LIB_EXT := $(LIB_EXT_DYNAMIC)
ifeq ($(STATIC), 1)
	LIB_EXT = $(LIB_EXT_STATIC)
	LIBWAKU_BUILD_COMMAND = libwakuStatic
	LIBLOGOSDELIVERY_BUILD_COMMAND = liblogosdeliveryStatic
endif

libwaku: | build deps librln
	echo -e $(BUILD_MSG) "build/$@.$(LIB_EXT)" && nimble $(BUILD_COMMAND) $@.$(LIB_EXT)

cwaku_example: | build libwaku
	echo -e $(BUILD_MSG) "build/$@" && \
		cc -o "build/$@" \
		./examples/cbindings/waku_example.c \
		./examples/cbindings/base64.c \
		-lwaku -Lbuild/ \
		-pthread -ldl -lm

cppwaku_example: | build libwaku
	echo -e $(BUILD_MSG) "build/$@" && \
		g++ -o "build/$@" \
		./examples/cpp/waku.cpp \
		./examples/cpp/base64.cpp \
		-lwaku -Lbuild/ \
		-pthread -ldl -lm

nodejswaku: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		node-gyp build --directory=examples/nodejs/

liblogosdelivery: | build deps librln
	echo -e $(BUILD_MSG) "build/$@.$(LIB_EXT)" && $(ENV_SCRIPT) nim $(LIBLOGOSDELIVERY_BUILD_COMMAND) $(NIM_PARAMS) waku.nims $@.$(LIB_EXT)

logosdelivery_example: | build liblogosdelivery
	@echo -e $(BUILD_MSG) "build/$@"
ifeq ($(detected_OS),Darwin)
	gcc -o build/$@ \
		liblogosdelivery/examples/logosdelivery_example.c \
		-I./liblogosdelivery \
		-L./build \
		-llogosdelivery \
		-Wl,-rpath,./build
else ifeq ($(detected_OS),Linux)
	gcc -o build/$@ \
		liblogosdelivery/examples/logosdelivery_example.c \
		-I./liblogosdelivery \
		-L./build \
		-llogosdelivery \
		-Wl,-rpath,'$$ORIGIN'
else ifeq ($(detected_OS),Windows)
	gcc -o build/$@.exe \
		liblogosdelivery/examples/logosdelivery_example.c \
		-I./liblogosdelivery \
		-L./build \
		-llogosdelivery \
		-lws2_32
endif

#####################
## Mobile Bindings ##
#####################
.PHONY: libwaku-android \
		libwaku-android-precheck \
		libwaku-android-arm64 \
		libwaku-android-amd64 \
		libwaku-android-x86 \
		libwaku-android-arm

ANDROID_TARGET ?= 30
ifeq ($(detected_OS),Darwin)
	ANDROID_TOOLCHAIN_DIR := $(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/darwin-x86_64
else
	ANDROID_TOOLCHAIN_DIR := $(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/linux-x86_64
endif

libwaku-android-precheck:
ifndef ANDROID_NDK_HOME
	$(error ANDROID_NDK_HOME is not set)
endif

build-libwaku-for-android-arch:
	mkdir -p $(CURDIR)/build/android/$(ABIDIR)/
	CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_ARCH=$(ANDROID_ARCH) ANDROID_COMPILER=$(ANDROID_COMPILER) ANDROID_TOOLCHAIN_DIR=$(ANDROID_TOOLCHAIN_DIR) nimble libWakuAndroid
else
	./scripts/build_rln_android.sh $(CURDIR)/build $(LIBRLN_BUILDDIR) $(LIBRLN_VERSION) $(CROSS_TARGET) $(ABIDIR)
endif
	$(MAKE) rebuild-nat-libs CC=$(ANDROID_TOOLCHAIN_DIR)/bin/$(ANDROID_COMPILER)

libwaku-android-arm64: ANDROID_ARCH=aarch64-linux-android
libwaku-android-arm64: CPU=arm64
libwaku-android-arm64: ABIDIR=arm64-v8a
libwaku-android-arm64: | libwaku-android-precheck build deps
	$(MAKE) build-libwaku-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libwaku-android-amd64: ANDROID_ARCH=x86_64-linux-android
libwaku-android-amd64: CPU=amd64
libwaku-android-amd64: ABIDIR=x86_64
libwaku-android-amd64: | libwaku-android-precheck build deps
	$(MAKE) build-libwaku-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libwaku-android-x86: ANDROID_ARCH=i686-linux-android
libwaku-android-x86: CPU=i386
libwaku-android-x86: ABIDIR=x86
libwaku-android-x86: | libwaku-android-precheck build deps
	$(MAKE) build-libwaku-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libwaku-android-arm: ANDROID_ARCH=armv7a-linux-androideabi
libwaku-android-arm: CPU=arm
libwaku-android-arm: ABIDIR=armeabi-v7a
libwaku-android-arm: | libwaku-android-precheck build deps
	$(MAKE) build-libwaku-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=armv7-linux-androideabi CPU=$(CPU) ABIDIR=$(ABIDIR) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libwaku-android:
	$(MAKE) libwaku-android-amd64
	$(MAKE) libwaku-android-arm64
	$(MAKE) libwaku-android-x86

#################
## iOS Bindings #
#################
.PHONY: libwaku-ios-precheck \
		libwaku-ios-device \
		libwaku-ios-simulator \
		libwaku-ios

IOS_DEPLOYMENT_TARGET ?= 18.0

define get_ios_sdk_path
$(shell xcrun --sdk $(1) --show-sdk-path 2>/dev/null)
endef

libwaku-ios-precheck:
ifeq ($(detected_OS),Darwin)
	@command -v xcrun >/dev/null 2>&1 || { echo "Error: Xcode command line tools not installed"; exit 1; }
else
	$(error iOS builds are only supported on macOS)
endif

build-libwaku-for-ios-arch:
	IOS_SDK=$(IOS_SDK) IOS_ARCH=$(IOS_ARCH) IOS_SDK_PATH=$(IOS_SDK_PATH) nimble libWakuIOS

libwaku-ios-device: IOS_ARCH=arm64
libwaku-ios-device: IOS_SDK=iphoneos
libwaku-ios-device: IOS_SDK_PATH=$(call get_ios_sdk_path,iphoneos)
libwaku-ios-device: | libwaku-ios-precheck build deps
	$(MAKE) build-libwaku-for-ios-arch IOS_ARCH=$(IOS_ARCH) IOS_SDK=$(IOS_SDK) IOS_SDK_PATH=$(IOS_SDK_PATH)

libwaku-ios-simulator: IOS_ARCH=arm64
libwaku-ios-simulator: IOS_SDK=iphonesimulator
libwaku-ios-simulator: IOS_SDK_PATH=$(call get_ios_sdk_path,iphonesimulator)
libwaku-ios-simulator: | libwaku-ios-precheck build deps
	$(MAKE) build-libwaku-for-ios-arch IOS_ARCH=$(IOS_ARCH) IOS_SDK=$(IOS_SDK) IOS_SDK_PATH=$(IOS_SDK_PATH)

libwaku-ios:
	$(MAKE) libwaku-ios-device
	$(MAKE) libwaku-ios-simulator

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
			sed -E 's@#([0-9]+)@[#\1](https://github.com/waku-org/nwaku/issues/\1)@g'
