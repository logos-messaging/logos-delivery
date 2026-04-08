# Copyright (c) 2022 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

###########################
## bearssl (nimbledeps)  ##
###########################
# Rebuilds libbearssl.a from the package installed by nimble under
# nimbledeps/pkgs2/. Used by `make update` / $(NIMBLEDEPS_STAMP).
#
# BEARSSL_NIMBLEDEPS_DIR is evaluated at parse time, so targets that
# depend on it must be invoked via a recursive $(MAKE) call so the sub-make
# re-evaluates the variable after nimble setup has populated nimbledeps/.
#
# `ls -dt` (sort by modification time, newest first) is used to pick the
# latest installed version and is portable across Linux, macOS, and
# Windows (MSYS/MinGW).

BEARSSL_NIMBLEDEPS_DIR := $(shell ls -dt $(CURDIR)/nimbledeps/pkgs2/bearssl-* 2>/dev/null | head -1)
BEARSSL_CSOURCES_DIR   := $(BEARSSL_NIMBLEDEPS_DIR)/bearssl/csources

BEARSSL_UNAME_M := $(shell uname -m)
ifeq ($(BEARSSL_UNAME_M),x86_64)
  PORTABLE_BEARSSL_CFLAGS := -W -Wall -Os -fPIC -mssse3
else
  PORTABLE_BEARSSL_CFLAGS := -W -Wall -Os -fPIC
endif

.PHONY: clean-bearssl-nimbledeps rebuild-bearssl-nimbledeps

clean-bearssl-nimbledeps:
ifeq ($(BEARSSL_NIMBLEDEPS_DIR),)
	$(error No bearssl package found under nimbledeps/pkgs2/ — run 'make update' first)
endif
	+ [ -e "$(BEARSSL_CSOURCES_DIR)/build" ] && \
		"$(MAKE)" -C "$(BEARSSL_CSOURCES_DIR)" clean || true

rebuild-bearssl-nimbledeps: | clean-bearssl-nimbledeps
ifeq ($(BEARSSL_NIMBLEDEPS_DIR),)
	$(error No bearssl package found under nimbledeps/pkgs2/ — run 'make update' first)
endif
	@echo "Rebuilding bearssl from $(BEARSSL_CSOURCES_DIR)"
	+ "$(MAKE)" -C "$(BEARSSL_CSOURCES_DIR)" CFLAGS="$(PORTABLE_BEARSSL_CFLAGS)" lib