#!/usr/bin/env bash
# Installs a specific nimble version without using `nimble install nimble`.
#
# Install the selected executable under:
#
#   ~/.local/nimble-<version-or-revision>/bin
#
# The Makefile places this directory before ~/.nimble/bin on PATH. Nimble
# may update package links under ~/.nimble/bin during setup, including the
# `nimble` link when Nimble is installed as a package. Installing the
# selected executable outside that directory avoids writing through that
# link.
#
# Procedure:
#   1. Reuse an executable already reporting the requested version/revision.
#   2. For a release, try the version-specific GitHub asset.
#   3. Otherwise, build the requested tag or revision from source.

set -e

NIMBLE_VERSION="${1:-}"
NIMBLE_REVISION="${2:-}"
if [ -z "${NIMBLE_VERSION}" ]; then
  echo "Usage: $0 <nimble-version> [nimble-revision]" >&2
  exit 1
fi

NIMBLE_ID="${NIMBLE_REVISION:-${NIMBLE_VERSION}}"
NIMBLE_DIR="${HOME}/.local/nimble-${NIMBLE_ID}/bin"
NIMBLE_BIN="${NIMBLE_DIR}/nimble"

# Step 1: reuse the executable if it reports the requested version.
if [ -x "${NIMBLE_BIN}" ]; then
  nimble_ver=$("${NIMBLE_BIN}" --version 2>/dev/null \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  nimble_rev=$("${NIMBLE_BIN}" --version 2>/dev/null \
    | grep -oE '[0-9a-f]{40}' | head -1 || true)
  if [ "${nimble_ver}" = "${NIMBLE_VERSION}" ] &&
      { [ -z "${NIMBLE_REVISION}" ] || [ "${nimble_rev}" = "${NIMBLE_REVISION}" ]; }; then
    echo "Nimble ${NIMBLE_ID} already installed, skipping."
    exit 0
  fi
fi

mkdir -p "${NIMBLE_DIR}"

# Step 2: try the version-specific prebuilt release asset.
#
# The URL identifies a release under github.com/nim-lang/nimble. After
# extraction, the script checks that the binary can execute --version.
# It does not independently verify an archive checksum. A failed
# download, extraction, or execution falls through to the source build.
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  ASSET="linux_x64" ;;
  Linux-aarch64) ASSET="linux_aarch64" ;;
  Darwin-arm64)  ASSET="macosx_aarch64" ;;
  Darwin-x86_64) ASSET="macosx_x64" ;;
  MINGW*-x86_64|MSYS*-x86_64) ASSET="windows_x64" ;;
  *)             ASSET="" ;;
esac
if [ -z "${NIMBLE_REVISION}" ] && [ -n "${ASSET}" ]; then
  URL="https://github.com/nim-lang/nimble/releases/download/v${NIMBLE_VERSION}/nimble-${ASSET}.tar.gz"
  echo "Downloading prebuilt nimble ${NIMBLE_VERSION} (${ASSET})..."
  if curl -fsSL "${URL}" | tar -xz -C "${NIMBLE_DIR}"; then
    if "${NIMBLE_BIN}" --version >/dev/null 2>&1; then
      "${NIMBLE_BIN}" --version | head -1
      echo "Nimble ${NIMBLE_VERSION} installed to ${NIMBLE_BIN}"
      exit 0
    fi
    echo "Prebuilt binary does not run, falling back to source build." >&2
  else
    echo "Prebuilt download failed, falling back to source build." >&2
  fi
fi

# Step 3: clone the requested version tag and build it with the Nim
# compiler resolved from PATH.
NIM_BIN="$(command -v nim)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

if [ -n "${NIMBLE_REVISION}" ]; then
  echo "Cloning nimble ${NIMBLE_REVISION} with submodules..."
  git clone --depth=1 --no-checkout https://github.com/nim-lang/nimble.git \
    "${WORK_DIR}/nimble"
  git -C "${WORK_DIR}/nimble" fetch --depth=1 origin "${NIMBLE_REVISION}"
  git -C "${WORK_DIR}/nimble" checkout --detach FETCH_HEAD
  git -C "${WORK_DIR}/nimble" submodule update --init --recursive --depth=1
else
  echo "Cloning nimble v${NIMBLE_VERSION} with submodules..."
  git clone --depth=1 --branch "v${NIMBLE_VERSION}" \
    --recurse-submodules --shallow-submodules \
    https://github.com/nim-lang/nimble.git \
    "${WORK_DIR}/nimble"
fi

echo "Building nimble ${NIMBLE_VERSION} with $("${NIM_BIN}" --version | head -1)..."
cd "${WORK_DIR}/nimble"
# Nim reads nim.cfg and config.nims from the current directory; these
# files add the vendored module paths used by the build.
"${NIM_BIN}" c -d:release --path:src \
  -o:"${WORK_DIR}/nimble_new" src/nimble.nim

# Stage the executable under a separate pathname, then rename it over
# the target. This avoids writing the target executable in place.
cp "${WORK_DIR}/nimble_new" "${NIMBLE_BIN}.new.$$"
mv -f "${NIMBLE_BIN}.new.$$" "${NIMBLE_BIN}"

echo "Nimble ${NIMBLE_VERSION} installed to ${NIMBLE_BIN}"
