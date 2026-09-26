# delivery_module e2e tests

End-to-end checks that run the built `delivery_module` + `liblogosdelivery`
inside real `logoscore` daemon containers and drive them over RPC. Per PR: red on
regressions in `delivery_module` / `liblogosdelivery` / the codegen+RPC path.

## Architecture

Two `delivery_module` daemons in a shared docker network, peered **directly** via
`staticnodes` — no bootstrap node. Node A starts first; node B is configured with
A's container-routable multiaddr and dials it; gossipsub/relay handles the rest.

```
docker network "logosdelivery-e2e-<uuid>"  (172.31.0.0/16)
  ┌────────────────────────────┐        ┌────────────────────────────┐
  │ logoscore-a  (node A)       │◀──────▶│ logoscore-b  (node B)       │
  │ relay, cluster 198, shard 0 │ relay  │ staticnodes=[A multiaddr]   │
  └────────────────────────────┘        └────────────────────────────┘
```

This mirrors the proven two-node relay setup in
[`logos-delivery-interop-tests`](https://github.com/logos-messaging/logos-delivery-interop-tests)
(`tests/wrappers_tests/test_send_relay_propagation.py`, scenario S06): relay-only,
single shard, discv5 off. The single-node lifecycle tests use one daemon each.

## What's tested

| Test | Daemons | Asserts |
|---|---|---|
| `test_create_start_and_stop_node` | 1 | `load_module → createNode → start → stop` all succeed over RPC |
| `test_createNode_twice_rejected` | 1 | second `createNode` returns `success=false` |
| `test_query_and_subscribe_methods` | 1 | queries (`getAvailableConfigs`/`getAvailableNodeInfoIDs`/`getNodeInfo`) + `subscribe`/`unsubscribe` round-trip |
| `test_two_nodes_propagation` | 2 | **gate** — sender sees `messagePropagated` for its `requestId` |
| `test_bidirectional_propagation` | 2 | A→B and B→A both propagate |
| `test_two_nodes_message_received` | 2 | receiver sees `messageReceived` (see below) |

We assert `messagePropagated`, not `messageSent`: with relay-only / no store peer,
`messageSent` never fires (interop S06 vs S07).

## Event payload shape (read before extending receive assertions)

`delivery_module`'s public methods are **synchronous** — `client.call(...)` returns
the `StdLogosResult` `{success, value, error}` directly; there are no per-call
result events. Only message delivery is async, via the typed events
`messageReceived` / `messageQueued` / `messagePropagated` / `messageSent` /
`messageError` / `connectionStateChanged`.

The logoscore CLI serializes a typed event as `{"event": <name>, "data": {"arg0":
<1st arg>, "arg1": <2nd arg>, ...}}` — each codegen event arg lands at `argN` by
position (so `messagePropagated.requestId` = `arg0`, `messageReceived.contentTopic`
= `arg1`). `parse_event` / `event_arg` in `libs/helpers.py` read that.

`messageReceived` fires and its `contentTopic` (`arg1`) is asserted. The
`vector<uint8_t>` `payload` arg's serialization is **not yet asserted** — if you
extend the receive checks to the payload, read `messageReceived payload: …` from
the logs and confirm the decoding in `libs/helpers.py` first.

`source` (`arg3`) is `"live"` or `"history"`. A node that has been down and
comes back can replay what it missed as `"history"`, so a test asserting on a
freshly published message should pin `arg3` to `"live"`.

## Prerequisites

- `docker` available on host.
- `LOGOSCORE_IMAGE` env: `logoscore:smoke-portable`, built once from
  `logos-co/logos-logoscore-py/tests/docker_smoke/build_smoke_image.sh`.
- `LOGOS_MODULES_DIR` env: a directory containing `delivery_module/manifest.json`
  (the output of `nix build .#install-portable` → `result/modules`).
- A host-side `logoscore` CLI on `PATH` (the client shells out to it). Build it from
  `logos-co/logos-logoscore-cli` pinned to the same commit as the smoke image.

If any of these is missing, all e2e tests **skip** with a clear reason.

## Running locally without docker

`local_e2e.py` runs the same scenarios against the released `logoscore`
binaries on this host: one daemon for lifecycle and queries, two daemons
peered by static nodes for delivery both ways, and, given an RLN preset
table, a node whose questions must reach `liblogos_rln_module`.

```bash
nix build .#delivery_module-lgx-portable
lgpm --modules-dir ./modules --allow-unsigned install --file result/*.lgx   # plus the RLN bundles for the RLN check
python3 local_e2e.py --modules-dir ./modules [--rln-presets presets.json]
```

## Running locally — Linux

```bash
# 1. Build the module in install-portable layout.
nix build .#install-portable
export LOGOS_MODULES_DIR=$PWD/result/modules

# 2. Build the logoscore smoke image (one-time) + CLI, pinned together.
git clone https://github.com/logos-co/logos-logoscore-py.git /tmp/logoscore-py
cd /tmp/logoscore-py && git checkout aa45db52
bash tests/docker_smoke/build_smoke_image.sh
export LOGOSCORE_IMAGE=logoscore:smoke-portable
cd -
nix build --out-link /tmp/logoscore-cli \
  "github:logos-co/logos-logoscore-cli/5a1cf746e841e8e8a8fd48333cff55bd12c45c52#cli"
export PATH="/tmp/logoscore-cli/bin:$PATH"

# 3. Install deps + run.
cd tests/e2e
pip install -r requirements.txt
pytest -v
```

## Running locally — macOS

Docker-mode on macOS (arm64) needs a Linux remote builder for
`nix build .#install-portable` (the Linux `delivery_module_plugin.so` + bundled
dylibs), which isn't shipped here. Use CI to validate, or a Linux host.

## Configuration schema

Node configs are built by `libs/helpers.make_delivery_config()` and follow the
`createNode` `WakuNodeConf` JSON schema (see `../README.md#node-configuration-createnode`):

| Field | Value here | Why |
|---|---|---|
| `relay` | `true` | gossipsub relay path under test |
| `clusterId` | `198` | isolated test cluster (interop's `DEFAULT_CLUSTER_ID`) |
| `numShardsInNetwork` | `1` | single shard → every content topic maps to shard 0 |
| `discv5Discovery` | `false` | peering is explicit via `staticnodes`, not discovery |
| `staticnodes` | `[A multiaddr]` (node B only) | direct dial of node A |
| `store` / `filter` / `lightpush` | `false` | not exercised here |

> The cluster + shard must match across both nodes (they do — same config builder).
> A peer is reached via `getNodeInfo("MyMultiaddresses")` with the container IP
> substituted in (`helpers.node_multiaddr`), since the advertised address is `0.0.0.0`.

## Troubleshooting

Daemon container logs are saved to `$E2E_LOG_DIR` (default `/tmp`) on teardown, and
uploaded as the `e2e-test-logs` artifact in CI on failure. Set
`LOGOSCORE_PY_FORWARD_OUTPUT=1` to also mirror CLI + daemon output into pytest logs.

## CI

`.github/workflows/ci.yml` has an `e2e-tests` job (`needs: build-and-test`,
ubuntu-latest) that builds `.#install-portable`, builds the smoke image + CLI, runs
`pytest -v`, and uploads logs on failure. `build-and-test` pre-warms the
`install-portable` cachix cache so the e2e job hits it warm.
