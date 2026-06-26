# E2E: logos-chat-ui over the local mixnet sim

Run two `logos-chat-ui` clients that exchange end-to-end messages **through the
5-node mix sim** (Sphinx routing + RLN spam protection + exit-node delivery).

This is a full from-scratch runbook: clone → build → provision → run → message.

> Running against the **live testnet-0.2 mix fleet** instead of a local sim?
> See [README-fleet.md](README-fleet.md).

The two clients adopt the **two provisioned chat memberships** the sim generates
(peer-IDs `…1Qx…` and `…RABscN`), via `CHAT_NODEKEY`. RLN keystores are
peer-ID-derived, so fixing the nodekey makes the right `rln_keystore_<peerId>.json`
resolve.

---

## 0. Prerequisites

- **Nix** with flakes enabled (the chat client is built/run via `nix run`).
- **Rust toolchain** (`rustc` + `cargo`, via [rustup](https://rustup.rs)) and the
  standard dev tools (C compiler, GNU Make, Bash, Git) — needed to build the mix
  node (`wakunode2`).
- macOS or Linux.

## 1. Repos & branches

Only **logos-delivery** needs to be cloned. The chat client (and its whole
dependency chain) is pulled automatically by `nix run`.

| repo | branch | role | how it's consumed |
|------|--------|------|-------------------|
| `logos-messaging/logos-delivery` | `feat/logos-testnetv02-mix` | mix sim (5 nodes) + this harness | clone + `make wakunode2` |
| `logos-co/logos-chat-ui` | `feat/logos-testnetv02-mix` | the GUI client | `nix run github:…` (pulls the rest) |
| `logos-co/logos-chat-module` | `feat/logos-testnetv02-mix` | `liblogoschat` module | transitive flake input |
| `logos-messaging/logos-chat` | `feat/logos-testnetv02-mix` | Nim SDK (in-process nwaku) | transitive flake input (`submodules=1`) |

## 2. Build & provision the sim

```bash
git clone --recurse-submodules -b feat/logos-testnetv02-mix \
  https://github.com/logos-messaging/logos-delivery
cd logos-delivery

make wakunode2          # builds Nim + deps + librln + the mix node (first run is long)

cd simulations/mixnet
./build_setup.sh        # generates rln_tree.db + 7 keystores (mix nodes + 2 chat slots)
```

> `build_setup.sh` sources the nwaku `env.sh`, so `nim` and `librln_v2.0.2.a`
> (built by `make wakunode2`) are already in place. The sim is configured with
> **cover traffic disabled** and **userMessageLimit = 100** (matches the chat's RLN
> default) in `config*.toml`.

## 3. Start the 5 mix nodes

Each in its own terminal, **bootstrap (`run_mix_node.sh`) first**:

```bash
cd simulations/mixnet
./run_mix_node.sh       # bootstrap   tcp/60001
./run_mix_node1.sh      #             tcp/60002
./run_mix_node2.sh      #             tcp/60003
./run_mix_node3.sh      #             tcp/60004
./run_mix_node4.sh      #             tcp/60005
```

Wait for `MixRlnSpamProtection started` + `Node setup complete` on each.

## 4. Start the two chat-ui clients

Two more terminals. The first run builds the whole chat chain via nix (slow once,
cached after):

```bash
cd simulations/mixnet/chat-ui
./run_chat_ui.sh A      # ClientA, tcp/60010
./run_chat_ui.sh B      # ClientB, tcp/60011
```

Each opens a GUI. The bottom status bar should show **`MIX 5/4`** (mix pool full)
with the send button enabled.

To iterate on a local chat-ui checkout instead of the pushed branch:

```bash
CHAT_UI="$HOME/Code/logos-chat-ui" ./run_chat_ui.sh A
```

## 5. Exchange messages

1. In **ClientA**: click **My Bundle** and copy the intro bundle.
2. In **ClientB**: **+ new** → paste A's bundle + a first message → create.
3. Send messages each way — they route A↔B **through the mixnet**.

> ⏱️ **Messages arrive in ~1 s.** A mix send takes ~0.8–1.1 s end-to-end: the Sphinx
> forward path reaches the exit hop in ~0.4–0.7 s, plus RLN proof time. (An earlier
> build had a hardcoded 30 s per-send "root convergence" wait — a leftover from
> dynamic on-chain membership — that made delivery take ~a minute; it was removed,
> since static RLN membership has a fixed Merkle root with nothing to converge.)

To confirm a message actually traversed the mix, watch a mix node log for
`onMessage - exit is destination` (the exit hop delivering to the recipient) — its
timestamp lands within ~0.5 s of when the message was sent.

## How the config flows

`run_chat_ui.sh` sources `env.sh` and sets the env `logos-chat-ui` reads into the
chat config:

| env | meaning |
|-----|---------|
| `CHAT_MIX_NODES` | the 5 mix nodes as `multiaddr:curve25519pubkey` — **both the node ID and the mix pubkey are hardcoded**; the chat does no mix-peer discovery |
| `CHAT_STATIC_PEER` | bootstrap node (relay the chat connects to) |
| `CHAT_CLUSTER_ID` / `CHAT_SHARD_ID` | `2` / `0` (must match the mix nodes) |
| `CHAT_NODEKEY` | adopt a provisioned chat identity so its RLN keystore resolves |
| `CHAT_MIX_REQUIRED` | force Required (mix) mode |
| `CHAT_UI` | flake to run (default: the pushed `feat/logos-testnetv02-mix` branch) |

## Notes / limitations

- **TRACE logging is heavy:** 5 mix nodes at `log-level=TRACE` (the default in
  `config*.toml`) write multi-GB logs and burn CPU/disk — a resource concern, not a
  correctness one. For long local runs, lower `log-level` or prefer fleet nodes.
- **Static membership only:** the two chat slots are fixed. More clients means
  adding their peer-IDs to `setup_credentials.nim` + re-running `build_setup.sh`.
- **No mix discovery on the client:** every mix node must be listed in
  `CHAT_MIX_NODES` (multiaddr **and** curve25519 mix pubkey). The mix *nodes*
  discover each other via kad; the chat client does not.
- **Creds are not checked in** — `rln_tree.db` / `rln_keystore_*.json` are binary
  and regenerated by `build_setup.sh`.
