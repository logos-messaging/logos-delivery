#!/usr/bin/env bash

# Install Anvil

REQUIRED_FOUNDRY_VERSION="$1"

if command -v anvil &> /dev/null; then
    # Foundry is already installed; check the current version.
    CURRENT_FOUNDRY_VERSION=$(anvil --version 2>/dev/null | awk '{print $2}')

    if [ -n "$CURRENT_FOUNDRY_VERSION" ]; then
        # Compare CURRENT_FOUNDRY_VERSION < REQUIRED_FOUNDRY_VERSION using sort -V
        lower_version=$(printf '%s\n%s\n' "$CURRENT_FOUNDRY_VERSION" "$REQUIRED_FOUNDRY_VERSION" | sort -V | head -n1)

        if [ "$lower_version" != "$REQUIRED_FOUNDRY_VERSION" ]; then
            echo "Anvil is already installed with version $CURRENT_FOUNDRY_VERSION, which is older than the required $REQUIRED_FOUNDRY_VERSION. Please update Foundry manually if needed."
        fi
    fi
else
    BASE_DIR="${XDG_CONFIG_HOME:-$HOME}"
    FOUNDRY_DIR="${FOUNDRY_DIR:-"$BASE_DIR/.foundry"}"
    FOUNDRY_BIN_DIR="$FOUNDRY_DIR/bin"

    echo "Installing Foundry..."
    curl -L https://foundry.paradigm.xyz | bash

    # Add Foundry to PATH for this script session
    export PATH="$FOUNDRY_BIN_DIR:$PATH"

    # Verify foundryup is available
    if ! command -v foundryup >/dev/null 2>&1; then
        echo "Error: foundryup installation failed or not found in $FOUNDRY_BIN_DIR"
        exit 1
    fi

    # Run foundryup to install the required version
    if [ -n "$REQUIRED_FOUNDRY_VERSION" ]; then
        echo "Installing Foundry tools version $REQUIRED_FOUNDRY_VERSION..."
        foundryup --install "$REQUIRED_FOUNDRY_VERSION"
    else
        echo "Installing latest Foundry tools..."
        foundryup
    fi

    # Verify anvil was installed
    if ! command -v anvil >/dev/null 2>&1; then
        echo "Error: anvil installation failed"
        exit 1
    fi

    echo "Anvil successfully installed: $(anvil --version)"
fi