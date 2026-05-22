#!/usr/bin/env bash

# Install Anvil
FOUNDRY_VERSION="$1"
./scripts/install_anvil.sh "$FOUNDRY_VERSION"

# Install pnpm
PNPM_VERSION="$2"
./scripts/install_pnpm.sh "$PNPM_VERSION"