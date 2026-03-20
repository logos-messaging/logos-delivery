#!/usr/bin/env bash

# This script is used to build the rln library for the current platform.
# Previously downloaded prebuilt binaries, but due to compatibility issues
# we now always build from source.

set -e

# first argument is the build directory
build_dir=$1
rln_version=$2
output_filename=$3

[[ -z "${build_dir}" ]]       && { echo "No build directory specified"; exit 1; }
[[ -z "${rln_version}" ]]     && { echo "No rln version specified";     exit 1; }
[[ -z "${output_filename}" ]] && { echo "No output filename specified"; exit 1; }

echo "Building RLN library from source (version ${rln_version})..."

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

# Build rln from source
cargo build --release -p rln --manifest-path "${build_dir}/rln/Cargo.toml"
cp "${build_dir}/target/release/librln.a" "${output_filename}"

echo "Successfully built ${output_filename}"
