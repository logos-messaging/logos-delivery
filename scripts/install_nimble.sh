#!/usr/bin/env bash
# Installs the pinned Nimble release from its prebuilt binary into <dir>
# (default ~/.local/nimble-<version>/bin). A binary that already reports the
# version is reused. Nimble then installs Nim itself, so no Nim is needed here.

set -e

VERSION="${1:-}"
if [ -z "${VERSION}" ]; then
  echo "Usage: $0 <nimble-version> [install-dir]" >&2
  exit 1
fi
VERSION="${VERSION#v}"

NIMBLE_DIR="${2:-${HOME}/.local/nimble-${VERSION}/bin}"
if command -v cygpath >/dev/null 2>&1; then
  NIMBLE_DIR="$(cygpath -u "${NIMBLE_DIR}")"
fi

case "$(uname -s)" in
  Darwin) OS=macosx ;;
  Linux) OS=linux ;;
  MINGW* | MSYS* | CYGWIN*) OS=windows ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) ARCH=x64 ;;
  aarch64 | arm64) ARCH=aarch64 ;;
  armv7l) ARCH=armv7l ;;
  i686 | i386) ARCH=x32 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

EXTENSION=nimble
[ "${OS}" = "windows" ] && EXTENSION=nimble.exe
NIMBLE_BIN="${NIMBLE_DIR}/${EXTENSION}"

if [ -x "${NIMBLE_BIN}" ]; then
  have=$("${NIMBLE_BIN}" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [ "${have}" = "${VERSION}" ]; then
    echo "Nimble ${VERSION} already installed, skipping."
    exit 0
  fi
fi

mkdir -p "${NIMBLE_DIR}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

URL="https://github.com/nim-lang/nimble/releases/download/v${VERSION}/nimble-${OS}_${ARCH}.tar.gz"
echo "Downloading Nimble ${VERSION} from ${URL}..."
curl -fsSL "${URL}" -o "${WORK_DIR}/nimble.tar.gz"
tar -xzf "${WORK_DIR}/nimble.tar.gz" -C "${WORK_DIR}"

cp "${WORK_DIR}/${EXTENSION}" "${NIMBLE_BIN}.new.$$"
chmod +x "${NIMBLE_BIN}.new.$$"
mv -f "${NIMBLE_BIN}.new.$$" "${NIMBLE_BIN}"

echo "Nimble ${VERSION} installed to ${NIMBLE_BIN}"
