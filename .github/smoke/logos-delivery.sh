#!/usr/bin/env bash
# Windows smoke for the nix cross target, run by logos-co/logos-windows-ci: cwd
# is the staged tree root, one directory per target, and `run` is on PATH.
set -euo pipefail

# By hand on a native build: SMOKE_NATIVE=1 NODE=./build/logosdeliverynode
# LIB=./build/liblogosdelivery.so bash this file; `run` is then a plain exec.
if [ -n "${SMOKE_NATIVE:-}" ]; then
  run() { "$@"; }
fi

NODE="${NODE:-logosdeliverynode-windows-x86_64/bin/logosdeliverynode.exe}"
LIB="${LIB:-liblogosdelivery-windows-x86_64/bin/liblogosdelivery.dll}"
HDR="${HDR:-liblogosdelivery-windows-x86_64/include/generated/logosdelivery.h}"
CBOR_HDR="${CBOR_HDR:-liblogosdelivery-windows-x86_64/include/generated/nim_ffi_cbor.h}"
PRELUDE_HDR="${PRELUDE_HDR:-liblogosdelivery-windows-x86_64/include/generated/nim_ffi_prelude.h}"

# 1. The tree carries what a consumer links and dlopens. `min-pes: 1` is met by
# the node's exe alone, so without this a vanished DLL would still be green.
for f in "$LIB" "$HDR" "$CBOR_HDR" "$PRELUDE_HDR"; do
  if [ ! -s "$f" ]; then
    echo "::error::$f is missing or empty in the staged tree." >&2
    echo "::error::staged: $(find . -mindepth 1 -maxdepth 1 -type d | sort | tr '\n' ' ')" >&2
    exit 1
  fi
done
echo "staged: $LIB ($(wc -c < "$LIB") bytes), generated C binding headers"

# Assert the exact generated paths rather than accepting an unusable include
# directory.

# 2. libpq ships beside the node's exe. A dlopen leaves no PE import, so no
# static gate sees it; without it `--version` exits 1 before printing.
if [ ! -s "$(dirname "$NODE")/libpq.dll" ]; then
  echo "::error::libpq.dll is not beside $NODE." >&2
  # shellcheck disable=SC2012  # these are DLL names, not arbitrary input
  echo "::error::shipped there: $(ls -1 "$(dirname "$NODE")" | tr '\n' ' ')" >&2
  exit 1
fi

# 3. The node PE starts on Windows: `--version` is confutils' early exit, so
# this is the load test -- imports resolve, static rln/C init, Nim main runs.
run "$NODE" --version | tee version.txt
grep -qi 'git commit hash' version.txt

# ...and reaches its own argument parser rather than dying in a static ctor.
run "$NODE" --help | tee help.txt
grep -qi 'usage' help.txt

echo "smoke ok"
