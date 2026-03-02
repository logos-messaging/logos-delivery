#!/usr/bin/env bash
# E2E test: starts the 5-node mix simulation, launches two chat clients,
# sends messages in both directions, and verifies delivery.
# Exit code 0 = all tests passed, 1 = failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configurable timeouts (seconds)
SIM_TIMEOUT=${E2E_SIM_TIMEOUT:-900}
DISCOVERY_WAIT=${E2E_DISCOVERY_WAIT:-60}
MSG_TIMEOUT=${E2E_MSG_TIMEOUT:-120}

PASSED=0
FAILED=0
SIM_PID=""
CHAT1_PID=""
CHAT2_PID=""
SIM_LOG=$(mktemp)
CHAT1_LOG=$(mktemp)
CHAT2_LOG=$(mktemp)
PIPE1="/tmp/e2e_chat1_in_$$"
PIPE2="/tmp/e2e_chat2_in_$$"

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    exec 3>&- 2>/dev/null || true
    exec 4>&- 2>/dev/null || true
    [ -n "$CHAT1_PID" ] && kill "$CHAT1_PID" 2>/dev/null || true
    [ -n "$CHAT2_PID" ] && kill "$CHAT2_PID" 2>/dev/null || true
    if [ -n "$SIM_PID" ]; then
        kill "$SIM_PID" 2>/dev/null || true
        wait "$SIM_PID" 2>/dev/null || true
    fi
    pkill -f logos_host 2>/dev/null || true
    rm -f "$PIPE1" "$PIPE2" 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT

echo "=== RLN Mix Network E2E Test ==="
echo ""

# ── Phase 1: Start simulation ──────────────────────────────────────
echo "[1/5] Starting simulation (this takes a few minutes)..."

bash "$SCRIPT_DIR/run_simulation.sh" > "$SIM_LOG" 2>&1 &
SIM_PID=$!

# Disable errexit — polling loops use grep/kill that may return non-zero
set +e

LAST_STEP=""
ELAPSED=0
while [ $ELAPSED -lt $SIM_TIMEOUT ]; do
    if grep -q '\[7/7\] Simulation running!' "$SIM_LOG" 2>/dev/null; then
        echo "  Simulation ready."
        break
    fi
    # Show simulation progress as new [N/7] lines appear
    STEP_LINE=$(grep -F '/7]' "$SIM_LOG" 2>/dev/null | tail -1)
    if [ -n "$STEP_LINE" ] && [ "$STEP_LINE" != "$LAST_STEP" ]; then
        echo "  $STEP_LINE"
        LAST_STEP="$STEP_LINE"
    fi
    if ! kill -0 "$SIM_PID" 2>/dev/null; then
        echo "FATAL: Simulation exited prematurely."
        tail -30 "$SIM_LOG"
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if ! grep -q '\[7/7\] Simulation running!' "$SIM_LOG" 2>/dev/null; then
    echo "FATAL: Simulation not ready after ${SIM_TIMEOUT}s."
    tail -30 "$SIM_LOG"
    exit 1
fi

# ── Phase 2: Start chat clients ────────────────────────────────────
echo "[2/5] Starting chat clients..."

rm -f "$PIPE1" "$PIPE2"
mkfifo "$PIPE1" "$PIPE2"

# Open FIFOs read-write (<>) so open(2) never blocks and the write end
# stays alive as long as the FD is open — even if readers come and go.
exec 3<>"$PIPE1"
exec 4<>"$PIPE2"

# Start chat clients reading from the FIFOs.
bash "$SCRIPT_DIR/run_chat_mix.sh" < "$PIPE1" > "$CHAT1_LOG" 2>&1 &
CHAT1_PID=$!
bash "$SCRIPT_DIR/run_chat_mix1.sh" < "$PIPE2" > "$CHAT2_LOG" 2>&1 &
CHAT2_PID=$!

echo "TestAlice" >&3
echo "TestBob" >&4
echo "  Clients started, nicknames sent."

# ── Phase 3: Wait for mix node discovery ───────────────────────────
echo "[3/5] Waiting for mix node discovery (up to ${DISCOVERY_WAIT}s)..."

DISC_ELAPSED=0
C1_READY=0
C2_READY=0
while [ $DISC_ELAPSED -lt $DISCOVERY_WAIT ]; do
    [ $C1_READY -eq 0 ] && grep -q "ready to publish messages now" "$CHAT1_LOG" 2>/dev/null && { echo "  Alice: ready"; C1_READY=1; }
    [ $C2_READY -eq 0 ] && grep -q "ready to publish messages now" "$CHAT2_LOG" 2>/dev/null && { echo "  Bob:   ready"; C2_READY=1; }
    [ $C1_READY -eq 1 ] && [ $C2_READY -eq 1 ] && break
    sleep 2
    DISC_ELAPSED=$((DISC_ELAPSED + 2))
done

if [ $C1_READY -eq 0 ] || [ $C2_READY -eq 0 ]; then
    echo "FATAL: Chat clients not ready within ${DISCOVERY_WAIT}s."
    [ $C1_READY -eq 0 ] && { echo "  Alice log tail:"; tail -10 "$CHAT1_LOG"; }
    [ $C2_READY -eq 0 ] && { echo "  Bob log tail:";   tail -10 "$CHAT2_LOG"; }
    exit 1
fi

echo "  Settling filter subscriptions (20s)..."
sleep 20

# ── Phase 4: Send messages and verify delivery ─────────────────────
echo "[4/5] Sending messages and verifying delivery..."

MSG_A="e2e_alice_$(date +%s)"
MSG_B="e2e_bob_$(date +%s)"

check_delivery() {
    local log_file=$1
    local pattern=$2
    local label=$3
    local elapsed=0
    while [ $elapsed -lt $MSG_TIMEOUT ]; do
        if grep -q "$pattern" "$log_file" 2>/dev/null; then
            echo "  PASS: $label"
            PASSED=$((PASSED + 1))
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo "  FAIL: $label (not received after ${MSG_TIMEOUT}s)"
    FAILED=$((FAILED + 1))
    return 0
}

echo "  Sending: Alice -> '$MSG_A'"
echo "$MSG_A" >&3

echo "  Sending: Bob   -> '$MSG_B'"
echo "$MSG_B" >&4

echo "  Waiting for delivery (up to ${MSG_TIMEOUT}s per message)..."

check_delivery "$CHAT2_LOG" "$MSG_A" "Alice -> Bob"
check_delivery "$CHAT1_LOG" "$MSG_B" "Bob -> Alice"

# ── Phase 5: Report ────────────────────────────────────────────────
echo ""
echo "[5/5] Results: $PASSED passed, $FAILED failed"
echo ""

if [ $FAILED -eq 0 ] && [ $PASSED -ge 2 ]; then
    echo "E2E TEST PASSED"
    exit 0
else
    echo "E2E TEST FAILED"
    echo "  Simulation log: $SIM_LOG"
    echo "  Alice log:      $CHAT1_LOG"
    echo "  Bob log:        $CHAT2_LOG"
    exit 1
fi
