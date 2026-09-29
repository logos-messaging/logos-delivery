#!/usr/bin/env bash
# Check out the Python binding, build liblogosdelivery from this repo and place it
# where the binding expects it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINDINGS="tests-e2e/vendor/logos-delivery-python-bindings"
LIBDIR="$ROOT/$BINDINGS/lib"

cd "$ROOT"
# .gitmodules sets `update = none` for it, which only `--checkout` overrides.
git submodule update --init --checkout "$BINDINGS"
make V=1 liblogosdelivery

mkdir -p "$LIBDIR"
if [ -f build/liblogosdelivery.so ]; then
  cp build/liblogosdelivery.so "$LIBDIR/liblogosdelivery.so"
elif [ -f build/liblogosdelivery.dylib ]; then
  cp build/liblogosdelivery.dylib "$LIBDIR/liblogosdelivery.dylib"
  ln -sf liblogosdelivery.dylib "$LIBDIR/liblogosdelivery.so"
else
  echo "ERROR: built library not found in build/" >&2
  exit 1
fi
echo "Placed liblogosdelivery in $LIBDIR"
