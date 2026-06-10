#!/usr/bin/env bash

# Install Foundry binaries (forge, cast, anvil, chisel).
#
# We bypass `foundryup` and pull the release tarball straight from GitHub.

set -euo pipefail

REQUIRED_FOUNDRY_VERSION="${1:-}"
if [ -z "$REQUIRED_FOUNDRY_VERSION" ]; then
    echo "usage: install_anvil.sh <foundry-version>" >&2
    exit 1
fi

if command -v anvil >/dev/null 2>&1; then
    CURRENT_FOUNDRY_VERSION=$(anvil --version 2>/dev/null | awk '{print $2}')

    if [ -n "$CURRENT_FOUNDRY_VERSION" ]; then
        lower_version=$(printf '%s\n%s\n' "$CURRENT_FOUNDRY_VERSION" "$REQUIRED_FOUNDRY_VERSION" | sort -V | head -n1)

        if [ "$lower_version" != "$REQUIRED_FOUNDRY_VERSION" ]; then
            echo "Anvil is already installed with version $CURRENT_FOUNDRY_VERSION, which is older than the required $REQUIRED_FOUNDRY_VERSION. Please update Foundry manually if needed."
        fi
    fi
    exit 0
fi

case "$(uname -s)" in
    Darwin) PLATFORM=darwin ;;
    Linux)  PLATFORM=linux  ;;
    *) echo "Unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64)   ARCH=amd64 ;;
    arm64|aarch64)  ARCH=arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

BASE_DIR="${XDG_CONFIG_HOME:-$HOME}"
FOUNDRY_DIR="${FOUNDRY_DIR:-"$BASE_DIR/.foundry"}"
FOUNDRY_BIN_DIR="$FOUNDRY_DIR/bin"

TAG="v${REQUIRED_FOUNDRY_VERSION}"
ASSET="foundry_${TAG}_${PLATFORM}_${ARCH}.tar.gz"
URL="https://github.com/foundry-rs/foundry/releases/download/${TAG}/${ASSET}"

echo "Installing Foundry ${TAG} for ${PLATFORM}/${ARCH}..."
mkdir -p "$FOUNDRY_BIN_DIR"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
archive="$tmpdir/foundry.tar.gz"

curl -fL --retry 5 --retry-delay 2 --retry-all-errors -o "$archive" "$URL"

# Validate the archive before extracting -- catches truncated/HTML responses
# loudly instead of leaving a half-installed Foundry on disk.
tar tzf "$archive" >/dev/null

tar -xzf "$archive" -C "$FOUNDRY_BIN_DIR" forge cast anvil chisel
chmod +x "$FOUNDRY_BIN_DIR"/{forge,cast,anvil,chisel}

export PATH="$FOUNDRY_BIN_DIR:$PATH"
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$FOUNDRY_BIN_DIR" >> "$GITHUB_PATH"
fi

if ! command -v anvil >/dev/null 2>&1; then
    echo "Error: anvil installation failed" >&2
    exit 1
fi

echo "Anvil successfully installed: $(anvil --version)"
