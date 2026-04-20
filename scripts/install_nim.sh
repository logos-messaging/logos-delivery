#!/usr/bin/env bash
# Installs a specific Nim version.
# Usage: install_nim.sh <nim-version>
#
# Installs to ~/.nim/nim-<version>/ and symlinks binaries into ~/.nimble/bin/,
# which is the idiomatic Nim location already on PATH.
#
# Pre-built binaries are downloaded from nim-lang.org when available.
# Falls back to building from source otherwise (e.g. macOS on older releases).

set -e

NIM_VERSION="${1:-}"

if [ -z "${NIM_VERSION}" ]; then
  echo "Usage: $0 <nim-version>" >&2
  exit 1
fi

# Check if the right version is already installed
nim_ver=$(nim --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ "${nim_ver}" = "${NIM_VERSION}" ]; then
  echo "Nim ${NIM_VERSION} already installed, skipping."
  exit 0
fi

if [ -n "${nim_ver}" ]; then
  newer=$(printf '%s\n%s\n' "${NIM_VERSION}" "${nim_ver}" | sort -V | tail -1)
  if [ "${newer}" = "${nim_ver}" ]; then
    echo "WARNING: Nim ${nim_ver} is installed; this repo is validated against ${NIM_VERSION}." >&2
    echo "WARNING: The build will proceed but may behave differently." >&2
    exit 0
  fi
fi

OS=$(uname -s | tr 'A-Z' 'a-z' | sed 's/darwin/macosx/')
ARCH=$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/')

NIM_DEST="${HOME}/.nim/nim-${NIM_VERSION}"
BINARY_URL="https://nim-lang.org/download/nim-${NIM_VERSION}-${OS}_${ARCH}.tar.xz"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Checking for pre-built Nim ${NIM_VERSION} (${OS}_${ARCH})..."
HTTP_STATUS=$(curl -sI "${BINARY_URL}" | head -1 | grep -oE '[0-9]{3}' || true)

if [ "${HTTP_STATUS}" = "200" ]; then
  echo "Downloading pre-built binary from ${BINARY_URL}..."
  curl -fL "${BINARY_URL}" -o "${WORK_DIR}/nim.tar.xz"
  tar -xJf "${WORK_DIR}/nim.tar.xz" -C "${WORK_DIR}"
  rm -rf "${NIM_DEST}"
  mkdir -p "${HOME}/.nim"
  cp -r "${WORK_DIR}/nim-${NIM_VERSION}" "${NIM_DEST}"
else
  echo "No pre-built binary found for ${OS}_${ARCH}. Building from source..."
  SRC_URL="https://github.com/nim-lang/Nim/archive/refs/tags/v${NIM_VERSION}.tar.gz"
  curl -fL "${SRC_URL}" -o "${WORK_DIR}/nim-src.tar.gz"
  tar -xzf "${WORK_DIR}/nim-src.tar.gz" -C "${WORK_DIR}"
  cd "${WORK_DIR}/Nim-${NIM_VERSION}"
  sh build_all.sh
  rm -rf "${NIM_DEST}"
  mkdir -p "${HOME}/.nim"
  cp -r "${WORK_DIR}/Nim-${NIM_VERSION}" "${NIM_DEST}"
fi

mkdir -p "${HOME}/.nimble/bin"
for bin_path in "${NIM_DEST}/bin/"*; do
  ln -sf "${bin_path}" "${HOME}/.nimble/bin/$(basename "${bin_path}")"
done

echo "Nim ${NIM_VERSION} installed to ${NIM_DEST}"
echo "Binaries symlinked in ~/.nimble/bin — ensure it is in your PATH."
