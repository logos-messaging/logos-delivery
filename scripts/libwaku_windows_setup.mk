# ---------------------------------------------------------
# Windows Setup Makefile
# ---------------------------------------------------------

# Extend PATH (Make preserves environment variables)
export PATH := /c/msys64/usr/bin:/c/msys64/mingw64/bin:/c/msys64/usr/lib:/c/msys64/mingw64/lib:$(PATH)

# Tools required
DEPS = gcc g++ make cmake cargo upx rustc python

# Default target
.PHONY: windows-setup
windows-setup: check-deps update-submodules create-tmp libunwind miniupnpc libnatpmp
	@echo "Windows setup completed successfully!"

.PHONY: check-deps
check-deps:
	@echo "Checking libwaku build dependencies..."
	@for dep in $(DEPS); do \
		if ! which $$dep >/dev/null 2>&1; then \
			echo "✗ Missing dependency: $$dep"; \
			exit 1; \
		else \
			echo "✓ Found: $$dep"; \
		fi; \
	done

.PHONY: update-submodules
update-submodules:
	@echo "Updating libwaku git submodules..."
	git submodule update --init --recursive

.PHONY: create-tmp
create-tmp:
	@echo "Creating tmp directory..."
	mkdir -p tmp

.PHONY: libunwind
libunwind:
	@echo "Building libunwind..."
	cd vendor/nim-libbacktrace && make all V=1

.PHONY: miniupnpc
miniupnpc:
	@echo "Building miniupnpc..."
	cd vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc && \
		make -f Makefile.mingw CC=gcc CXX=g++ libminiupnpc.a V=1

.PHONY: libnatpmp
libnatpmp:
	@echo "Building libnatpmp..."
	cd vendor/nim-nat-traversal/vendor/libnatpmp-upstream && \
		make CC="gcc -fPIC -D_WIN32_WINNT=0x0600 -DNATPMP_STATICLIB" libnatpmp.a V=1
