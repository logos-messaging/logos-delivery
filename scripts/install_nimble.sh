#!/usr/bin/env bash
# Installs a specific nimble version without using `nimble install nimble`.
#
# `nimble install nimble` is inherently fragile:
#   - ETXTBSY: overwriting the running nimble binary in pkgs2/
#   - JSON parse failures with older nimble versions reading packages_official.json
#
# Strategy:
#   1. If the right version is already at ~/.nimble/bin/nimble → done.
#   2. If a previously-compiled binary exists in pkgs2/ → re-link it.
#   3. Otherwise: clone the nimble git repo, init submodules, build with nim,
#      and atomically replace the target (mv avoids ETXTBSY on the old binary).

set -e

NIMBLE_VERSION="${1:-}"
if [ -z "${NIMBLE_VERSION}" ]; then
  echo "Usage: $0 <nimble-version>" >&2
  exit 1
fi

<<<<<<< HEAD
# On Windows (MSYS2) the binaries carry a .exe extension.
EXE=""
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) EXE=".exe" ;;
esac

NIMBLE_BIN="${HOME}/.nimble/bin/nimble${EXE}"
=======
NIMBLE_BIN="${HOME}/.nimble/bin/nimble"
>>>>>>> master

# 1. Already installed at the right version?
if [ -x "${NIMBLE_BIN}" ]; then
  nimble_ver=$("${NIMBLE_BIN}" --version 2>/dev/null \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [ "${nimble_ver}" = "${NIMBLE_VERSION}" ]; then
    echo "Nimble ${NIMBLE_VERSION} already installed, skipping."
    exit 0
  fi
fi

# 2. Already compiled into pkgs2/ from a previous (possibly partial) run?
<<<<<<< HEAD
PKGS2_NIMBLE=$(ls -dt "${HOME}/.nimble/pkgs2/nimble-${NIMBLE_VERSION}-"*/nimble${EXE} \
=======
PKGS2_NIMBLE=$(ls -dt "${HOME}/.nimble/pkgs2/nimble-${NIMBLE_VERSION}-"*/nimble \
>>>>>>> master
  2>/dev/null | head -1 || true)
if [ -n "${PKGS2_NIMBLE}" ] && [ -x "${PKGS2_NIMBLE}" ]; then
  echo "Nimble ${NIMBLE_VERSION} found in pkgs2, re-linking to ${NIMBLE_BIN}."
  mkdir -p "${HOME}/.nimble/bin"
  ln -sf "${PKGS2_NIMBLE}" "${NIMBLE_BIN}"
  exit 0
fi

# 3. Build from source.
<<<<<<< HEAD
NIM_BIN="${HOME}/.nimble/bin/nim${EXE}"
=======
NIM_BIN="${HOME}/.nimble/bin/nim"
>>>>>>> master
if [ ! -x "${NIM_BIN}" ]; then
  NIM_BIN="$(command -v nim)"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Cloning nimble v${NIMBLE_VERSION} with submodules..."
git clone --depth=1 --branch "v${NIMBLE_VERSION}" \
  --recurse-submodules --shallow-submodules \
  https://github.com/nim-lang/nimble.git \
  "${WORK_DIR}/nimble"

echo "Building nimble ${NIMBLE_VERSION} with $("${NIM_BIN}" --version | head -1)..."
cd "${WORK_DIR}/nimble"
# nim reads nim.cfg / config.nims in the current dir, which sets vendor paths.
"${NIM_BIN}" c -d:release --path:src \
<<<<<<< HEAD
  -o:"${WORK_DIR}/nimble_new${EXE}" src/nimble.nim

mkdir -p "${HOME}/.nimble/bin"
# Atomic rename: avoids ETXTBSY when the old binary at NIMBLE_BIN is still running.
cp "${WORK_DIR}/nimble_new${EXE}" "${NIMBLE_BIN}.new.$$"
=======
  -o:"${WORK_DIR}/nimble_new" src/nimble.nim

mkdir -p "${HOME}/.nimble/bin"
# Atomic rename: avoids ETXTBSY when the old binary at NIMBLE_BIN is still running.
cp "${WORK_DIR}/nimble_new" "${NIMBLE_BIN}.new.$$"
>>>>>>> master
mv -f "${NIMBLE_BIN}.new.$$" "${NIMBLE_BIN}"

echo "Nimble ${NIMBLE_VERSION} installed to ${NIMBLE_BIN}"