#!/bin/bash
# Check cover traffic metrics from all mix nodes.
# Ports: 8008 + ports-shift (1-5) = 8009-8013

echo "=== Cover Traffic Metrics ==="
echo ""

for i in 1 2 3 4 5; do
  port=$((8008 + i))
  echo "--- Node $i (port $port) ---"
  metrics=$(curl -s "http://127.0.0.1:$port/metrics" 2>/dev/null)
  if [ -z "$metrics" ]; then
    echo "  (unreachable)"
  else
    echo "$metrics" | grep -E "mix_cover_|mix_slot_" | grep -v "^#" || echo "  (no cover metrics yet)"
  fi
  echo ""
done
