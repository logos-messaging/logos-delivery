# Shared env for running logos-chat-ui clients against this mixnet sim.
# Values mirror ../config*.toml (5 mix nodes on tcp/60001-60005, clusterId 2,
# shard 0). Sourced by run_chat_ui.sh.

# The 5 sim mix nodes as <multiaddr>:<curve25519 mix pubkey>, comma-separated.
# NOTE: the chat client seeds its mix pool from this STATIC list — it does NOT do
# mix-peer discovery — so every node must be listed explicitly.
export CHAT_MIX_NODES="\
/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o:9d09ce624f76e8f606265edb9cca2b7de9b41772a6d784bddaf92ffa8fba7d2c,\
/ip4/127.0.0.1/tcp/60002/p2p/16Uiu2HAmLtKaFaSWDohToWhWUZFLtqzYZGPFuXwKrojFVF6az5UF:9231e86da6432502900a84f867004ce78632ab52cd8e30b1ec322cd795710c2a,\
/ip4/127.0.0.1/tcp/60003/p2p/16Uiu2HAmTEDHwAziWUSz6ZE23h5vxG2o4Nn7GazhMor4bVuMXTrA:275cd6889e1f29ca48e5b9edb800d1a94f49f13d393a0ecf1a07af753506de6c,\
/ip4/127.0.0.1/tcp/60004/p2p/16Uiu2HAmPwRKZajXtfb1Qsv45VVfRZgK3ENdfmnqzSrVm3BczF6f:e0ed594a8d506681be075e8e23723478388fb182477f7a469309a25e7076fc18,\
/ip4/127.0.0.1/tcp/60005/p2p/16Uiu2HAmRhxmCHBYdXt1RibXrjAUNJbduAhzaTHwFCZT4qWnqZAu:8fd7a1a7c19b403d231452a9b1ea40eb1cc76f455d918ef8980e7685f9eeeb1f"

# Bootstrap mix node, which doubles as the relay the chat connects to (for
# receiving + RLN membership broadcast).
export CHAT_STATIC_PEER="/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAmPiEs2ozjjJF2iN2Pe2FYeMC9w4caRHKYdLdAfjgbWM6o"

export CHAT_CLUSTER_ID=2
export CHAT_SHARD_ID=0
export CHAT_MIN_MIX_POOL=4
export CHAT_MIX_REQUIRED=1   # force Required (mix) mode without the UI toggle

# logos-chat-ui flake to run. Override with a local checkout to iterate, e.g.
#   CHAT_UI="$HOME/Code/logos-chat-ui" ./run_chat_ui.sh A
export CHAT_UI="${CHAT_UI:-github:logos-co/logos-chat-ui?ref=feat/logos-testnetv02-mix}"
