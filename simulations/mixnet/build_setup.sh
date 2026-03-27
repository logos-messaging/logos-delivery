#!/bin/bash
cd "$(dirname "$0")"
MIXNET_DIR=$(pwd)
cd ../..
ROOT_DIR=$(pwd)
source "$ROOT_DIR/env.sh"

# Prefer explicitly provided RLN library path, otherwise use local migrated build.
LIBRLN_PATH=${LIBRLN_PATH:-"/Users/prem/Code/mix-rln-spam-protection-plugin/librln.a"}

# Clean up old files first
rm -f "$MIXNET_DIR/rln_tree.db" "$MIXNET_DIR"/rln_keystore_*.json

echo "Building and running credentials setup..."
# Compile to temp location, then run from mixnet directory
nim c -d:release --mm:refc \
    --passL:"$LIBRLN_PATH" --passL:-lm \
    -o:/tmp/setup_credentials_$$ \
    "$MIXNET_DIR/setup_credentials.nim" 2>&1 | tail -30

# Run from mixnet directory so files are created there
cd "$MIXNET_DIR"
/tmp/setup_credentials_$$

# Clean up temp binary
rm -f /tmp/setup_credentials_$$

# Verify output
if [ -f "rln_tree.db" ]; then
    echo ""
    echo "Tree file ready at: $(pwd)/rln_tree.db"
    ls -la rln_keystore_*.json 2>/dev/null | wc -l | xargs -I {} echo "Generated {} keystore files"
else
    echo "Setup failed - rln_tree.db not found"
    exit 1
fi
