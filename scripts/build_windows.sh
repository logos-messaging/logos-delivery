#!/bin/sh

echo "- - - - - - - - - - Windows Setup Script - - - - - - - - - -"

# Mirrors the steps in .github/workflows/windows-build.yml so a local MSYS2
# build matches CI. Builds go through the nimble build system: Nim/Nimble are
# installed via scripts/install_nim.sh + install_nimble.sh, dependencies are
# fetched into nimbledeps/ by `nimble setup --localdeps`, and the nat-libs and
# bearssl C sources are rebuilt from there.

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
execute_command "which gcc g++ make cmake cargo upx rustc python nasm"

echo "3. -.-.-.- Updating submodules -.-.-.-"
execute_command "git submodule update --init --recursive"

echo "4. -.-.-.- Installing nasm -.-.-.-"
execute_command "bash scripts/install_nasm_in_windows.sh"

echo "5. -.-.-.- Installing Nim and Nimble -.-.-.-"
execute_command "make install-nimble"

echo "6. -.-.-.- Patch nimble.lock for Windows nim checksum -.-.-.-"
# nimble.exe uses Windows Git (core.autocrlf=true by default), which converts
# LF->CRLF on checkout. This changes the SHA1 of the nim package source tree
# relative to the Linux-computed checksum stored in nimble.lock. Patch the lock
# file with the Windows-computed checksum before nimble reads it.
execute_command "sed -i 's/68bb85cbfb1832ce4db43943911b046c3af3caab/a092a045d3a427d127a5334a6e59c76faff54686/g' nimble.lock"

echo "7. -.-.-.- Installing nimble deps -.-.-.-"
execute_command "nimble setup --localdeps -y"
execute_command "make rebuild-nat-libs-nimbledeps CC=gcc"
execute_command "make rebuild-bearssl-nimbledeps CC=gcc"
execute_command "touch nimbledeps/.nimble-setup"

echo "8. -.-.-.- Creating tmp directory -.-.-.-"
execute_command "mkdir -p tmp"

echo "9. -.-.-.- Building wakunode2 -.-.-.- "
execute_command "make wakunode2 LOG_LEVEL=DEBUG V=3 -j8"

echo "10. -.-.-.- Building libwaku -.-.-.- "
execute_command "make libwaku STATIC=0 LOG_LEVEL=DEBUG V=1 -j8"

echo "Windows setup completed successfully!"
echo "✓ Successful commands: $success_count"
echo "✗ Failed commands: $failure_count"
