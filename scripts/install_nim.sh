#!/usr/bin/env bash
# Installs a specific Nim version.
# Usage: install_nim.sh <nim-version>
#
# Installs to ~/.nim/nim-<version>/ and symlinks binaries into ~/.nimble/bin/,
# which is the idiomatic Nim location already on PATH.
#
# Pre-built binaries are downloaded from nim-lang.org: a .zip on Windows
# (nim-<version>_x64.zip), a .tar.xz on Linux/macOS. On Unix, falls back to
# building from source when no pre-built tarball exists.

set -e

NIM_VERSION="${1:-}"

if [ -z "${NIM_VERSION}" ]; then
  echo "Usage: $0 <nim-version>" >&2
  exit 1
fi

NIM_DEST="${HOME}/.nim/nim-${NIM_VERSION}"

# 1. A matching Nim is already on PATH (e.g. provided by CI's setup-nim-action,
#    choosenim, or a previous run of this script). Use it as-is: installing over it
#    would symlink a freshly downloaded Nim into ~/.nimble/bin (first on PATH) and
#    shadow a known-good toolchain, which has caused C-backend build failures.
nim_ver=$(nim --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ "${nim_ver}" = "${NIM_VERSION}" ]; then
  echo "Nim ${NIM_VERSION} already on PATH ($(command -v nim)), skipping install."
  exit 0
fi

# 2. Already installed at our expected location from a previous run, but not on PATH.
#    Re-link binaries into ~/.nimble/bin.
if [ -f "${NIM_DEST}/lib/system.nim" ]; then
  echo "Nim ${NIM_VERSION} already installed at ${NIM_DEST}, re-linking binaries."
  mkdir -p "${HOME}/.nimble/bin"
  for bin_path in "${NIM_DEST}/bin/"*; do
    ln -sf "${bin_path}" "${HOME}/.nimble/bin/$(basename "${bin_path}")"
  done
  exit 0
fi

if [ -n "${nim_ver}" ]; then
  echo "INFO: Nim ${nim_ver} found in PATH; installing Nim ${NIM_VERSION} to ${NIM_DEST}." >&2
fi

<<<<<<< HEAD
=======
OS=$(uname -s | tr 'A-Z' 'a-z' | sed 's/darwin/macosx/')
ARCH=$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/')

BINARY_URL="https://nim-lang.org/download/nim-${NIM_VERSION}-${OS}_${ARCH}.tar.xz"
>>>>>>> master
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
  # Windows: Nim ships as a zip named nim-<version>_<arch>.zip
  # (no OS segment, .zip rather than .tar.xz, and no source-build fallback).
  case "$(uname -m)" in
  x86_64 | amd64) WIN_ARCH=x64 ;;
  *) WIN_ARCH=x32 ;;
  esac
  BINARY_URL="https://nim-lang.org/download/nim-${NIM_VERSION}_${WIN_ARCH}.zip"

<<<<<<< HEAD
  echo "Downloading pre-built Nim ${NIM_VERSION} (windows_${WIN_ARCH}) from ${BINARY_URL}..."
  curl -fL "${BINARY_URL}" -o "${WORK_DIR}/nim.zip"
  unzip -q "${WORK_DIR}/nim.zip" -d "${WORK_DIR}"
  SRC_DIR="${WORK_DIR}/nim-${NIM_VERSION}"
  ;;
*)
  OS=$(uname -s | tr 'A-Z' 'a-z' | sed 's/darwin/macosx/')
  ARCH=$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/')

  BINARY_URL="https://nim-lang.org/download/nim-${NIM_VERSION}-${OS}_${ARCH}.tar.xz"

  echo "Checking for pre-built Nim ${NIM_VERSION} (${OS}_${ARCH})..."
  HTTP_STATUS=$(curl -sI "${BINARY_URL}" | head -1 | grep -oE '[0-9]{3}' || true)

  if [ "${HTTP_STATUS}" = "200" ]; then
    echo "Downloading pre-built binary from ${BINARY_URL}..."
    curl -fL "${BINARY_URL}" -o "${WORK_DIR}/nim.tar.xz"
    tar -xJf "${WORK_DIR}/nim.tar.xz" -C "${WORK_DIR}"
    SRC_DIR="${WORK_DIR}/nim-${NIM_VERSION}"
  else
    echo "No pre-built binary found for ${OS}_${ARCH}. Building from source..."
    SRC_URL="https://github.com/nim-lang/Nim/archive/refs/tags/v${NIM_VERSION}.tar.gz"
    curl -fL "${SRC_URL}" -o "${WORK_DIR}/nim-src.tar.gz"
    tar -xzf "${WORK_DIR}/nim-src.tar.gz" -C "${WORK_DIR}"
    cd "${WORK_DIR}/Nim-${NIM_VERSION}"
    sh build_all.sh
    SRC_DIR="${WORK_DIR}/Nim-${NIM_VERSION}"
  fi
  ;;
esac

# rm -rf can fail with "Directory not empty" on overlay filesystems (e.g. Docker).
# Using cp -r src/. dst/ handles both cases: dst absent (clean) or partially present.
rm -rf "${NIM_DEST}" 2>/dev/null || true
mkdir -p "${NIM_DEST}"
cp -r "${SRC_DIR}/." "${NIM_DEST}/"
=======
if [ "${HTTP_STATUS}" = "200" ]; then
  echo "Downloading pre-built binary from ${BINARY_URL}..."
  curl -fL "${BINARY_URL}" -o "${WORK_DIR}/nim.tar.xz"
  tar -xJf "${WORK_DIR}/nim.tar.xz" -C "${WORK_DIR}"
  SRC_DIR="${WORK_DIR}/nim-${NIM_VERSION}"
else
  echo "No pre-built binary found for ${OS}_${ARCH}. Building from source..."
  SRC_URL="https://github.com/nim-lang/Nim/archive/refs/tags/v${NIM_VERSION}.tar.gz"
  curl -fL "${SRC_URL}" -o "${WORK_DIR}/nim-src.tar.gz"
  tar -xzf "${WORK_DIR}/nim-src.tar.gz" -C "${WORK_DIR}"
  cd "${WORK_DIR}/Nim-${NIM_VERSION}"
  sh build_all.sh
  SRC_DIR="${WORK_DIR}/Nim-${NIM_VERSION}"
fi
>>>>>>> master

# rm -rf can fail with "Directory not empty" on overlay filesystems (e.g. Docker).
# Using cp -r src/. dst/ handles both cases: dst absent (clean) or partially present.
rm -rf "${NIM_DEST}" 2>/dev/null || true
mkdir -p "${NIM_DEST}"
cp -r "${SRC_DIR}/." "${NIM_DEST}/"

mkdir -p "${HOME}/.nimble/bin"
for bin_path in "${NIM_DEST}/bin/"*; do
  ln -sf "${bin_path}" "${HOME}/.nimble/bin/$(basename "${bin_path}")"
done

echo "Nim ${NIM_VERSION} installed to ${NIM_DEST}"
echo "Binaries symlinked in ~/.nimble/bin — ensure it is in your PATH."