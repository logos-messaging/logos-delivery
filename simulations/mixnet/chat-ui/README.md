# Testing logos-chat-ui against the local mixnet sim

Run two `logos-chat-ui` clients that exchange end-to-end messages **through the
5-node mix sim** (Sphinx routing + RLN spam protection + exit-node delivery).

The two clients adopt the **two provisioned chat memberships** the sim already
generates (peer-IDs `…1Qx…` and `…RABscN`, the same identities `run_chat_mix*.sh`
use), via `CHAT_NODEKEY`. RLN keystores are peer-ID-derived, so fixing the nodekey
makes the right `rln_keystore_<peerId>.json` resolve.

## Prerequisites

- Nix (the chat-ui builds via `nix run`).
- This sim built + provisioned (run from `simulations/mixnet/`):

```bash
make -C ../../ wakunode2      # build the mix node binary
./build_setup.sh             # generate rln_tree.db + 7 keystores
```

> `build_setup.sh` regenerates `rln_tree.db` + all keystores from
> `setup_credentials.nim`. This sim is configured with **cover traffic disabled**
> and **userMessageLimit = 100** (matches the chat's RLN default).

## 1. Start the 5 mix nodes

Each in its own terminal, bootstrap first:

```bash
./run_mix_node.sh            # bootstrap (tcp/60001)
./run_mix_node1.sh           # tcp/60002
./run_mix_node2.sh           # tcp/60003
./run_mix_node3.sh           # tcp/60004
./run_mix_node4.sh           # tcp/60005
```

Wait for `MixRlnSpamProtection started` + `Node setup complete` on each.

## 2. Start the two chat-ui clients

```bash
cd chat-ui
./run_chat_ui.sh A           # ClientA on tcp/60010
./run_chat_ui.sh B           # ClientB on tcp/60011
```

Each opens a GUI window. The bottom status bar should show **`MIX 5/4`** (mix pool
full) with the send button enabled.

To iterate on a local chat-ui checkout instead of the pushed branch:

```bash
CHAT_UI="$HOME/Code/logos-chat-ui" ./run_chat_ui.sh A
```

## 3. Exchange messages

1. In **ClientA**: click **My Bundle** and copy the intro bundle.
2. In **ClientB**: **+ new** → paste A's bundle + a first message → create.
3. Send messages each way — they route A↔B through the mixnet.

## How the config flows

`run_chat_ui.sh` sets env that `logos-chat-ui` reads into the chat config:

| env | meaning |
|-----|---------|
| `CHAT_MIX_NODES` | the 5 mix nodes (`multiaddr:curve25519pubkey`) — **hardcoded**, the chat does no mix-peer discovery |
| `CHAT_STATIC_PEER` | bootstrap node (relay the chat connects to) |
| `CHAT_CLUSTER_ID` / `CHAT_SHARD_ID` | `2` / `0` (must match the mix nodes) |
| `CHAT_NODEKEY` | adopt a provisioned chat identity so its RLN keystore resolves |
| `CHAT_MIX_REQUIRED` | force Required (mix) mode |

## Notes / limitations

- **Load:** 5 mix nodes at `log-level=TRACE` (the default in `config*.toml`) write
  multi-GB logs and can starve a desktop machine. For real testing prefer fleet
  nodes; locally, lower `log-level` if the UI feels sluggish.
- **Static membership only:** the two chat slots are fixed. Adding more clients
  means adding their peer-IDs to `setup_credentials.nim` + re-running `build_setup.sh`.
- **No mix discovery on the client:** all mix nodes must be in `CHAT_MIX_NODES`.
