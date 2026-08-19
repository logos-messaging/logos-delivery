#!/usr/bin/env bash
# Windows smoke for logos-delivery's nix cross target.
#
# HOW IT IS RUN (logos-co/logos-windows-ci contract)
#   cwd is the staged tree ROOT, which holds ONE DIRECTORY PER TARGET -- so
#   every path below starts with a target name (`logosdeliverynode/bin/...`,
#   never `bin/...`). `run` is a wrapper on PATH: wine on the Linux pre-filter
#   leg, a direct exec on the real windows-latest leg, so this one file serves
#   both. It refuses a path that does not exist and refuses a command that
#   exits 0 having printed nothing, and on failure reports the exit code, both
#   streams and what shipped beside the binary.
#
# BY HAND, against a native build:
#   SMOKE_NATIVE=1 NODE=./build/logosdeliverynode LIB=./build/liblogosdelivery.so \
#     bash .github/smoke/logos-delivery.sh
#   `run` is then a plain exec and none of the wrapper's checks apply.
set -euo pipefail

if [ -n "${SMOKE_NATIVE:-}" ]; then
  run() { "$@"; }
fi

NODE="${NODE:-logosdeliverynode/bin/logosdeliverynode.exe}"
LIB="${LIB:-liblogosdelivery/bin/liblogosdelivery.dll}"
HDR="${HDR:-liblogosdelivery/include/generated/logosdelivery.h}"

# ---------------------------------------------------------------------------
# 1. The tree carries what a consumer links and dlopens.
#
# The DLL cannot be smoke-RUN -- it has no entry point -- so its presence is
# asserted here and its imports and exports are gated on the builder side
# (windows-gates, and .github/gates/exported-c-abi.sh). What this catches is an
# install rule that silently stopped copying: `min-pes: 1` is satisfied by the
# node's exe alone, so without this line the DLL could vanish and the job would
# still be green.
# ---------------------------------------------------------------------------
for f in "$LIB" "$HDR"; do
  if [ ! -s "$f" ]; then
    echo "::error::$f is missing or empty in the staged tree." >&2
    echo "::error::staged: $(find . -mindepth 1 -maxdepth 1 -type d | sort | tr '\n' ' ')" >&2
    exit 1
  fi
done
echo "staged: $LIB ($(wc -c < "$LIB") bytes), $HDR"

# `generated/logosdelivery.h` is emitted by a Nim compile-time pass whose path
# handling follows the TARGET's separator. Under cross that pass wrote the whole
# path as one backslash-named file at the project root and left include/generated
# empty -- a build that succeeded and shipped no header. It is asserted by name
# because "the header exists" was, for one release, the whole bug.

# ---------------------------------------------------------------------------
# 2. libpq ships beside the node's exe.
#
# `-d:postgres` makes Nim resolve libpq through a module-level {.dynlib.} before
# main() runs, and a bare-name load on Windows searches the image's OWN
# directory -- never the caller's, never a sibling target's. This is asserted
# separately from the run below because no static check can see it: a dlopen
# leaves nothing in the PE import table, so the import-closure gate passes on a
# binary that cannot start. Measured: without these DLLs, `--version` exits 1
# having printed `could not load: libpq.dll` and nothing else.
# ---------------------------------------------------------------------------
if [ ! -s "$(dirname "$NODE")/libpq.dll" ]; then
  echo "::error::libpq.dll is not beside $NODE." >&2
  # shellcheck disable=SC2012  # these are DLL names, not arbitrary input
  echo "::error::shipped there: $(ls -1 "$(dirname "$NODE")" | tr '\n' ' ')" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. The node PE actually starts on Windows.
#
# `--version` is confutils' own early exit, so this is not a functional test of
# the node. It is the load-time test: every import in the PE resolves, the
# statically linked Rust (rln) and C (nat-traversal, libpq's absence) pieces
# initialise, and the process reaches Nim's main. That is the half of Windows
# support that cannot be checked from Linux.
# ---------------------------------------------------------------------------
run "$NODE" --version | tee version.txt
grep -qi 'git commit hash' version.txt

# ...and reaches its own argument parser rather than dying in a static ctor.
run "$NODE" --help | tee help.txt
grep -qi 'usage' help.txt

echo "smoke ok"
