#!/usr/bin/env sh
set -e

NASM_VERSION="2.16.01"
NASM_ZIP="nasm-${NASM_VERSION}-win64.zip"
NASM_URL="https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VERSION}/win64/${NASM_ZIP}"

INSTALL_DIR="$HOME/.local/nasm"
BIN_DIR="$INSTALL_DIR/bin"

echo "Installing NASM ${NASM_VERSION}..."

# Create directories
mkdir -p "$BIN_DIR"
cd "$INSTALL_DIR"

# Download
if [ ! -f "$NASM_ZIP" ]; then
  echo "Downloading NASM..."
  curl -LO "$NASM_URL"
fi

# Extract
echo "Extracting..."
unzip -o "$NASM_ZIP"

# Move binaries
cp nasm-*/nasm.exe "$BIN_DIR/"
cp nasm-*/ndisasm.exe "$BIN_DIR/"

# Add to PATH in bashrc (idempotent)
if ! grep -q 'nasm/bin' "$HOME/.bashrc"; then
  echo '' >> "$HOME/.bashrc"
  echo '# NASM' >> "$HOME/.bashrc"
  echo 'export PATH="$HOME/.local/nasm/bin:$PATH"' >> "$HOME/.bashrc"
fi

