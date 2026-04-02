#!/usr/bin/env bash

# Install pnpm

REQUIRED_PNPM_VERSION="$1"

if command -v pnpm &> /dev/null; then
    # pnpm is already installed; check the current version.
    CURRENT_PNPM_VERSION=$(pnpm --version 2>/dev/null)

    if [ -n "$CURRENT_PNPM_VERSION" ]; then
        # Compare CURRENT_PNPM_VERSION < REQUIRED_PNPM_VERSION using sort -V
        lower_version=$(printf '%s\n%s\n' "$CURRENT_PNPM_VERSION" "$REQUIRED_PNPM_VERSION" | sort -V | head -n1)

        if [ "$lower_version" != "$REQUIRED_PNPM_VERSION" ]; then
            echo "pnpm is already installed with version $CURRENT_PNPM_VERSION, which is older than the required $REQUIRED_PNPM_VERSION. Please update pnpm manually if needed."
        fi
    fi
else
    # Install pnpm using npm
    if [ -n "$REQUIRED_PNPM_VERSION" ]; then
        echo "Installing pnpm version $REQUIRED_PNPM_VERSION..."
        npm install -g pnpm@$REQUIRED_PNPM_VERSION
    else
        echo "Installing latest pnpm..."
        npm install -g pnpm
    fi

    # Verify pnpm was installed
    if ! command -v pnpm >/dev/null 2>&1; then
        echo "Error: pnpm installation failed"
        exit 1
    fi

    echo "pnpm successfully installed: $(pnpm --version)"
fi

