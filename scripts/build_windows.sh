#!/bin/sh

echo "- - - - - - - - - - Windows Setup Script - - - - - - - - - -"

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
export PATH="/c/msys64/usr/bin:/c/msys64/mingw64/bin:/c/msys64/usr/lib:/c/msys64/mingw64/lib:$PATH"

echo "2. -.-.-.- Verify dependencies -.-.-.-"
execute_command "which gcc g++ make cmake cargo upx rustc python nasm nim"

echo "3. -.-.-.- Updating submodules -.-.-.-"
execute_command "git submodule update --init --recursive"

echo "4. -.-.-.- Creating tmp directory -.-.-.-"
execute_command "mkdir -p tmp"

# Nim is installed separately, and make builds the C libraries itself:
# Nat.mk builds miniupnpc and libnatpmp from the package nimble installed, and
# libbacktrace is disabled by default. The vendor tree those steps used is gone.

echo "5. -.-.-.- Building wakunode2 -.-.-.- "
execute_command "make wakunode2 LOG_LEVEL=DEBUG V=1 -j8"

echo "6. -.-.-.- Building logosdeliverynode -.-.-.- "
execute_command "make logosdeliverynode POSTGRES=1 LOG_LEVEL=DEBUG V=1 -j8"

echo "7. -.-.-.- Building liblogosdelivery -.-.-.- "
execute_command "make liblogosdelivery STATIC=0 LOG_LEVEL=DEBUG V=1 -j8"

echo "✓ Successful commands: $success_count"
echo "✗ Failed commands: $failure_count"

# execute_command records failures instead of stopping, so the exit status has
# to carry them. Without this the script reports success after a failed build.
if [ "$failure_count" -ne 0 ]; then
    echo "Windows setup FAILED"
    exit 1
fi

echo "Windows setup completed successfully!"
