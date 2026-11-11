#!/usr/bin/env bash
# Fails if a Nim build holds a compiler warning raised in this repo's code.
#
#   scripts/check_compile_warnings.sh              builds the node and the library
#   scripts/check_compile_warnings.sh <log>...     checks existing build logs
#
# Warnings raised inside dependencies (nimbledeps/, ~/.nimble, the Nim stdlib)
# are ignored: they cannot be fixed here. A warning that cannot be fixed in this
# repo is silenced where it is raised with a scoped
# `{.push warning[<Name>]: off.}` ... `{.pop.}` and a comment saying why.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -eq 0 ]; then
  mkdir -p build
  log=build/compile-warnings.log
  echo "compile warnings: building logosdeliverynode and liblogosdelivery, log in: $log"
  make -j1 logosdeliverynode liblogosdelivery 2>&1 | tee "$log"
  set -- "$log"
fi

# A Nim diagnostic reads: <path>(<line>, <col>) Warning: <text> [<Name>]
found=$(
  sed $'s/\x1b\\[[0-9;]*m//g' "$@" |
    awk -v root="$(pwd -P)/" '
      /^[^ ]+\.nims?\([0-9]+, [0-9]+\) Warning: / {
        path = substr($0, 1, index($0, "(") - 1)
        if (substr(path, 1, 1) != "/") path = root path
        if (index(path, root) != 1) next
        rel = substr(path, length(root) + 1)
        if (rel ~ /^(nimbledeps|vendor)\//) next
        print rel substr($0, index($0, "("))
      }
    ' |
    sort -u
)

if [ -z "$found" ]; then
  echo "compile warnings: none"
  exit 0
fi

echo "$found"
echo
echo "compile warnings: $(echo "$found" | wc -l | tr -d ' ') found in this repo's code; fix each one above"
exit 1
