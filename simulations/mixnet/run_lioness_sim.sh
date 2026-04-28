#!/bin/bash
# Headless mixnet simulation driver for the LIONESS payload-encryption branch.
# Starts 5 mix nodes + 2 chat clients in background, sends a test message
# from alice → bob through the mixnet, captures cover-traffic metrics, tears down.

set -u
cd "$(dirname "$0")"

# --- cleanup helper ---------------------------------------------------
cleanup() {
  echo "[cleanup] killing wakunode2 + chat2mix processes..."
  pkill -f 'wakunode2 --config-file' 2>/dev/null
  pkill -f 'chat2mix --cluster-id=2' 2>/dev/null
  sleep 1
}
trap cleanup EXIT

# --- start mix nodes --------------------------------------------------
echo "[sim] starting bootstrap mix node..."
./run_mix_node.sh > mix_node.log 2>&1 &
sleep 6

for i in 1 2 3 4; do
  echo "[sim] starting mix node $i..."
  ./run_mix_node$i.sh > mix_node$i.log 2>&1 &
  sleep 2
done

echo "[sim] waiting 15s for nodes to peer..."
sleep 15

echo "[sim] checking node setup completion..."
for f in mix_node.log mix_node1.log mix_node2.log mix_node3.log mix_node4.log; do
  if grep -q "Node setup complete" "$f"; then
    echo "  [ok] $f"
  else
    echo "  [WARN] $f missing 'Node setup complete'"
  fi
done

# --- baseline metrics -------------------------------------------------
echo ""
echo "[sim] === baseline cover-traffic metrics (t0) ==="
./check_cover_traffic.sh > metrics_t0.log 2>&1
cat metrics_t0.log

# --- chat clients -----------------------------------------------------
echo ""
echo "[sim] launching chat clients..."

# alice: nickname → wait → send message → wait → /exit
( echo "alice"
  sleep 20
  echo "Hello from Alice via LIONESS!"
  sleep 25
  echo "/exit"
) | ./run_chat_mix.sh > chat_alice.log 2>&1 &

# bob: nickname → wait → /exit (just listening)
( echo "bob"
  sleep 50
  echo "/exit"
) | ./run_chat_mix1.sh > chat_bob.log 2>&1 &

echo "[sim] waiting 60s for message round-trip through mixnet..."
sleep 60

# --- verify message receipt ------------------------------------------
echo ""
echo "[sim] === message delivery check ==="
if grep -q "Hello from Alice via LIONESS" chat_bob.log; then
  echo "[PASS] Bob received Alice's message"
  grep "Hello from Alice" chat_bob.log
else
  echo "[FAIL] Bob did not receive Alice's message"
  echo "--- last 20 lines of chat_bob.log ---"
  tail -20 chat_bob.log
fi

# --- final metrics ----------------------------------------------------
echo ""
echo "[sim] === post-traffic cover-traffic metrics (t1) ==="
./check_cover_traffic.sh > metrics_t1.log 2>&1
cat metrics_t1.log

echo ""
echo "[sim] done. Logs: mix_node*.log, chat_alice.log, chat_bob.log, metrics_t{0,1}.log"
