#!/usr/bin/env bash
# Usage: scripts/build_windows.sh [logosdeliverynode|liblogosdelivery]
# Without an argument both are built. NPROC, LOG_LEVEL, V and NIMFLAGS can be
# set in the environment.

echo "- - - - - - - - - - Windows Setup Script - - - - - - - - - -"

target="${1:-all}"
case "$target" in
    all|logosdeliverynode|liblogosdelivery) ;;
    *)
        echo "Usage: $0 [logosdeliverynode|liblogosdelivery]" >&2
        exit 2
        ;;
esac

NPROC="${NPROC:-$(nproc)}"
LOG_LEVEL="${LOG_LEVEL:-DEBUG}"
V="${V:-1}"

success_count=0
failure_count=0

# Function to execute a command and check its status
execute_command() {
    echo "Executing: $1"
    if eval "$1"; then
        echo -e "✓ Command succeeded \n"
        ((success_count++))
    else
        echo -e "✗ Command failed \n"
        ((failure_count++))
    fi
}

echo "1. -.-.-.-- Set PATH -.-.-.-"
# Git Bash has no pacman; an MSYS2 shell already has these directories on PATH.
if [ ! -x /usr/bin/pacman ]; then
    export PATH="/c/msys64/mingw64/bin:/c/msys64/usr/bin:$PATH"
fi

echo "2. -.-.-.- Verify dependencies -.-.-.-"
execute_command "which gcc g++ make cmake cargo rustc python nasm"

# make installs the pinned Nimble, which then installs Nim and the locked
# dependencies into nimbledeps/, so no Nim is needed on PATH. make also builds
# the C libraries itself: the librln target inits the vendor/zerokit submodule,
# Nat.mk builds miniupnpc and libnatpmp from the package nimble installed, and
# libbacktrace is disabled by default. The vendor tree those steps used is gone.

echo "3. -.-.-.- Build -.-.-.- "
if [ "$target" = all ] || [ "$target" = logosdeliverynode ]; then
    execute_command "make logosdeliverynode POSTGRES=1 LOG_LEVEL=$LOG_LEVEL V=$V -j$NPROC"
fi
if [ "$target" = all ] || [ "$target" = liblogosdelivery ]; then
    execute_command "make liblogosdelivery STATIC=0 LOG_LEVEL=$LOG_LEVEL V=$V -j$NPROC"
fi

echo "✓ Successful commands: $success_count"
echo "✗ Failed commands: $failure_count"

# execute_command records failures instead of stopping, so the exit status has
# to carry them. Without this the script reports success after a failed build.
if [ "$failure_count" -ne 0 ]; then
    echo "Windows setup FAILED"
    exit 1
fi

echo "Windows setup completed successfully!"
