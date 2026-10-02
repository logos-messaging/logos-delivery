#!/bin/bash

# === Configuration ===
WAKUCANARY_BINARY="../../../build/wakucanary"
PEER_ADDRESS="/dns4/store-01.do-ams3.status.staging.status.im/tcp/30303/p2p/16Uiu2HAm3xVDaz6SRJ6kErwC21zBJEZjavVXg7VSkoWzaV1aMA3F"
TIMEOUT=5
LOG_LEVEL="info"
PROTOCOLS=("store" "relay" "lightpush" "filter" "peer-exchange" "store-sync" "mix")

# === Logging Setup ===
LOG_DIR="logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/ping_test_$TIMESTAMP.log"

echo "Building Waku Canary app..."
( cd ../../../ && make wakucanary ) >> "$LOG_FILE" 2>&1

echo "Protocol Support Test - $TIMESTAMP" | tee -a "$LOG_FILE"
echo "Peer: $PEER_ADDRESS" | tee -a "$LOG_FILE"
echo "---------------------------------------" | tee -a "$LOG_FILE"

# === Protocol Testing Loop ===
for PROTOCOL in "${PROTOCOLS[@]}"; do
  TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
  LOG_FILE="$LOG_DIR/ping_test_${PROTOCOL}_$TIMESTAMP.log"

  {
    echo "=== Canary Run: $TIMESTAMP ==="
    echo "Peer     : $PEER_ADDRESS"
    echo "Protocol : $PROTOCOL"
    echo "LogLevel : DEBUG"
    echo "-----------------------------------"
    $WAKUCANARY_BINARY \
      --address="$PEER_ADDRESS" \
      --protocol="$PROTOCOL" \
      --log-level=DEBUG
    echo "-----------------------------------"
    echo "Exit code: $?"
  } 2>&1 | tee "$LOG_FILE"

  echo "✅ Log saved to: $LOG_FILE"
  echo ""
done

echo "All protocol checks completed. Log saved to: $LOG_FILE"
