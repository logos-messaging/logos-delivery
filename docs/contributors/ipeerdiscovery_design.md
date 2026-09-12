# IPeerDiscovery — pluggable discovery interface (phased design)

Goal: one abstract interface over discv5, internal kad ServiceDiscovery, and a
future external ServiceDiscovery (logos-libp2p-module via FFI glue). Phased so
each step is a reviewable PR.

Guiding decisions (agreed):
- **Wrap, don't refactor**: Phase 1 keeps `WakuDiscoveryV5` and `WakuKademlia`
  intact and wraps them in `IPeerDiscovery` implementations.
- **Dependencies via getter RequestBrokers**: node state the wrappers need
  (ENR, bootstrap nodes, Switch, PeerManager, node key, subscription queue) is
  obtained through request brokers, not constructor injection — decouples
  initialization wiring/order.
- **Node lifecycle events** (new): `Initialized / Starting / Started /
  Stopping / Stopped` — discovery impls listen and self-start/stop, breaking
  the `Waku.start` vs `node.start` ownership split without moving code.
- **PeerManager feeding stays internal** to the wrapped entities (both already
  `addPeer` actively). The interface does **not** route peers; consumers do not
  pull. `PeersDiscovered` is an observability hook (logs, user info, metrics),
  plus the on-demand lookup verbs for existing consumers
  (`ServicePeersRequest`, REST discovery handler).

Lane: plain non-API `BrokerInterface` (in-process, single-thread; `emit` sync,
drops async) — consistent with the poc/structured-api-interface decision.

## Phase 1 — interface + two wrappers (one PR)

### 1.1 Minimal interface

`logos_delivery/waku/discovery/peer_discovery_interface.nim`:

```nim
{.push raises: [].}

import chronos, results
import brokers/[broker_interface, event_broker, request_broker]

type DiscoveredService* = object
  id*: string                 # service id / capability tag
  data*: seq[byte]

type DiscoveredPeer* = object
  peerId*: string             # base58
  addrs*: seq[string]         # multiaddr strings
  enr*: string                # discv5 only; "" otherwise (lossless passthrough)
  seqNo*: uint64
  services*: seq[DiscoveredService]

type DiscoveryBackendInfo* = object
  id*: string                 # "discv5" | "kad" | "kad-ext"
  running*: bool
  keyKinds*: seq[string]      # e.g. @["svc", "shard", "cap", ""]
  boundPorts*: seq[uint16]    # e.g. discv5 UDP port after auto-port; empty if n/a

BrokerInterface(IPeerDiscovery):
  EventBroker:
    # Observability hook — peers already reached the PeerManager internally.
    type PeersDiscovered = object
      origin*: string
      key*: string            # criteria; "" for background/random
      peers*: seq[DiscoveredPeer]

  RequestBroker:
    proc backendInfo(): Future[Result[DiscoveryBackendInfo, string]] {.async.}
  RequestBroker:
    proc startDiscovery(): Future[Result[void, string]] {.async.}
  RequestBroker:
    proc stopDiscovery(): Future[Result[void, string]] {.async.}
  RequestBroker:
    # (WakuKademlia: lookupServicePeers; module: discoLookup)
    proc lookupServicePeers(
      key: string, limit: int
    ): Future[Result[seq[DiscoveredPeer], string]] {.async.}
  RequestBroker:
    # (libp2p: lookupRandom; module: discoRandomLookup)
    proc lookupRandom(): Future[Result[seq[DiscoveredPeer], string]] {.async.}
```

Deferred to later phases (declared in the design, not in the Phase-1 code):
`startAdvertising`/`stopAdvertising`, `registerInterest`/`unregisterInterest`,
`addBootstrapEntries` — Phase 1 keeps advertise/interest sets flowing in via
the existing conf-time paths (`KademliaDiscoveryConf`,
`topicSubscriptionQueue`), so the wrappers don't need runtime verbs yet.

Criteria keys (unchanged from the earlier draft): `svc:<id>`, `shard:<c>/<s>`,
`cap:<x>`, `""` = random. Phase 1 only exercises `svc:` (kad) and `cap:`
(discv5 REST handler, if migrated).

### 1.2 Node-state getter brokers (new)

`logos_delivery/waku/api/node_state_requests.nim` — plain RequestBrokers
(single provider each, wired by `Waku`/factory; ref types are fine on the
in-process lane):

```nim
RequestBroker:
  proc getNodeSwitch(): Future[Result[Switch, string]] {.async.}
RequestBroker:
  proc getNodePeerManager(): Future[Result[PeerManager, string]] {.async.}
RequestBroker:
  proc getNodeEnr(): Future[Result[enr.Record, string]] {.async.}
RequestBroker:
  proc getNodeKey(): Future[Result[crypto.PrivateKey, string]] {.async.}
RequestBroker:
  proc getDynamicBootstrapNodes(): Future[Result[seq[RemotePeerInfo], string]] {.async.}
RequestBroker:
  proc getTopicSubscriptionQueue():
    Future[Result[AsyncEventQueue[SubscriptionEvent], string]] {.async.}
```

Providers installed by the factory when the state becomes available (ENR after
`setupNode`, dynamic bootstrap after DNS retrieval in `Waku.start`). Wrappers
call the getters inside `startDiscovery` — by lifecycle ordering (below) the
state is guaranteed present, and an unset provider yields a clean `err`.

### 1.3 Node lifecycle events (new)

`logos_delivery/waku/api/events/node_lifecycle_events.nim`:

```nim
type NodeLifecycleStage* {.pure.} = enum
  Initialized   # conf resolved, node constructed (end of setupNode)
  Starting      # Waku.start entered (DNS fetch about to run)
  Started       # startNode done, dynamic bootstrap known, protocols mounted
  Stopping      # Waku.stop entered
  Stopped       # everything down

EventBroker:
  type NodeLifecycleEvent* = object
    stage*: NodeLifecycleStage
```

Emit sites: `setupNode` end (`Initialized`), `Waku.start` entry (`Starting`),
after `startNode` + port/ENR updates (`Started`), `Waku.stop` entry
(`Stopping`), end (`Stopped`).

Discovery wrappers subscribe: on `Started` → `startDiscovery()`; on `Stopping`
→ `stopDiscovery()`. This replaces the hardcoded call sites in
`Waku.start` (discv5, waku.nim:429) and `node.start()` (kad,
waku_node.nim:629) — those blocks are deleted; ordering constraints
(discv5-after-DNS) are satisfied because `Started` fires after DNS retrieval.

### 1.4 Wrapper impls

`logos_delivery/waku/discovery/discv5_peer_discovery.nim`:

```nim
type Discv5PeerDiscovery* = ref object of IPeerDiscovery
  inner: WakuDiscoveryV5        # created lazily in startDiscovery
  conf: Discv5Conf

BrokerImplement Discv5PeerDiscovery of IPeerDiscovery:
  method startDiscovery(self): Future[Result[void, string]] {.async.} =
    let enrRec   = ?await getNodeEnr.request()          # getter brokers
    let pm       = ?await getNodePeerManager.request()
    let queue    = ?await getTopicSubscriptionQueue.request()
    let dynBoot  = ?await getDynamicBootstrapNodes.request()
    let key      = ?await getNodeKey.request()
    self.inner = ?await setupAndStartDiscv5(
      enrRec, pm, queue, self.conf, dynBoot, rng, key, listenAddr)
    ok()
  method stopDiscovery(self) = await self.inner.stop(); ok()
  method lookupServicePeers(self, key, limit) =
    # cap:/shard: keys -> predicate over findRandomPeers (REST handler parity)
  method lookupRandom(self) =
    (await self.inner.findRandomPeers()).mapIt(it.toDiscoveredPeer())
```

`logos_delivery/waku/discovery/kad_peer_discovery.nim`: same shape around
`WakuKademlia` (`new` needs Switch + PeerManager via getters + `switch.mount`;
`startDiscovery` = `wakuKademlia.start()`; `lookupServicePeers("svc:" & id)` →
`wakuKademlia.lookupServicePeers(id)`).

`PeersDiscovered` emission:
- kad: `WakuKademlia` already emits the node-level `PeersDiscoveredEvent` —
  nothing to add.
- discv5: `searchLoop` emits the same global `PeersDiscoveredEvent` directly
  after its `addPeer` batch (symmetric with WakuKademlia; no import cycle;
  origin rides `RemotePeerInfo.origin = Discv5`). Only Phase-1 touch to
  existing discovery code, ~3 lines.
- The wrappers bridge the global event onto their instance-scoped
  `PeersDiscovered` facade (filtering by origin), so interface consumers get
  per-backend streams while global listeners keep working unchanged.

Node/factory changes:
- `WakuNode.wakuKademlia` / `Waku.wakuDiscV5` fields replaced by
  `discoveries*: seq[IPeerDiscovery]` (or kept temporarily with the wrapper
  alongside — reviewer's choice; keeping both eases the diff, the fields go in
  Phase 2).
- `ServicePeersRequest` provider (node_factory.nim:187) delegates to the kad
  wrapper's `lookupServicePeers`.
- Existing behavior preserved: PX-server origin filter, REST discovery handler,
  mix conf wiring, PX-loop gating all untouched.

Port reporting (replaces the `waku.nim:444-445` conf write-back): the discv5
wrapper records the bound UDP port after `setupAndStartDiscv5` and reports it
via `backendInfo().boundPorts` — consumers (`node.ports.discv5Udp`, logging)
query it after `Started` instead of the conf being mutated.

Caveats to verify in Phase 1 (compile-time/runtime):
- first `BrokerInterface` use on the branch — validate codegen with a mock-impl
  unit test before the wrappers;
- `Waku.stop` still must tolerate discovery impls that never started;
- getter brokers returning `ref` types: single-thread in-process only —
  agreed decision: this pattern will NOT be extended to the FFI/MT lanes.

## Phase 2 — config-driven instantiation

- Factory derives from conf which impls to construct/attach
  (`discv5Conf.isSome` → `Discv5PeerDiscovery`, `kademliaDiscoveryConf.isSome`
  → `KadPeerDiscovery`); direct fields removed; start/stop fully
  lifecycle-event driven.
- Preset gap fix rides along: route preset `entryNodes` into backends that can
  take them (kad accepts peerId+multiaddr bootstrap; today presets leave both
  discv5 and kad bootstrap-empty — see analysis) via a
  (now-introduced) `addBootstrapEntries` verb.
- Introduce `startAdvertising`/`stopAdvertising`/`registerInterest`/
  `unregisterInterest` verbs; kad maps 1:1
  (`addServiceToAdvertise`/`addServiceToDiscover` etc.); discv5 maps shard/cap
  keys to ENR updates, replacing the `topicSubscriptionQueue` coupling.

## Phase 3 — external ServiceDiscovery skeleton

- `ExternalServiceDiscovery` impl of the same interface: requestId-correlated
  JSON roundtrips out through the library event callback; new FFI entries
  `waku_disco_backend_reply`, `waku_disco_push_peers`,
  `waku_disco_build_own_xpr` (proxy-XPR advertising with the delivery
  identity); backend selection in node conf.
- Glue in logos-delivery-module maps ops onto the module's `disco*` RPCs and
  runs the polling cadence (the module has no discovery push events).
- Reference: per-backend verb mapping and module analysis in the earlier
  sections of this doc's git history / `iservicediscovery_plan.md`.

## Per-backend verb mapping (full target state)

| Verb | discv5 (`WakuDiscoveryV5`) | kad internal (`WakuKademlia`/`ServiceDiscovery`) | kad-ext (module via glue) |
|---|---|---|---|
| `startDiscovery` | `setupAndStartDiscv5` (open UDP + loops) | `WakuKademlia.start` (interest + loops) | roundtrip `discoStart` |
| `stopDiscovery` | `stop()` | `WakuKademlia.stop` | roundtrip `discoStop` |
| `lookupServicePeers(key, n)` | `findRandomPeers(pred(key))` — `cap:`/`shard:` only | `lookupServicePeers(svcId)` | `discoLookup` |
| `lookupRandom()` | `findRandomPeers()` | `protocol.lookupRandom()` | `discoRandomLookup` |
| `startAdvertising` (P2) | ENR update (`updateENRShards`/caps) | `addServiceToAdvertise` → `protocol.startAdvertising` | `discoStartAdvertising(key, data, record)` |
| `stopAdvertising` (P2) | ENR remove | `removeServiceToAdvertise` | `discoStopAdvertising` |
| `registerInterest` (P2) | predicate extend | `addServiceToDiscover` → `registerInterest` | `discoRegisterInterest` |
| `unregisterInterest` (P2) | predicate narrow | `removeServiceToDiscover` | `discoUnregisterInterest` |
| `addBootstrapEntries` (P2) | `updateBootstrapRecords(enrs)` | `protocol.updatePeers(parsed)` | `connectPeer` per entry |
| `PeersDiscovered` | searchLoop hook (P1 edit) | existing `PeersDiscoveredEvent` | `waku_disco_push_peers` (P3) |
