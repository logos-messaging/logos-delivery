#!/usr/bin/env bash

# Simple script to regenerate the Anvil state file
# This creates a state file compatible with the current Foundry version

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$PROJECT_ROOT/tests/waku_rln_relay/anvil_state"
STATE_FILE="$STATE_DIR/state-deployed-contracts-mint-and-approved.json"
STATE_FILE_GZ="${STATE_FILE}.gz"

echo "==================================="
echo "Anvil State File Regeneration Tool"
echo "==================================="
echo ""

# Check if Foundry is installed
if ! command -v anvil &> /dev/null; then
    echo "ERROR: anvil is not installed!"
    echo "Please run: make rln-deps"
    exit 1
fi

ANVIL_VERSION=$(anvil --version 2>/dev/null | head -n1)
echo "Using Foundry: $ANVIL_VERSION"
echo ""

# Backup existing state file
if [ -f "$STATE_FILE_GZ" ]; then
    BACKUP_FILE="${STATE_FILE_GZ}.backup-$(date +%Y%m%d-%H%M%S)"
    echo "Backing up existing state file to: $(basename $BACKUP_FILE)"
    cp "$STATE_FILE_GZ" "$BACKUP_FILE"
fi

# Remove old state files
rm -f "$STATE_FILE" "$STATE_FILE_GZ"

echo ""
echo "Running test to generate fresh state file..."
echo "This will:"
echo "  1. Build RLN library"
echo "  2. Start Anvil with state dump enabled"
echo "  3. Deploy contracts"  
echo "  4. Save state and compress it"
echo ""

cd "$PROJECT_ROOT"

# Run a single test that deploys contracts
# The test framework will handle state dump
make test tests/waku_rln_relay/test_rln_group_manager_onchain.nim "RLN instances" || {
    echo ""
    echo "Test execution completed (exit status: $?)"
    echo "Checking if state file was generated..."
}

# Check if state file was created
if [ -f "$STATE_FILE" ]; then
    echo ""
    echo "✓ State file generated: $STATE_FILE"
    
    # Compress it
    gzip -c "$STATE_FILE" > "$STATE_FILE_GZ"
    echo "✓ Compressed: $STATE_FILE_GZ"
    
    # File sizes
    STATE_SIZE=$(du -h "$STATE_FILE" | cut -f1)
    GZ_SIZE=$(du -h "$STATE_FILE_GZ" | cut -f1)
    echo ""
    echo "File sizes:"
    echo "  Uncompressed: $STATE_SIZE"
    echo "  Compressed:   $GZ_SIZE"
    
    # Optionally remove uncompressed
    echo ""
    read -p "Remove uncompressed state file? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm "$STATE_FILE"
        echo "✓ Removed uncompressed file"
    fi
    
    echo ""
    echo "============================================"
    echo "✓ SUCCESS! State file regenerated"
    echo "============================================"
    echo ""
    echo "Next steps:"
    echo "  1. Test locally: make test tests/node/test_wakunode_lightpush.nim"
    echo "  2. If tests pass, commit: git add $STATE_FILE_GZ"
    echo "  3. Push and verify CI passes"
    echo ""
else
    echo ""
    echo "============================================"
    echo "✗ ERROR: State file was not generated"
    echo "============================================"
    echo ""
    echo "The state file should have been created at: $STATE_FILE"
    echo "Please check the test output above for errors."
    exit 1
fi
