# Copyright (c) 2026 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

###########################
## leopard (nimbledeps)  ##
###########################
# nim-leopard builds the vendored Leopard-RS C++ library with cmake at Nim
# compile time. Its CMakeLists.txt declares two test executables from
# `tests/benchmark.cpp` and `tests/experiments.cpp`, but nimble strips every
# directory named `tests` when it installs a package, so those sources are
# missing under nimbledeps/pkgs2/ and cmake fails at the generate step --
# before it can build the `libleopard` target nim-leopard actually asks for.
#
# Restore the two files as empty `main`s. They are only ever configured, never
# built: nim-leopard runs `make libleopard`, not `make all`.
#
# LEOPARD_NIMBLEDEPS_DIR is evaluated at parse time, so this target must be
# invoked through a recursive $(MAKE) call, after nimble setup has populated
# nimbledeps/ -- same constraint as BearSSL.mk and Nat.mk.

LEOPARD_NIMBLEDEPS_DIR := $(shell ls -dt $(CURDIR)/nimbledeps/pkgs2/leopard-* 2>/dev/null | head -1)
LEOPARD_TESTS_DIR      := $(LEOPARD_NIMBLEDEPS_DIR)/vendor/leopard/tests

.PHONY: rebuild-leopard-nimbledeps

rebuild-leopard-nimbledeps:
# Keep this guard first: with an empty LEOPARD_NIMBLEDEPS_DIR the paths below
# expand to an absolute /vendor/leopard/tests, so the mkdir would target the
# filesystem root. Being a recipe line, it fires only when the target runs, so
# a checkout without nimbledeps/ still parses.
ifeq ($(LEOPARD_NIMBLEDEPS_DIR),)
	$(error No leopard package found under nimbledeps/pkgs2/ — run 'make build-deps' first)
endif
	@mkdir -p "$(LEOPARD_TESTS_DIR)"
	@for stub in benchmark experiments; do \
		if [ ! -f "$(LEOPARD_TESTS_DIR)/$$stub.cpp" ]; then \
			echo "Restoring leopard cmake placeholder $$stub.cpp"; \
			echo 'int main() { return 0; }' > "$(LEOPARD_TESTS_DIR)/$$stub.cpp"; \
		fi; \
	done
