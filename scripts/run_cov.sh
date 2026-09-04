#!/bin/sh

# Run this through `make coverage`, which supplies LIBRLN_FILE. The library is
# named for the pinned zerokit release, so this script must not hardcode it.
if [ -z "$LIBRLN_FILE" ]
then
    echo "[ERROR] LIBRLN_FILE is not set. Run 'make coverage'."
    exit 1
fi

# set -e so a failed compile, test run, lcov or genhtml fails this script. The
# cleanup below runs from a trap so it still happens on failure, and its exit
# status cannot mask theirs.
set -e

# Check for lcov tool
if ! command -v lcov >/dev/null 2>&1
then
    echo "[ERROR] You need to have lcov installed in order to generate the test coverage report."
    exit 2
fi

SCRIPT_PATH=$(dirname "$(realpath -s "$0")")
REPO_ROOT=$(dirname $SCRIPT_PATH)
generated_not_to_break_here="$REPO_ROOT/generated_not_to_break_here"

if [ "$1" != "-y" ] && [ -f "$generated_not_to_break_here" ]
then
    echo "The file '$generated_not_to_break_here' already exists. Do you want to continue? (y/n)"
    read -r response
    if [ "$response" != "y" ]
    then
        exit 3
    fi
fi

output_directory="$REPO_ROOT/coverage_html_report"
base_filepath="$REPO_ROOT/tests/test_all"
nim_filepath=$base_filepath.nim
info_filepath=$base_filepath.info

cleanup() {
    rm -rf "$info_filepath" "$base_filepath" nimcache
    rm -f "$generated_not_to_break_here"
}
trap cleanup EXIT

# Workaround a nim bug. See https://github.com/nim-lang/Nim/issues/12376
touch $generated_not_to_break_here

# Generate the coverage report
nim --debugger:native --passC:--coverage --passL:--coverage --passL:"$LIBRLN_FILE" --passL:-lm c $nim_filepath
lcov --base-directory . --directory . --zerocounters -q
$base_filepath
lcov --base-directory . --directory . --include "*/waku/**" --include "*/apps/**" --exclude "*/vendor/**" -c -o $info_filepath
genhtml -o $output_directory $info_filepath
