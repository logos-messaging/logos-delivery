#!/usr/bin/env bash

# Generates nix/submodules.json from .gitmodules and git ls-tree.
# This allows Nix to fetch all git submodules without requiring
# locally initialized submodules or the '?submodules=1' URI flag.
#
# Usage: ./scripts/generate_nix_submodules.sh
#
# Run this script after:
#   - Adding/removing submodules
#   - Updating submodule commits (e.g. after 'make update')
#   - Any change to .gitmodules
#
# Compatible with macOS bash 3.x (no associative arrays).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${REPO_ROOT}/nix/submodules.json"

cd "$REPO_ROOT"

TMP_URLS=$(mktemp)
TMP_REVS=$(mktemp)
trap 'rm -f "$TMP_URLS" "$TMP_REVS"' EXIT

# Parse .gitmodules: extract (path, url) pairs
current_path=""
while IFS= read -r line; do
  case "$line" in
    *"path = "*)
      current_path="${line#*path = }"
      ;;
    *"url = "*)
      if [ -n "$current_path" ]; then
        url="${line#*url = }"
        url="${url%/}"
        printf '%s\t%s\n' "$current_path" "$url" >> "$TMP_URLS"
        current_path=""
      fi
      ;;
  esac
done < .gitmodules

# Get pinned commit hashes from git tree
git ls-tree HEAD vendor/ | while IFS= read -r tree_line; do
  mode=$(echo "$tree_line" | awk '{print $1}')
  type=$(echo "$tree_line" | awk '{print $2}')
  hash=$(echo "$tree_line" | awk '{print $3}')
  path=$(echo "$tree_line" | awk '{print $4}')
  if [ "$type" = "commit" ]; then
    path="${path%/}"
    printf '%s\t%s\n' "$path" "$hash" >> "$TMP_REVS"
  fi
done

# Generate JSON by joining urls and revs on path
printf '[\n' > "$OUTPUT"
first=true

sort "$TMP_URLS" | while IFS="$(printf '\t')" read -r path url; do
  rev=$(grep "^${path}	" "$TMP_REVS" | cut -f2 || true)

  if [ -z "$rev" ]; then
    echo "WARNING: No commit hash found for submodule '$path', skipping" >&2
    continue
  fi

  if [ "$first" = true ]; then
    first=false
  else
    printf '  ,\n' >> "$OUTPUT"
  fi

  printf '  {\n    "path": "%s",\n    "url": "%s",\n    "rev": "%s"\n  }\n' \
    "$path" "$url" "$rev" >> "$OUTPUT"
done

printf ']\n' >> "$OUTPUT"

count=$(grep -c '"path"' "$OUTPUT" || echo 0)
echo "Generated $OUTPUT with $count submodule entries"
