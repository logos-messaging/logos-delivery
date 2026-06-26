# E2E: logos-chat-ui over the live testnet-0.2 mix fleet

Run `logos-chat-ui` clients against the **deployed testnet-0.2 mix fleet** (5 remote
mix nodes) instead of the local sim. The client **discovers** the fleet's mix nodes
(and their curve25519 pubkeys) via libp2p Kademlia service discovery — no node
addresses or pubkeys are hardcoded.

This is the fleet counterpart of [README.md](README.md) (the local 5-node sim). Key
differences:

- No local mix nodes to build or run — you dial the live fleet.
- Credentials come from a **secret bundle** provided by the fleet operator (not
  `build_setup.sh`).
- The client picks its RLN membership from an **in-app startup popup** (demo user
  1–10), and its libp2p peer-ID is **decoupled** from that membership.

---

## 0. Prerequisites

- **Nix** with flakes enabled — the whole client chain is pulled from GitHub via
  `nix run`; nothing to clone or build by hand.
- Network access to the fleet (`*.ih-eu-mda1.misc.vaclab.status.im`).
- macOS or Linux.

## 1. Get the credentials bundle 🔒

The fleet uses **static RLN membership**. Obtain the credentials bundle from the
fleet operator — a tarball containing:

- `users/user1..user10/` — 10 demo-user RLN keystores,
- `rln_tree.db` — the shared 15-member tree (5 fleet nodes + 10 demo users),
- `fleet_bootstrap.txt` — the 5 fleet bootstrap multiaddrs.

> ⚠️ **The bundle is secret — never commit it.** It holds per-user RLN keystores and
> the shared tree, which together expose the fleet's entire RLN identity. Keep it
> outside any git repo.

Extract it somewhere local:

```bash
mkdir -p ~/fleet-creds && tar -xzf chat-app-credentials.tar.gz -C ~/fleet-creds
export CHAT_CREDS_DIR=~/fleet-creds/chat-app-credentials
```

## 2. Run a client

```bash
export CHAT_CREDS_DIR=~/fleet-creds/chat-app-credentials   # from step 1
export CHAT_CLUSTER_ID=2
export CHAT_SHARD_ID=0
export CHAT_MIN_MIX_POOL=4
export CHAT_MIX_REQUIRED=1
export CHAT_PORT=0                                          # 0 = random (use distinct ports per client)
# Receive path: filter-subscribe to one fleet node (any line from the bundle).
export CHAT_STATIC_PEER="$(grep -m1 '^/dns4' "$CHAT_CREDS_DIR/fleet_bootstrap.txt")"

nix run 'github:logos-co/logos-chat-ui?ref=feat/logos-testnetv02-mix' --accept-flake-config
```

The first run builds the whole chat chain from GitHub (slow once, cached after). The
flake locks already pin the matching `logos-chat-module` / `logos-chat` revs — no
overrides needed.

## 3. Pick a membership in the startup popup

On launch a popup asks which **demo user (1–10)** to use. Each maps to one RLN
membership in the shared tree. Pick one and hit **Start**:

- The app stages that user's keystore + the shared tree into its run dir, then
  mounts the mix protocol.
- It **discovers** the 5 fleet mix nodes via kad (seeded from `fleet_bootstrap.txt`)
  — watch the bottom status bar fill to **`MIX 4/4`** (`mixReady`).
- The node comes up immediately ("Connected"); mix discovery fills the pool in the
  background — the send button enables once the pool reaches the minimum.

**Multiple testers / clients:** each picks a demo-user index. The peer-ID is
**decoupled** from the membership (random nodekey per run), so two clients can pick
the *same* index without a peer-ID collision. Use distinct `CHAT_PORT`s.

## 4. Exchange messages

1. In **Client A**: **My Bundle** → copy the intro bundle.
2. In **Client B**: **+ new** → paste A's bundle + a first message → create.
3. Send each way — messages route A↔B through the fleet mixnet.

> ⚠️ **Known limitation (2026-06): 2-way messaging over the fleet is not delivering
> yet.** Sends enter the mix but no SURB reply returns (the recipient receives
> nothing). The client side is verified correct — discovery, RLN proof, and
> credential handling all check out, and the client uses the bundle's `rln_tree.db`
> which matches the tree deployed on the fleet. The issue is under investigation on
> the **fleet routing** side. **Discovery + startup are fully testable today;
> message delivery is not.**

## Config reference

| env | meaning |
|-----|---------|
| `CHAT_CREDS_DIR` | path to the extracted secret bundle (keystores + `rln_tree.db` + `fleet_bootstrap.txt`) |
| `CHAT_STATIC_PEER` | a fleet node multiaddr to filter-subscribe to (receive path) |
| `CHAT_CLUSTER_ID` / `CHAT_SHARD_ID` | `2` / `0` (must match the fleet) |
| `CHAT_MIN_MIX_POOL` | min mix peers before send is allowed (default `4`) |
| `CHAT_MIX_REQUIRED` | `1` = force Required (mix-only) mode |
| `CHAT_PORT` | libp2p port (`0` = random; use distinct ports per client) |

The demo-user index, fleet bootstrap list (`CHAT_KAD_BOOTSTRAP`), and the RLN
keystore are all derived from the bundle + the popup selection at startup — you don't
set them by hand.

## How it differs from the sim runbook

| | local sim ([README.md](README.md)) | live fleet (this doc) |
|--|--|--|
| mix nodes | 5 local — you build + run them | 5 remote — already deployed |
| node addresses / pubkeys | hardcoded in `CHAT_MIX_NODES` | **discovered via kad** (`fleet_bootstrap.txt`) |
| credentials | generated by `build_setup.sh` | **secret bundle** from the fleet operator |
| membership selection | fixed `CHAT_NODEKEY` | **in-app popup** (demo user 1–10), peer-ID decoupled |
