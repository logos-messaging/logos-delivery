#!/bin/bash
cd "$(dirname "$0")"
MIXNET_DIR=$(pwd)
cd ../..
ROOT_DIR=$(pwd)

# Source env.sh to get the correct nim with vendor paths
source "$ROOT_DIR/env.sh"

# Clean up old keystore files
rm -f "$MIXNET_DIR"/rln_keystore_*.json

echo "Building and running credentials setup..."
# Compile to temp location, then run from mixnet directory
nim c -d:release --mm:refc \
    --passL:"-L$ROOT_DIR/vendor/zerokit/target/release -lrln" \
    -o:/tmp/setup_credentials_$$ \
    "$MIXNET_DIR/setup_credentials.nim" 2>&1 | tail -30

# Run from mixnet directory so files are created there
cd "$MIXNET_DIR"
/tmp/setup_credentials_$$
RESULT=$?

# Clean up temp binary
rm -f /tmp/setup_credentials_$$

# Verify output
if [ $RESULT -eq 0 ]; then
    echo ""
    KEYSTORE_COUNT=$(ls -1 rln_keystore_*.json 2>/dev/null | wc -l | tr -d ' ')
    echo "Generated $KEYSTORE_COUNT keystore files"
else
    echo "Setup failed"
    exit 1
fi
