#!/usr/bin/env bash

# Build a separate, pinned RLN library for mix spam-protection usage.
# This keeps the main nwaku RLN dependency flow unchanged.

set -euo pipefail

source_dir="${1:-}"
version="${2:-}"
output_file="${3:-}"
repo_url="${4:-https://github.com/vacp2p/zerokit.git}"

if [[ -z "${source_dir}" || -z "${version}" || -z "${output_file}" ]]; then
  echo "Usage: $0 <source_dir> <version_tag> <output_file> [repo_url]"
  exit 1
fi

mkdir -p "$(dirname "${source_dir}")"
mkdir -p "$(dirname "${output_file}")"

if [[ ! -d "${source_dir}/.git" ]]; then
  echo "Cloning zerokit ${version} from ${repo_url}..."
  if [[ -e "${source_dir}" ]]; then
    echo "Path exists but is not a git repository: ${source_dir}"
    echo "Please remove it and retry."
    exit 1
  fi
  git clone --depth 1 --branch "${version}" "${repo_url}" "${source_dir}"
else
  echo "Using existing zerokit checkout in ${source_dir}"
  current_tag="$(git -C "${source_dir}" describe --tags --exact-match 2>/dev/null || true)"
  if [[ "${current_tag}" != "${version}" ]]; then
    echo "Updating zerokit checkout to ${version}..."
    git -C "${source_dir}" fetch --tags origin "${version}"
    git -C "${source_dir}" checkout --detach "${version}"
  fi
fi

echo "Building mix RLN library from source (version ${version})..."
cargo build --release -p rln --manifest-path "${source_dir}/rln/Cargo.toml"

cp "${source_dir}/target/release/librln.a" "${output_file}"
echo "Successfully built ${output_file}"
