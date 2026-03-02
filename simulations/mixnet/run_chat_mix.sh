#!/usr/bin/env bash
# Chat client 1 — connects via lightpush to the mix network.
# Run this AFTER run_simulation.sh has all 5 nodes up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHAT2MIX="$DELIVERY_DIR/build/chat2mix"

if [ ! -f "$CHAT2MIX" ]; then
    echo "chat2mix not found. Build with: cd $DELIVERY_DIR && make chat2mix"
    exit 1
fi

NODE0_ADDR="/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o"

"$CHAT2MIX" \
    --ports-shift=200 \
    --cluster-id=2 \
    --num-shards-in-network=1 \
    --shard=0 \
    --servicenode="$NODE0_ADDR" \
    --log-level=TRACE \
    --nodekey="cb6fe589db0e5d5b48f7e82d33093e4d9d35456f4aaffc2322c473a173b2ac49" \
    --kad-bootstrap-node="$NODE0_ADDR" \
    --mixnode="/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o:9d09ce624f76e8f606265edb9cca2b7de9b41772a6d784bddaf92ffa8fba7d2c" \
    --mixnode="/ip4/127.0.0.1/tcp/60002/p2p/16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF:9231e86da6432502900a84f867004ce78632ab52cd8e30b1ec322cd795710c2a" \
    --mixnode="/ip4/127.0.0.1/tcp/60003/p2p/16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA:275cd6889e1f29ca48e5b9edb800d1a94f49f13d393a0ecf1a07af753506de6c" \
    --mixnode="/ip4/127.0.0.1/tcp/60004/p2p/16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f:e0ed594a8d506681be075e8e23723478388fb182477f7a469309a25e7076fc18" \
    --mixnode="/ip4/127.0.0.1/tcp/60005/p2p/16Uiu2HAmRhxmCHBYdXt1RibXrjAUNJbduAhzaTHwFCZT4qWnqZAu:8fd7a1a7c19b403d231452a9b1ea40eb1cc76f455d918ef8980e7685f9eeeb1f" \
    --fleet="none"
