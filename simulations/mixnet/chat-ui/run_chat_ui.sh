#!/usr/bin/env bash
# Run a logos-chat-ui client against this mixnet sim.
#
#   ./run_chat_ui.sh A     # first client  (adopts provisioned chat membership 1)
#   ./run_chat_ui.sh B     # second client (adopts provisioned chat membership 2)
#
# Each client adopts one of the two provisioned chat memberships via CHAT_NODEKEY
# (the same nodekeys run_chat_mix*.sh use), and runs from a per-client dir holding
# the RLN tree + keystores — mountMix loads rln_keystore_<peerId>.json + rln_tree.db
# from cwd, and CHAT_NODEKEY fixes the peerId so the right keystore resolves.
#
# Prereqs (from ../):
#   1. make wakunode2            # build the mix node binary
#   2. ./build_setup.sh          # generate rln_tree.db + keystores
#   3. ./run_mix_node.sh and run_mix_node1..4.sh   # all 5 mix nodes running
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SIM="$(cd "$HERE/.." && pwd)"
source "$HERE/env.sh"

case "${1:-}" in
  A) export CHAT_NAME=ClientA CHAT_PORT=60010 \
       CHAT_NODEKEY=35eace7ccb246f20c487e05015ca77273d8ecaed0ed683de3d39bf4f69336feb ;;
  B) export CHAT_NAME=ClientB CHAT_PORT=60011 \
       CHAT_NODEKEY=cb6fe589db0e5d5b48f7e82d33093e4d9d35456f4aaffc2322c473a173b2ac49 ;;
  *) echo "usage: $0 <A|B>"; exit 1 ;;
esac

DIR="$HERE/run-${1}"
mkdir -p "$DIR"
cp -f "$SIM/rln_tree.db" "$DIR/" 2>/dev/null \
  || { echo "missing rln_tree.db — run ../build_setup.sh first"; exit 1; }
cp -f "$SIM"/rln_keystore_*.json "$DIR/"

cd "$DIR"
exec nix run "$CHAT_UI" --accept-flake-config
