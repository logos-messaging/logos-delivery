#!/usr/bin/env bash

nwaku_build_dir=$1
zerokit_dir=$2
rln_version=$3
android_arch=$4
abi=$5

[[ -z "${nwaku_build_dir}" ]] && { echo "No nwaku build directory specified"; exit 1; }
[[ -z "${zerokit_dir}" ]]     && { echo "No zerokit directory specified";     exit 1; }
[[ -z "${rln_version}" ]]     && { echo "No rln version specified";           exit 1; }
[[ -z "${android_arch}" ]]    && { echo "No android architecture specified";  exit 1; }
[[ -z "${abi}" ]]             && { echo "No abi specified";                   exit 1; }

set -e

export RUSTFLAGS="-Ccodegen-units=1"

# cross compiles the Rust lib inside Docker images that bundle their own
# Android toolchain; pinned so upstream changes cannot break this build.
if ! command -v cross >/dev/null 2>&1; then
  cargo install cross --git https://github.com/cross-rs/cross --rev 55f84725
fi

output_dir=`echo ${nwaku_build_dir}/android/${abi}`
mkdir -p ${output_dir}
pushd ${zerokit_dir}/rln
cross rustc --release --lib --target=${android_arch} --crate-type=cdylib
cp ../target/${android_arch}/release/librln.so ${output_dir}/.
popd
