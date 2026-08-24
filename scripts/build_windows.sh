#!/usr/bin/env bash

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

# Run from the repository root, whatever directory the script was invoked from.
cd "$(dirname "$0")/.." || exit 1

# Toolchain versions are pinned in logos_delivery.nimble, the same file the
# Makefile reads them from.
NIM_VERSION=$(grep -E '^const RequiredNimVersion\s*=' logos_delivery.nimble | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
NIMBLE_VERSION=$(grep -E '^const RequiredNimbleVersion\s*=' logos_delivery.nimble | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
NIM_DIR="$HOME/.nim/nim-$NIM_VERSION"

echo "1. -.-.-.-- Set PATH -.-.-.-"
# $HOME/.nimble/bin comes first: it holds the pinned nimble, which has to win
# over the older nimble bundled with the Nim release in $NIM_DIR/bin.
export PATH="$HOME/.nimble/bin:$NIM_DIR/bin:$HOME/.local/nasm/bin:/c/msys64/usr/bin:/c/msys64/mingw64/bin:/c/msys64/usr/lib:/c/msys64/mingw64/lib:$PATH"

echo "2. -.-.-.- Verify dependencies -.-.-.-"
execute_command "which gcc g++ make cmake cargo upx rustc python curl unzip"

echo "3. -.-.-.- Verify HTTPS certificate trust -.-.-.-"
# MSYS2's curl and git verify against MSYS2's own CA bundle, not the Windows
# certificate store. TLS-inspecting antivirus (AVG, Avast, ESET, Kaspersky) and
# corporate proxies re-sign every certificate with a root that only Windows
# trusts, so the downloads below and nimble's dependency clones all fail with
# "unable to get local issuer certificate".
if curl -fsS --connect-timeout 15 -o /dev/null -I https://nim-lang.org 2>/dev/null; then
    echo -e "✓ HTTPS certificates verify \n"
else
    curl_status=$?
    if [ "$curl_status" -eq 60 ]; then
        echo "✗ curl cannot verify HTTPS certificates."
        echo "  Something is intercepting TLS and signing with a root that only"
        echo "  Windows trusts. See 'HTTPS downloads fail' under Windows"
        echo "  troubleshooting in README.md for the one-time fix."
        exit 1
    fi
    echo -e "✗ Could not reach https://nim-lang.org (curl exit $curl_status), continuing \n"
    ((failure_count++))
fi

echo "4. -.-.-.- Installing nasm -.-.-.-"
# A Windows build requirement since the v0.38.0 dependency bump (#3712), which
# added nasm to CI. MSYS2's mingw-w64-x86_64-nasm satisfies it; the upstream
# win64 build is only fetched when no nasm is on PATH.
if which nasm >/dev/null 2>&1; then
    echo -e "nasm already installed ($(which nasm)), skipping \n"
else
    execute_command "./scripts/install_nasm_in_windows.sh"
fi

echo "5. -.-.-.- Keep LF line endings for cloned dependencies -.-.-.-"
# Windows Git defaults to core.autocrlf=true. The LF→CRLF conversion changes the
# SHA1 of the dependencies nimble clones, so they no longer match nimble.lock and
# nimble re-downloads them on every build. These variables apply the setting to
# every git process started from this script (nimble's clones included) without
# touching the user's global git config.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=core.autocrlf
export GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=core.eol
export GIT_CONFIG_VALUE_1=lf

echo "6. -.-.-.- Updating submodules -.-.-.-"
execute_command "git submodule update --init --recursive"

echo "7. -.-.-.- Installing Nim $NIM_VERSION -.-.-.-"
# The Makefile's install-nim target is a no-op on Windows, so install Nim here.
# nim-lang.org ships prebuilt Windows binaries, there is nothing to compile.
nim_version_found=$(nim --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ "$nim_version_found" = "$NIM_VERSION" ]; then
    echo -e "Nim $NIM_VERSION already on PATH ($(which nim)), skipping \n"
else
    mkdir -p "$HOME/.nim"
    execute_command "curl -fL 'https://nim-lang.org/download/nim-${NIM_VERSION}_x64.zip' -o '$HOME/.nim/nim-${NIM_VERSION}.zip'"
    execute_command "unzip -q -o '$HOME/.nim/nim-${NIM_VERSION}.zip' -d '$HOME/.nim'"
    execute_command "nim --version"
fi

echo "8. -.-.-.- Installing Nimble $NIMBLE_VERSION -.-.-.-"
# The Makefile's install-nimble target is a no-op on Windows too. The install
# runs from outside the repository so nimble treats it as a global install
# instead of resolving it against this package's local dependencies.
nimble_version_found=$(nimble --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ "$nimble_version_found" = "$NIMBLE_VERSION" ]; then
    echo -e "Nimble $NIMBLE_VERSION already installed, skipping \n"
else
    execute_command "(cd '$HOME' && nimble install 'nimble@${NIMBLE_VERSION}' -y)"
fi

echo "9. -.-.-.- Installing nimble dependencies -.-.-.-"
# Nim's own source tree checks out differently per platform (its .gitattributes
# forces line endings), so its locked checksum never matches on Windows, even
# with autocrlf disabled. --useSystemNim reuses the Nim installed above and skips
# that check, while still verifying every other locked dependency.
execute_command "nimble setup --localdeps -y --useSystemNim"
# The C dependencies (miniupnpc, libnatpmp, bearssl) are built explicitly with
# gcc, as CI does: make's default CC is 'cc', which MSYS2 does not guarantee.
execute_command "make rebuild-nat-libs-nimbledeps CC=gcc"
execute_command "make rebuild-bearssl-nimbledeps CC=gcc"
# Mark the dependency setup as done so make does not repeat it on every build.
execute_command "touch nimbledeps/.nimble-setup"

echo "10. -.-.-.- Creating tmp directory -.-.-.-"
execute_command "mkdir -p tmp"

echo "11. -.-.-.- Building wakunode2 -.-.-.- "
execute_command "make wakunode2 -j8"

echo "12. -.-.-.- Building logosdeliverynode -.-.-.- "
execute_command "make logosdeliverynode POSTGRES=1 -j8"

echo "13. -.-.-.- Building liblogosdelivery -.-.-.- "
execute_command "make liblogosdelivery STATIC=0 -j8"

echo "-.-.-.- Build artifacts -.-.-.-"
for artifact in build/wakunode2.exe build/logosdeliverynode.exe build/liblogosdelivery.dll; do
    if [ -f "$artifact" ]; then
        echo "✓ $artifact"
    else
        echo "✗ $artifact not found"
    fi
done

echo "Windows setup completed!"
echo "✓ Successful commands: $success_count"
echo "✗ Failed commands: $failure_count"

[ "$failure_count" -eq 0 ] || exit 1
