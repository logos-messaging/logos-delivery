#!/bin/bash
# Build and run RLN credential setup for the mix simulation.
#
# Prerequisites:
# - Sequencer running (bash dev.sh)
# - Programs deployed (source dev/env.sh && cargo run --bin run_setup)
# - Environment set up (source dev/env.sh)
#
# This script:
# 1. Builds register_member binary
# 2. Registers 7 members on-chain (one per node)
# 3. Generates keystores via setup_keystores.nim

set -euo pipefail
cd "$(dirname "$0")"
MIXNET_DIR=$(pwd)
cd ../..
ROOT_DIR=$(pwd)
RLN_PROJECT_DIR="${RLN_PROJECT_DIR:-$(cd "$ROOT_DIR/../.." && pwd)}"

echo "=== RLN Mix Simulation Setup ==="
echo "  Mixnet dir: $MIXNET_DIR"
echo "  RLN project: $RLN_PROJECT_DIR"
echo ""

# Peer IDs derived from nodekeys in config files
PEER_IDS=(
    "16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o"  # config.toml (service node)
    "16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF"  # config1.toml (mix node 1)
    "16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA"  # config2.toml (mix node 2)
    "16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f"  # config3.toml (mix node 3)
    "16Uiu2HAmRhxmCHBYdXt1RibXrjAUNJbduAhzaTHwFCZT4qWnqZAu"  # config4.toml (mix node 4)
    "16Uiu2HAm1QxSjNvNbsT2xtLjRGAsBLVztsJiTHr9a3EK96717hpj"  # chat2mix client 1
    "16Uiu2HAmC9h26U1C83FJ5xpE32ghqya8CaZHX1Y7qpfHNnRABscN"  # chat2mix client 2
)

RATE_LIMITS=(100 100 100 100 100 100 100)

# Step 1: Build register_member
echo "[1/3] Building register_member..."
(cd "$RLN_PROJECT_DIR" && cargo build --release --bin register_member 2>&1 | tail -5)
REGISTER_BIN="$RLN_PROJECT_DIR/target/release/register_member"
if [ ! -f "$REGISTER_BIN" ]; then
    echo "FATAL: register_member binary not found at $REGISTER_BIN"
    exit 1
fi

# Step 2: Register members and build manifest
echo "[2/3] Registering ${#PEER_IDS[@]} members on-chain..."
MANIFEST_FILE="$MIXNET_DIR/credentials_manifest.json"
echo "[" > "$MANIFEST_FILE"

for i in "${!PEER_IDS[@]}"; do
    PEER_ID="${PEER_IDS[$i]}"
    RATE_LIMIT="${RATE_LIMITS[$i]}"
    echo "  Registering node $((i+1))/${#PEER_IDS[@]} ($PEER_ID)..."

    OUTPUT=$("$REGISTER_BIN" 2>&1)

    CONFIG_ACCOUNT=$(echo "$OUTPUT" | grep "^CONFIG_ACCOUNT=" | cut -d= -f2)
    LEAF_INDEX=$(echo "$OUTPUT" | grep "^LEAF_INDEX=" | cut -d= -f2)
    IDENTITY_SECRET_HASH=$(echo "$OUTPUT" | grep "^IDENTITY_SECRET_HASH=" | cut -d= -f2)

    if [ -z "$CONFIG_ACCOUNT" ] || [ -z "$LEAF_INDEX" ] || [ -z "$IDENTITY_SECRET_HASH" ]; then
        echo "FATAL: Failed to parse register_member output for node $((i+1))"
        echo "Output was: $OUTPUT"
        exit 1
    fi

    # Add comma separator for all but first entry
    if [ "$i" -gt 0 ]; then
        echo "," >> "$MANIFEST_FILE"
    fi

    cat >> "$MANIFEST_FILE" <<EOF
  {
    "peerId": "$PEER_ID",
    "leafIndex": $LEAF_INDEX,
    "identitySecretHash": "$IDENTITY_SECRET_HASH",
    "rateLimit": $RATE_LIMIT,
    "configAccount": "$CONFIG_ACCOUNT"
  }
EOF

    echo "    Registered at leaf index $LEAF_INDEX"
done

echo "]" >> "$MANIFEST_FILE"

# Save CONFIG_ACCOUNT for logoscore (all nodes share the same config account)
FIRST_CONFIG_ACCOUNT=$(echo "$OUTPUT" | grep "^CONFIG_ACCOUNT=" | head -1 | cut -d= -f2)
echo "$FIRST_CONFIG_ACCOUNT" > "$MIXNET_DIR/config_account.txt"
echo ""
echo "  Config account: $FIRST_CONFIG_ACCOUNT"
echo "  Manifest: $MANIFEST_FILE"

# Step 3: Generate keystores
echo "[3/3] Generating keystores..."
cd "$MIXNET_DIR"

source "$ROOT_DIR/env.sh"

nim c -d:release --mm:refc \
    --passL:"-L$ROOT_DIR/vendor/zerokit/target/release -lrln" \
    -o:/tmp/setup_keystores_$$ \
    "$MIXNET_DIR/setup_keystores.nim" 2>&1 | tail -10

/tmp/setup_keystores_$$ "$MANIFEST_FILE"
RESULT=$?
rm -f /tmp/setup_keystores_$$

if [ $RESULT -ne 0 ]; then
    echo "FATAL: Keystore generation failed"
    exit 1
fi

KEYSTORE_COUNT=$(ls -1 rln_keystore_*.json 2>/dev/null | wc -l | tr -d ' ')
echo ""
echo "=== Setup Complete ==="
echo "  Registered: ${#PEER_IDS[@]} members"
echo "  Keystores: $KEYSTORE_COUNT files"
echo "  Config account: $(cat config_account.txt)"
echo ""
echo "Next steps:"
echo "  1. Start logoscore with RLN module + HTTP service"
echo "  2. Run mix nodes and chat clients"
