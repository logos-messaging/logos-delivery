#!/bin/sh

echo "- - - - - - - - - - Windows Setup Script - - - - - - - - - -"

# Mirrors the steps in .github/workflows/windows-build.yml so a local MSYS2
# build matches CI. Builds go through the nimble build system: Nimble is
# installed via scripts/install_nimble.sh, dependencies are fetched into
# nimbledeps/ by `nimble setup --localdeps`, and the nat-libs and bearssl C
# sources are rebuilt from there by make.

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
export PATH="$HOME/.nimble/bin:/c/msys64/usr/bin:/c/msys64/mingw64/bin:/c/msys64/usr/lib:/c/msys64/mingw64/lib:$PATH"

echo "2. -.-.-.- Verify dependencies -.-.-.-"
execute_command "which gcc g++ make cmake cargo upx rustc python nim"

echo "3. -.-.-.- Updating submodules -.-.-.-"
execute_command "git submodule update --init --recursive"

echo "4. -.-.-.- Installing nasm -.-.-.-"
execute_command "bash scripts/install_nasm_in_windows.sh"

echo "5. -.-.-.- Installing Nimble -.-.-.-"
execute_command "make install-nimble"

echo "6. -.-.-.- Installing nimble deps -.-.-.-"
execute_command "make build-deps CC=gcc"

echo "7. -.-.-.- Creating tmp directory -.-.-.-"
execute_command "mkdir -p tmp"

echo "8. -.-.-.- Building logosdeliverynode -.-.-.- "
execute_command "make logosdeliverynode POSTGRES=1 LOG_LEVEL=DEBUG V=1 -j8"

echo "9. -.-.-.- Building liblogosdelivery -.-.-.- "
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
