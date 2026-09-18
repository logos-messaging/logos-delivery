# Copyright (c) 2026 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

############################
## TinyCBOR (nimbledeps)  ##
############################
# The generated C binding (library/generated/*.h) encodes requests and decodes
# replies with TinyCBOR, so every C/C++ consumer compiles against its header and
# links it. nim-ffi vendors the copy it generates against; build that into a
# static archive, as nim-ffi's own generated CMakeLists does.
#
# Unlike BearSSL.mk / Nat.mk / Leopard.mk, the paths below use `=`, not `:=`:
# they are expanded when a recipe runs, after build-deps has populated
# nimbledeps/, so no recursive $(MAKE) is needed to see the package.

FFI_NIMBLEDEPS_DIR  = $(shell ls -dt $(CURDIR)/nimbledeps/pkgs2/ffi-* 2>/dev/null | head -1)
TINYCBOR_VENDOR_DIR = $(FFI_NIMBLEDEPS_DIR)/ffi/codegen/templates/cpp/vendor
TINYCBOR_LIB       := build/libtinycbor.a
TINYCBOR_SRCS      := cborencoder.c cborencoder_close_container_checked.c \
                      cborparser.c cborparser_dup_string.c cborerrorstrings.c

.PHONY: tinycbor

tinycbor: | build build-deps
	@test -f "$(TINYCBOR_VENDOR_DIR)/tinycbor/cbor.h" || \
		{ echo "No vendored TinyCBOR in the ffi package under nimbledeps/pkgs2/ -- run 'make build-deps' first" >&2; exit 1; }
	@mkdir -p build/tinycbor
	$(foreach src,$(TINYCBOR_SRCS),$(CC) -c -O2 -std=gnu99 -I"$(TINYCBOR_VENDOR_DIR)/tinycbor" \
		"$(TINYCBOR_VENDOR_DIR)/tinycbor/$(src)" -o build/tinycbor/$(src:.c=.o) &&) true
	rm -f $(TINYCBOR_LIB)
	$(AR) rcs $(TINYCBOR_LIB) $(TINYCBOR_SRCS:%.c=build/tinycbor/%.o)
