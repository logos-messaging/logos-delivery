#!/usr/bin/env bash

# Provides the rln static library for the current platform.
#
# If zerokit publishes a prebuilt `stateless` release asset for this platform,
# download and use it: that is faster than compiling and avoids fetching
# zerokit's many crate dependencies from crates.io. The asset is selected by
# the Rust host target triple (the platform identifier reported by rustc,
# e.g. x86_64-unknown-linux-gnu or aarch64-apple-darwin).
#
# When no matching asset exists (e.g. Windows), build from the vendored
# zerokit submodule instead.

set -e

# first argument is the build directory
build_dir=$1
rln_version=$2
output_filename=$3

[[ -z "${build_dir}" ]]       && { echo "No build directory specified"; exit 1; }
[[ -z "${rln_version}" ]]     && { echo "No rln version specified";     exit 1; }
[[ -z "${output_filename}" ]] && { echo "No output filename specified"; exit 1; }

# --- Prefer the prebuilt release asset --------------------------------------
# Host target triple, e.g. x86_64-unknown-linux-gnu / aarch64-apple-darwin.
host_triplet=$(rustc --version --verbose | awk '/host:/{print $2}')
tarball="${host_triplet}-stateless-rln.tar.gz"
url="https://github.com/vacp2p/zerokit/releases/download/${rln_version}/${tarball}"

echo "Looking for prebuilt RLN: ${url}"
if curl --silent --fail-with-body -L "${url}" -o "${tarball}"; then
    echo "Downloaded prebuilt ${tarball}"
    tar -xzf "${tarball}"
    mv "release/librln.a" "${output_filename}"
    rm -rf "${tarball}" release
    echo "Using prebuilt ${output_filename}"
    exit 0
fi
# curl --fail-with-body writes the error body to the file on HTTP failure.
rm -f "${tarball}"
echo "No prebuilt asset for ${host_triplet} at ${rln_version}; building from source."

# --- Fall back to building from the vendored submodule ----------------------
# Check if submodule version = version in Makefile
cargo metadata --format-version=1 --no-deps --manifest-path "${build_dir}/rln/Cargo.toml"

detected_OS=$(uname -s)
if [[ "$detected_OS" == MINGW* || "$detected_OS" == MSYS* ]]; then
    submodule_version=$(cargo metadata --format-version=1 --no-deps --manifest-path "${build_dir}/rln/Cargo.toml" | sed -n 's/.*"name":"rln","version":"\([^"]*\)".*/\1/p')
else
    submodule_version=$(cargo metadata --format-version=1 --no-deps --manifest-path "${build_dir}/rln/Cargo.toml" | jq -r '.packages[] | select(.name == "rln") | .version')
fi

if [[ "v${submodule_version}" != "${rln_version}" ]]; then
    echo "Submodule version (v${submodule_version}) does not match version in Makefile (${rln_version})"
    echo "Please update the submodule to ${rln_version}"
    exit 1
fi

# `stateless` feature: logos-delivery does not maintain a local Merkle tree
# (post-PR #3312); the contract is the source of truth and the path is fetched
# via getMerkleProof(index). The stateless build compiles out tree code.
#
# --no-default-features is required because zerokit's default features include
# `pmtree-ft` (a Merkle tree backend); `stateless` and any Merkle-tree feature
# are mutually exclusive (rln/src/lib.rs:32 compile_error).
cargo build --release -p rln --manifest-path "${build_dir}/rln/Cargo.toml" \
    --no-default-features --features stateless
cp "${build_dir}/target/release/librln.a" "${output_filename}"

echo "Successfully built ${output_filename}"
