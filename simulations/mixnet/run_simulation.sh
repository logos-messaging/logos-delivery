#!/usr/bin/env bash
# 5-node mix simulation using logoscore instances with embedded delivery + RLN modules.
# Each node is its own logoscore process — no standalone wakunode2 or HTTP polling.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
DELIVERY_DIR="$(cd ../.. && pwd)"
RLN_PROJECT_DIR="$(cd "$DELIVERY_DIR/.." && pwd)"

export RISC0_DEV_MODE=1
export TMPDIR=/tmp

# --- Node identity constants (from config*.toml) ---
NODEKEYS=(
    "f98e3fba96c32e8d1967d460f1b79457380e1a895f7971cecc8528abe733781a"
    "09e9d134331953357bd38bbfce8edb377f4b6308b4f3bfbe85c610497053d684"
    "ed54db994682e857d77cd6fb81be697382dc43aa5cd78e16b0ec8098549f860e"
    "42f96f29f2d6670938b0864aced65a332dcf5774103b4c44ec4d0ea4ef3c47d6"
    "3ce887b3c34b7a92dd2868af33941ed1dbec4893b054572cd5078da09dd923d4"
)
MIXKEYS=(
    "a87db88246ec0eedda347b9b643864bee3d6933eb15ba41e6d58cb678d813258"
    "c86029e02c05a7e25182974b519d0d52fcbafeca6fe191fbb64857fb05be1a53"
    "b858ac16bbb551c4b2973313b1c8c8f7ea469fca03f1608d200bbf58d388ec7f"
    "d8bd379bb394b0f22dd236d63af9f1a9bc45266beffc3fbbe19e8b6575f2535b"
    "780fff09e51e98df574e266bf3266ec6a3a1ddfcf7da826a349a29c137009d49"
)
PEER_IDS=(
    "16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o"
    "16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF"
    "16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA"
    "16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f"
    "16Uiu2HAmRhxmCHBYdXt1RibXrjAUNJbduAhzaTHwFCZT4qWnqZAu"
)
MIX_PUBKEYS=(
    "9d09ce624f76e8f606265edb9cca2b7de9b41772a6d784bddaf92ffa8fba7d2c"
    "9231e86da6432502900a84f867004ce78632ab52cd8e30b1ec322cd795710c2a"
    "275cd6889e1f29ca48e5b9edb800d1a94f49f13d393a0ecf1a07af753506de6c"
    "e0ed594a8d506681be075e8e23723478388fb182477f7a469309a25e7076fc18"
    "8fd7a1a7c19b403d231452a9b1ea40eb1cc76f455d918ef8980e7685f9eeeb1f"
)
BASE_TCP_PORT=60001
BASE_DISC_PORT=9001
NUM_NODES=5

CONTENT_TOPIC="/toy-chat/2/baixa-chiado/proto"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM="darwin-arm64-dev"; EXT="dylib";;
  Linux-x86_64) PLATFORM="linux-x86_64-dev"; EXT="so";;
  Linux-aarch64) PLATFORM="linux-aarch64-dev"; EXT="so";;
  *) echo "Unsupported platform"; exit 1;;
esac

# --- Cleanup ---
SEQUENCER_PID=""
INSTANCE_PIDS=()
MODULES_DIRS=()
WORK_DIR=""
cleanup() {
    echo ""
    echo "=== Shutting down ==="
    for pid in "${INSTANCE_PIDS[@]+"${INSTANCE_PIDS[@]}"}"; do
        if [ -n "$pid" ]; then
            local children
            children=$(pgrep -P "$pid" 2>/dev/null || true)
            kill "$pid" $children 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    pkill -f 'logos_host' 2>/dev/null || true
    if [ -n "$SEQUENCER_PID" ]; then
        kill "$SEQUENCER_PID" 2>/dev/null || true
        wait "$SEQUENCER_PID" 2>/dev/null || true
    fi
    for mdir in "${MODULES_DIRS[@]}"; do
        [ -n "$mdir" ] && rm -rf "$mdir"
    done
    if [ -n "$WORK_DIR" ]; then
        echo "  Logs:       $WORK_DIR"
    fi
    echo "Done."
}
trap cleanup EXIT

echo "=== Mix Simulation (5 LogosCore Instances) ==="
echo "  RLN project: $RLN_PROJECT_DIR"
echo "  Delivery:    $DELIVERY_DIR"
echo ""

pkill -f 'logos_host' 2>/dev/null || true
sleep 1
rm -f /tmp/logos_* 2>/dev/null || true

# ---------- Phase 1: Sequencer ----------
echo "[1/7] Starting sequencer..."

(cd "$RLN_PROJECT_DIR" && git submodule update --init lssa)

if nc -z 127.0.0.1 3040 2>/dev/null; then
    OLD_PID=$(lsof -ti tcp:3040 2>/dev/null || true)
    if [ -n "$OLD_PID" ]; then
        echo "  Port 3040 in use by PID $OLD_PID. Killing..."
        kill "$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
fi

rm -rf "$RLN_PROJECT_DIR/lssa/rocksdb"

echo "  Building sequencer (first run may take several minutes)..."
(cd "$RLN_PROJECT_DIR/lssa" && cargo build --features standalone -p sequencer_runner 2>&1 | tail -3) || {
    echo "  FATAL: sequencer build failed"
    exit 1
}

SEQUENCER_BIN="$RLN_PROJECT_DIR/lssa/target/debug/sequencer_runner"
(cd "$RLN_PROJECT_DIR/lssa" && env RUST_LOG=info "$SEQUENCER_BIN" sequencer_runner/configs/debug) >/dev/null 2>&1 &
SEQUENCER_PID=$!
echo "  PID: $SEQUENCER_PID"

echo "  Waiting for port 3040..."
for i in $(seq 1 300); do
    if nc -z 127.0.0.1 3040 2>/dev/null; then
        echo "  Sequencer ready."
        break
    fi
    if ! kill -0 "$SEQUENCER_PID" 2>/dev/null; then
        echo "  ERROR: Sequencer exited unexpectedly."
        exit 1
    fi
    sleep 1
done
if ! nc -z 127.0.0.1 3040 2>/dev/null; then
    echo "  ERROR: Sequencer did not start within 300s."
    exit 1
fi

# ---------- Phase 2: Deploy programs ----------
echo "[2/7] Deploying programs..."

# Build guest binaries if missing (required by run_setup and register_member)
LEZ_RLN_DIR="$RLN_PROJECT_DIR/lez-rln"
GUEST_BIN="$LEZ_RLN_DIR/methods/guest/target/riscv32im-risc0-zkvm-elf/docker/rln_registration.bin"
if [ ! -f "$GUEST_BIN" ]; then
    if ! command -v cargo-risczero &>/dev/null; then
        echo "  FATAL: zkVM guest binaries not found and cargo-risczero not installed."
        echo "  Install with: cargo install cargo-risczero && cargo risczero install"
        echo "  Requires Docker running for cross-compilation."
        exit 1
    fi
    echo "  Building zkVM guest programs (first run may take several minutes)..."
    (cd "$LEZ_RLN_DIR" && cargo risczero build --manifest-path methods/guest/Cargo.toml 2>&1 | tail -10) || {
        echo "  FATAL: guest program build failed. Is Docker running?"
        exit 1
    }
fi

export NSSA_WALLET_HOME_DIR="$RLN_PROJECT_DIR/dev"
export WALLET_CONFIG="$NSSA_WALLET_HOME_DIR/wallet_config.json"
export WALLET_STORAGE="$NSSA_WALLET_HOME_DIR/storage.json"
rm -f "$WALLET_CONFIG" "$WALLET_STORAGE"

SETUP_OUTPUT=$(cd "$LEZ_RLN_DIR" && cargo run --bin run_setup 2>&1) || {
    echo "  FATAL: run_setup failed:"
    echo "$SETUP_OUTPUT"
    exit 1
}
echo "$SETUP_OUTPUT" | tail -5
TREE_MAIN_ACCOUNT=$(echo "$SETUP_OUTPUT" | grep "Tree main account:" | awk '{print $NF}')
if [ -z "$TREE_MAIN_ACCOUNT" ]; then
    echo "  FATAL: Could not parse tree main account from run_setup output"
    exit 1
fi
echo "  Programs deployed."
echo "  Tree main account: $TREE_MAIN_ACCOUNT"

# ---------- Phase 3: Register 5 members & generate keystores ----------
echo "[3/7] Registering $NUM_NODES members and generating keystores..."

WORK_DIR=$(mktemp -d)

REGISTER_BIN="$LEZ_RLN_DIR/target/release/register_member"
(cd "$LEZ_RLN_DIR" && cargo build --release --bin register_member 2>&1 | tail -3)
if [ ! -f "$REGISTER_BIN" ]; then
    echo "  FATAL: register_member not found at $REGISTER_BIN"
    exit 1
fi

MANIFEST_FILE="$WORK_DIR/manifest.json"
echo "[" > "$MANIFEST_FILE"

LEAF_INDICES=()
IDENTITY_SECRETS=()
CONFIG_ACCOUNT=""

for i in $(seq 0 $((NUM_NODES - 1))); do
    echo "  Registering node $((i+1))/$NUM_NODES..."

    OUTPUT=$(cd "$LEZ_RLN_DIR" && "$REGISTER_BIN" 2>&1) || {
        echo "  FATAL: register_member failed:"
        echo "$OUTPUT"
        exit 1
    }
    CONFIG_ACCOUNT=$(echo "$OUTPUT" | grep "^CONFIG_ACCOUNT=" | cut -d= -f2)
    LEAF_INDEX=$(echo "$OUTPUT" | grep "^LEAF_INDEX=" | cut -d= -f2)
    IDENTITY_SECRET=$(echo "$OUTPUT" | grep "^IDENTITY_SECRET_HASH=" | cut -d= -f2)

    if [ -z "$CONFIG_ACCOUNT" ] || [ -z "$LEAF_INDEX" ] || [ -z "$IDENTITY_SECRET" ]; then
        echo "  FATAL: Failed to parse register_member output:"
        echo "$OUTPUT"
        exit 1
    fi

    LEAF_INDICES+=("$LEAF_INDEX")
    IDENTITY_SECRETS+=("$IDENTITY_SECRET")

    [ "$i" -gt 0 ] && echo "," >> "$MANIFEST_FILE"
    cat >> "$MANIFEST_FILE" <<EOF
  {
    "peerId": "${PEER_IDS[$i]}",
    "leafIndex": $LEAF_INDEX,
    "identitySecretHash": "$IDENTITY_SECRET",
    "rateLimit": 100,
    "configAccount": "$CONFIG_ACCOUNT"
  }
EOF
    echo "    leaf=$LEAF_INDEX"
done

echo "]" >> "$MANIFEST_FILE"
echo "  Config account: $CONFIG_ACCOUNT"

# Generate keystores
echo "  Generating keystores..."
LIBRLN_FILE="$DELIVERY_DIR/librln_v0.9.0.a"
if [ ! -f "$LIBRLN_FILE" ]; then
    echo "  Building librln..."
    (cd "$DELIVERY_DIR" && make librln 2>&1 | tail -5)
fi
if [ ! -f "$LIBRLN_FILE" ]; then
    echo "  FATAL: librln not found at $LIBRLN_FILE"
    exit 1
fi

if [ ! -f "$DELIVERY_DIR/nimbus-build-system.paths" ]; then
    echo "  Generating nim paths..."
    (cd "$DELIVERY_DIR" && make nimbus-build-system-paths 2>&1 | tail -3)
fi

NIM_PATH_ARGS=()
while IFS= read -r line; do
    line="${line//\"/}"
    [[ -n "$line" ]] && NIM_PATH_ARGS+=("$line")
done < "$DELIVERY_DIR/nimbus-build-system.paths"

SETUP_KS_BIN="$WORK_DIR/setup_keystores"
nim c -d:release --mm:refc \
    "${NIM_PATH_ARGS[@]}" \
    --passL:"$LIBRLN_FILE" --passL:"-lm" \
    -o:"$SETUP_KS_BIN" \
    "$SCRIPT_DIR/setup_keystores.nim" 2>&1 | tail -10

if [ ! -f "$SETUP_KS_BIN" ]; then
    echo "  FATAL: Failed to compile setup_keystores.nim"
    exit 1
fi

(cd "$WORK_DIR" && "$SETUP_KS_BIN" "$MANIFEST_FILE") || {
    echo "  FATAL: setup_keystores failed"
    exit 1
}
KEYSTORE_COUNT=$(ls -1 "$WORK_DIR"/rln_keystore_*.json 2>/dev/null | wc -l | tr -d ' ')
echo "  Keystores: $KEYSTORE_COUNT"

# ---------- Phase 4: Build / check modules ----------
echo "[4/7] Building modules (if needed)..."

LOGOSCORE="${LOGOSCORE:-$(nix build github:logos-co/logos-liblogos/7df6195 --override-input logos-cpp-sdk github:logos-co/logos-cpp-sdk/a4bd66c --no-link --print-out-paths)/bin/logoscore}"
WALLET_MODULE_RESULT="$RLN_PROJECT_DIR/logos-rln-module/result-wallet"

NEED_BUILD=0
[ -f "$RLN_PROJECT_DIR/logos-rln-module/result-rln/lib/liblogos_rln_module.$EXT" ] || NEED_BUILD=1
[ -f "$WALLET_MODULE_RESULT/lib/liblogos_execution_zone_wallet_module.$EXT" ] || NEED_BUILD=1
[ -f "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/delivery_module_plugin.$EXT" ] || NEED_BUILD=1

if [ "$NEED_BUILD" -eq 1 ]; then
    echo "  Some modules missing — running build_modules.sh..."
    bash "$RLN_PROJECT_DIR/build_modules.sh" || {
        echo "  FATAL: Module build failed."
        exit 1
    }
fi

[ -f "$RLN_PROJECT_DIR/logos-rln-module/result-rln/lib/liblogos_rln_module.$EXT" ] || { echo "  FATAL: RLN module not found after build."; exit 1; }
[ -f "$WALLET_MODULE_RESULT/lib/liblogos_execution_zone_wallet_module.$EXT" ] || { echo "  FATAL: Wallet module not found after build."; exit 1; }
[ -f "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/delivery_module_plugin.$EXT" ] || { echo "  FATAL: Delivery module not found after build."; exit 1; }
echo "  All modules present."

# Build chat2mix if not present
CHAT2MIX="$DELIVERY_DIR/build/chat2mix"
if [ ! -f "$CHAT2MIX" ] || [ "${REBUILD_NIM:-0}" = "1" ]; then
    echo "  Building chat2mix..."
    (cd "$DELIVERY_DIR" && make chat2mix 2>&1 | tail -5) || {
        echo "  WARNING: chat2mix build failed — chat clients won't be available"
    }
else
    echo "  chat2mix already built."
fi

# ---------- Phase 5: Stage modules ----------
echo "[5/7] Staging modules for $NUM_NODES instances..."

stage_modules() {
    local mdir
    mdir=$(mktemp -d)

    mkdir -p "$mdir/liblogos_execution_zone_wallet_module"
    cp -L "$WALLET_MODULE_RESULT/lib/liblogos_execution_zone_wallet_module.$EXT" "$mdir/liblogos_execution_zone_wallet_module/"
    [ -f "$WALLET_MODULE_RESULT/lib/libwallet_ffi.$EXT" ] && \
      cp -L "$WALLET_MODULE_RESULT/lib/libwallet_ffi.$EXT" "$mdir/liblogos_execution_zone_wallet_module/"
    echo "{\"name\":\"liblogos_execution_zone_wallet_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"liblogos_execution_zone_wallet_module.$EXT\"},\"dependencies\":[],\"capabilities\":[]}" > "$mdir/liblogos_execution_zone_wallet_module/manifest.json"

    mkdir -p "$mdir/liblogos_rln_module"
    cp -L "$RLN_PROJECT_DIR/logos-rln-module/result-rln/lib/liblogos_rln_module.$EXT" "$mdir/liblogos_rln_module/"
    cp -L "$RLN_PROJECT_DIR/logos-rln-module/result-rln/lib/liblez_rln_ffi.$EXT" "$mdir/liblogos_rln_module/" 2>/dev/null || true
    echo "{\"name\":\"liblogos_rln_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"liblogos_rln_module.$EXT\"},\"dependencies\":[\"liblogos_execution_zone_wallet_module\"],\"capabilities\":[]}" > "$mdir/liblogos_rln_module/manifest.json"

    mkdir -p "$mdir/delivery_module"
    cp -L "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/delivery_module_plugin.$EXT" "$mdir/delivery_module/"
    [ -f "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/liblogosdelivery.$EXT" ] && \
      cp -L "$RLN_PROJECT_DIR/logos-delivery-module/result/lib/liblogosdelivery.$EXT" "$mdir/delivery_module/"
    for pq in "$RLN_PROJECT_DIR"/logos-delivery-module/result/lib/libpq*; do
        [ -f "$pq" ] && cp -L "$pq" "$mdir/delivery_module/"
    done
    echo "{\"name\":\"delivery_module\",\"version\":\"1.0.0\",\"type\":\"core\",\"main\":{\"$PLATFORM\":\"delivery_module_plugin.$EXT\"},\"dependencies\":[],\"capabilities\":[]}" > "$mdir/delivery_module/manifest.json"

    echo "$mdir"
}

for i in $(seq 0 $((NUM_NODES - 1))); do
    MDIR=$(stage_modules)
    MODULES_DIRS+=("$MDIR")
    echo "  Node $i modules: $MDIR"
done

LOAD_ORDER="liblogos_execution_zone_wallet_module,liblogos_rln_module,delivery_module"
WALLET_CALL="liblogos_execution_zone_wallet_module.open($WALLET_CONFIG,$WALLET_STORAGE)"

# ---------- Phase 6: Start 5 logoscore instances ----------
echo "[6/7] Starting $NUM_NODES logoscore instances..."

# Write node configs and start instances
for i in $(seq 0 $((NUM_NODES - 1))); do
    TCP_PORT=$((BASE_TCP_PORT + i))
    DISC_PORT=$((BASE_DISC_PORT + i))
    LEAF_INDEX="${LEAF_INDICES[$i]}"
    NODE_CONFIG="$WORK_DIR/node${i}_config.json"
    LOG_FILE="$WORK_DIR/node${i}.log"

    # Bootstrap: node 0 has no entry nodes, others bootstrap to node 0
    if [ "$i" -eq 0 ]; then
        ENTRY_NODES="[]"
    else
        ENTRY_NODES="[\"/ip4/127.0.0.1/tcp/$BASE_TCP_PORT/p2p/${PEER_IDS[0]}\"]"
    fi

    # Build mixNodes array: all OTHER nodes' multiaddr:mixPubKey
    MIX_NODES_JSON=""
    for j in $(seq 0 $((NUM_NODES - 1))); do
        [ "$j" -eq "$i" ] && continue
        J_PORT=$((BASE_TCP_PORT + j))
        [ -n "$MIX_NODES_JSON" ] && MIX_NODES_JSON="$MIX_NODES_JSON, "
        MIX_NODES_JSON="$MIX_NODES_JSON\"/ip4/127.0.0.1/tcp/$J_PORT/p2p/${PEER_IDS[$j]}:${MIX_PUBKEYS[$j]}\""
    done

    cat > "$NODE_CONFIG" <<EOF
{
  "mode": "Core",
  "clusterId": 2,
  "numShardsInNetwork": 1,
  "entryNodes": $ENTRY_NODES,
  "maxMessageSize": "150 KiB",
  "listenAddress": "127.0.0.1",
  "tcpPort": $TCP_PORT,
  "discv5UdpPort": $DISC_PORT,
  "nodekey": "${NODEKEYS[$i]}",
  "mixkey": "${MIXKEYS[$i]}",
  "mixnodes": [$MIX_NODES_JSON],
  "mix": true,
  "enableSpamProtection": true,
  "logLevel": "TRACE"
}
EOF

    echo "  Starting node $i (port $TCP_PORT, leaf $LEAF_INDEX)..."

    (cd "$WORK_DIR" && TMPDIR=/tmp "$LOGOSCORE" -m "${MODULES_DIRS[$i]}" -l "$LOAD_ORDER" \
        -c "$WALLET_CALL" \
        -c "delivery_module.createNode(@$NODE_CONFIG)" \
        -c "delivery_module.start()" \
        -c "delivery_module.subscribe($CONTENT_TOPIC)" \
        -c "delivery_module.setRlnConfig($CONFIG_ACCOUNT,$LEAF_INDEX)" \
        -c "liblogos_rln_module.start_root_broadcast($CONFIG_ACCOUNT)" \
        -c "liblogos_rln_module.start_merkle_proof_broadcast($CONFIG_ACCOUNT,$LEAF_INDEX)" \
        </dev/null >"$LOG_FILE" 2>&1) &
    INSTANCE_PIDS+=($!)
    echo "  Node $i PID: ${INSTANCE_PIDS[$i]}"

    # Wait for all 7 -c calls to succeed
    echo "  Waiting for node $i to initialize..."
    for j in $(seq 1 90); do
        N=$(grep -c '^Method call successful' "$LOG_FILE" 2>/dev/null || true); N=${N:-0}
        [ "$N" -ge 7 ] && break
        if ! kill -0 "${INSTANCE_PIDS[$i]}" 2>/dev/null; then
            N=$(grep -c '^Method call successful' "$LOG_FILE" 2>/dev/null || true); N=${N:-0}
            echo "  ERROR: Node $i exited after $N/7 calls. Method call lines:"
            grep 'Method call' "$LOG_FILE"
            echo "  --- Last 15 log lines ---"
            tail -15 "$LOG_FILE"
            exit 1
        fi
        sleep 1
    done
    if [ "$N" -lt 7 ]; then
        echo "  ERROR: Node $i did not initialize ($N/7 calls). Log:"
        grep 'Method call\|Error' "$LOG_FILE" | tail -10
        exit 1
    fi
    echo "  Node $i ready ($N/7 calls)."

    # Pause between nodes to avoid resource contention
    sleep 3
done

# Wait for peer discovery across all nodes
echo "  Waiting for peer discovery (15s)..."
sleep 15

# ---------- Phase 7: Ready ----------
echo ""
echo "[7/7] Simulation running!"
echo ""
echo "  Sequencer:  PID $SEQUENCER_PID (port 3040)"
echo "  Config:     $CONFIG_ACCOUNT"
echo "  Logs:       $WORK_DIR/node*.log"
echo ""
for i in $(seq 0 $((NUM_NODES - 1))); do
    TCP_PORT=$((BASE_TCP_PORT + i))
    echo "  Node $i: PID ${INSTANCE_PIDS[$i]}, port $TCP_PORT, leaf ${LEAF_INDICES[$i]}"
done
echo ""
echo "  To inspect logs:"
for i in $(seq 0 $((NUM_NODES - 1))); do
    echo "    grep 'Method call' $WORK_DIR/node${i}.log"
done
echo ""
echo "  Now start chat clients in separate terminals:"
echo "    cd $(pwd)"
echo "    bash run_chat_mix.sh"
echo "    bash run_chat_mix1.sh"
echo ""
echo "  Press Ctrl+C to stop everything."

wait
