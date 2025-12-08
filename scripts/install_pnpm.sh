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
    # Install pnpm using the standalone installer
    if [ -n "$REQUIRED_PNPM_VERSION" ]; then
        echo "Installing pnpm version $REQUIRED_PNPM_VERSION..."
        curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION=$REQUIRED_PNPM_VERSION sh -
    else
        echo "Installing latest pnpm..."
        curl -fsSL https://get.pnpm.io/install.sh | sh -
    fi

    # Set PNPM_HOME and add to PATH (same as what the installer adds to .bashrc)
    export PNPM_HOME="$HOME/.local/share/pnpm"
    case ":$PATH:" in
        *":$PNPM_HOME:"*) ;;
        *) export PATH="$PNPM_HOME:$PATH" ;;
    esac

    # If running in GitHub Actions, persist the PATH change
    if [ -n "$GITHUB_PATH" ]; then
        echo "$PNPM_HOME" >> "$GITHUB_PATH"
        echo "Added $PNPM_HOME to GITHUB_PATH"
    fi

    # Verify pnpm was installed
    if ! command -v pnpm >/dev/null 2>&1; then
        echo "Error: pnpm installation failed"
        exit 1
    fi

    echo "pnpm successfully installed: $(pnpm --version)"
fi

