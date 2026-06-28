# Logos Delivery — Protocol Stack Architecture Study

> A top-to-bottom study of how the logos-delivery (nwaku/Waku v2 fork) stack works:
> the layered API, the core protocols, how they interconnect, their dependencies,
> the messaging API, the reliable channel API, and the C FFI library.

---

## 0. The big picture

`logos-delivery` is a Nim implementation of a libp2p messaging stack (a rebrand/fork of
nwaku — Waku v2). It is organized as **three stacked API layers** sitting on top of a
**suite of libp2p protocols**, with a **C FFI library** wrapping the whole thing.

```
                 ┌──────────────────────────────────────────────────────┐
   C / mobile    │  library/  (C ABI: liblogosdelivery.{so,dylib,a})    │
   applications  │  - logosdelivery_*  (stable, messaging tier)         │
                 │  - waku_*           (kernel tier, raw protocols)     │
                 └───────────────────────────┬──────────────────────────┘
                                             │  one worker thread + chronos loop
                 ┌───────────────────────────▼──────────────────────────┐
                 │  LogosDelivery  (logos_delivery/logos_delivery.nim)  │
                 │  pure concentrator: wires 3 layers, drives lifecycle │
                 └───────────────────────────┬──────────────────────────┘
        ┌──────────────────────┬─────────────┴───────────────┐
        ▼                      ▼                              ▼
  ReliableChannelManager → MessagingClient ──────────────► Waku (WakuNode)
  (E2E ordered, dedup,    (send/recv with delivery        (relay, lightpush,
   segmentation, repair)   confirmation + offline backfill) filter, store, sync,
                                                            discovery, RLN, mix)
```

The root type `LogosDelivery` (`logos_delivery/logos_delivery.nim`) is a **pure
concentrator**: it owns exactly one instance of each layer and chains them
`Waku ← MessagingClient ← ReliableChannelManager`, each layer driving the one below.
`new` builds bottom-up; `start` runs bottom-up; `stop` runs top-down so higher layers
drain first.

A recurring architectural device is the **broker context** (`brokers/broker_context`):
an in-process event/request bus that lets layers communicate without hard imports.
- `EventBroker` — fire-and-forget pub/sub (`MessageSentEvent`, `MessageReceivedEvent`, `ReadyToSendEvent`, …).
- `RequestBroker` — request/response with a single installable provider (`Encrypt`/`Decrypt`, `RequestRelayShard`, `RequestGenerateRlnProof`, shard/topic health). No provider ⇒ the request errors.

This bus is what keeps the reliable-channel layer fully decoupled from the layers below it,
and what lets RLN proof generation and shard resolution cross module boundaries.

---

## 1. Core data model (`waku/waku_core/`)

Every protocol imports these types. They are the universal vocabulary.

### WakuMessage — the universal envelope
`waku_core/message/message.nim`

| field | wire# | meaning |
|---|---|---|
| `payload: seq[byte]` | 1 | the application bytes (required) |
| `contentTopic: string` | 2 | logical topic (required) |
| `version: uint32` | 3 | legacy encryption discriminator |
| `timestamp: int64` | 10 | sender-set, **nanoseconds** (zigzag-encoded) |
| `meta: seq[byte]` | 11 | opaque marker, ≤ 64 bytes (used to route to the reliable-channel layer) |
| `proof: seq[byte]` | 21 | RLN rate-limit proof (RFC 17), opaque at core layer |
| `ephemeral: bool` | 31 | if true ⇒ never stored/archived |

Max message size: `DefaultMaxWakuMessageSize = 150 KiB`.

### Content topics & sharding
- **Content topic** (`topics/content_topic.nim`): `/<app>/<version>/<name>/<encoding>` (optionally with a leading generation). A string; structured form is `NsContentTopic`.
- **Pubsub topic / shard** (`topics/pubsub_topic.nim`): `RelayShard{clusterId, shardId}` rendered as `/waku/2/rs/<cluster>/<shard>`. Default = `/waku/2/rs/0/0`.
- **Auto-sharding** (`topics/sharding.nim`): a content topic deterministically maps to a shard via `sha256(application & version)` → last 64 bits mod shardCount. This is how a publish that supplies *only* a content topic deduces its pubsub topic.

### Deterministic hashing
`waku_core/message/digest.nim` — `computeMessageHash(pubsubTopic, msg) = SHA256(pubsubTopic ++ payload ++ contentTopic ++ meta ++ BE(timestamp))`. **`version`, `ephemeral`, and `proof` are deliberately excluded**, so the hash is a stable content identity even after an RLN proof is attached. This single 32-byte hash is used everywhere: relay message ID basis, store cursor, archive primary key, store-sync fingerprint, dedup keys.

### Protocol codecs (one place: `waku_core/codecs.nim`)
| Protocol | Codec |
|---|---|
| Relay | `/vac/waku/relay/2.0.0` |
| Lightpush v3 / legacy | `/vac/waku/lightpush/3.0.0` · `/vac/waku/lightpush/2.0.0-beta1` |
| Filter subscribe / push | `/vac/waku/filter-subscribe/2.0.0-beta1` · `/vac/waku/filter-push/2.0.0-beta1` |
| Store query | `/vac/waku/store-query/3.0.0` |
| Store-sync reconciliation / transfer | `/vac/waku/reconciliation/1.0.0` · `/vac/waku/transfer/1.0.0` |
| Metadata | `WakuMetadataCodec` |
| Peer exchange | `/vac/waku/peer-exchange/2.0.0-alpha1` |
| Rendezvous | `/vac/waku/rendezvous/1.0.0` |

---

## 2. The core protocols (`waku/`)

### 2.1 Relay — the gossipsub mesh (the hub)
`waku_relay/protocol.nim` — `WakuRelay = ref object of GossipSub` (subclasses libp2p GossipSub directly, RFC 29 tuning: `d=6, dLow=4, dHigh=8`, flood-publish, peer scoring, bad-peer disconnect).

- **Validators are the key extension point.** `addValidator` appends an app-level validator; `generateOrderedValidator` wraps them into one libp2p validator registered per topic. Any non-`Accept` short-circuits. **RLN is just one such validator.** The same validator list also gates lightpush via `validateMessage`.
- `subscribe` / `publish` / `unsubscribe`; `publish` returns peer count or a `PublishOutcome` error (`NoPeersToPublish`, `DuplicateMessage`, …).
- **Message ID** = `sha256(message.data)` (raw payload, implementation-agnostic).
- Per-topic **health** (UNHEALTHY / MINIMALLY / SUFFICIENTLY based on mesh peer count) is computed on a loop and emitted on the broker.

**Relay is the hub:** when a full node subscribes to a shard, `node/subscription_manager.nim`
installs one handler that fans every received message through, in order:
`trace(metrics) → filter.handleMessage → archive.handleMessage → storeSync.messageIngress → MessageSeenEvent(broker) → legacy app handler`.
That single chain is how relayed traffic reaches filter clients, the store, the sync mirror, and the app.

### 2.2 Lightpush — publish without running relay
`waku_lightpush/` (v3) and `waku_lightpush_legacy/` (v2). A light **client** sends one
`WakuMessage` to a **server** (a relay-running service node), which validates and publishes
it on the mesh.

- v3 wire: `LightpushRequest{requestId, pubSubTopic?, message}` → `LightPushResponse{requestId, statusCode, statusDesc?, relayPeerCount?}` with HTTP-like codes (200, 400, 413, 420, 429, 503, **504 OUT_OF_RLN_PROOF**, **505 NO_PEERS_TO_RELAY**). Auto-sharding can fill in the pubsub topic.
- The **relay bridge** is `callbacks.nim:getRelayPushHandler(relay, rlnPeer)`: attach RLN proof if needed → `relay.validateMessage` → `relay.publish`. So a lightpush request *becomes* a relay publish; the client never joins the mesh.
- Legacy v2 differences: single `PushRPC` envelope, boolean-only `PushResponse`, required pubsub topic, no auto-sharding, errors collapsed to "not published to any peer."

### 2.3 Filter v2 — receive without running relay
`waku_filter_v2/`. A light client registers `(pubsubTopic, contentTopic)` criteria with a
server and receives only matching messages.

- Two codecs: a **subscribe/request** channel (client→server: PING/SUBSCRIBE/UNSUBSCRIBE/UNSUBSCRIBE_ALL) and a **push** channel (server→client `MessagePush`, no response).
- Subscriptions are **soft-state with a 5-minute TTL** kept alive by client PINGs; the server prunes via a 1-minute maintenance loop and dedups pushes with a 2-minute cache.
- The filter *server* only has messages to push because it runs relay and is fed by the `subscription_manager` fan-out (`handleMessage`). The filter module has **no compile-time dependency on relay** — coupling is only at node assembly.

**Node types:** a **full/service node** mounts relay (joins the mesh) and optionally lightpush/filter/store *servers* to serve light clients. A **light node** runs no mesh: it publishes via the lightpush *client* and receives via the filter *client*.

### 2.4 Store / Archive / Store-sync — history & durability
- **Archive** (`waku_archive/`): local persistence behind an `ArchiveDriver` (driver pattern). Backends: **SQLite** (keyset-cursor pagination, schema v10), **Postgres** (partitioned, production/high-volume, `when defined(postgres)`), and an in-memory bounded `SortedSet` queue (25k cap). Ingests via `handleMessage` (computes hash, validates ±20 s timestamp drift, drops ephemeral, `driver.put`). Retention policies: time / capacity / size, on a 30-min loop.
- **Store** (`waku_store/`): the request/response query protocol over the archive. `StoreQueryRequest` carries content-topic/time filters, explicit `messageHashes`, and a **content-addressed cursor** (a `WakuMessageHash`, not an offset) for stable keyset pagination. The server is a thin shell: `requestHandler → archive.findMessages`. The client has `query` (one peer) and `queryToAny` (random peers, retry). `resume.nim` lets a node catch up on reconnect by querying everything since `max(lastOnline, now−6h)`.
- **Store-sync** (`waku_store_sync/`): peer-to-peer **Range-Based Set Reconciliation** (Negentropy-family). Two sub-protocols: **reconciliation** (recursive 8-way range splitting with XOR fingerprints, escalating to explicit item-set exchange below a 100-element threshold) figures out the diff; **transfer** ships the missing messages. Seeds an in-memory `SeqStorage` mirror from the archive; transferred messages re-enter via `syncMessageIngress` (skips the timestamp validator — and inbound transfer messages are **not yet RLN-verified**, a known gap).

### 2.5 Networking, discovery & peers (`waku/net/`, `discovery/`, `waku_enr/`, `waku_metadata/`, `waku_peer_exchange/`, `waku_rendezvous/`)
- **PeerManager** (`node/peer_manager/`): the connectivity engine. Wraps the libp2p `Switch` and an extended **PeerStore** (custom "books": ENR, Shard, Source/origin, Connection, failure/backoff). Distinguishes **relay peers** (managed in bulk to in/out target counts, ~⅔ inbound) from **service peers** (store/filter/lightpush/px, individually pinned in `serviceSlots`). A 30 s **connectivity loop** maintains relay targets — shard- and capability-aware in sharded mode — with exponential backoff (120 s × 4ⁿ), parallel-dial caps, IP-colocation limits, and periodic store pruning + SQLite persistence.
- **Discovery** all funnels into `peerManager.addPeer(peer, origin)`:
  - **discv5** (`waku_discv5.nim`): Ethereum node discovery, filters ENRs by a shard/cluster predicate, `searchLoop` feeds peers.
  - **DNS** (EIP-1459 `enrtree://`): resolves bootstrap ENRs fed into discv5 setup.
  - **Kademlia** (libp2p DHT): specialized here for **Mix**-capable peer/service discovery.
  - **Rendezvous** (libp2p): cluster-scoped `rs/<cluster>/mix` namespace; distributes signed `WakuPeerRecord`s carrying mix pubkeys.
  - **Peer exchange** (RFC 34): light nodes (no discv5) ask full nodes for a reservoir-sampled set of discv5-origin ENRs.
- **ENR** (`waku_enr/`): encodes a `waku2` **capability bitfield** (Relay=0, Store=1, Filter=2, Lightpush=3, **Sync=4, Mix=5** — the last two extend RFC 31), a len-prefixed `multiaddrs` field, and sharding (`rs` indices list < 64 shards, `rsv` 128-byte bit vector ≥ 64).
- **Metadata** (`waku_metadata/`): exchanged immediately on each connection; carries `clusterId` + live shards. **Gating** lives in the peer manager (`refreshPeerMetadata` on peer-join): **cluster mismatch ⇒ immediate disconnect+delete** — this hard-partitions the network by cluster. Shard info only refines selection, it doesn't gate.

### 2.6 RLN — Rate Limiting Nullifier (live anti-spam)
`waku/rln/`. Enforces "N messages per epoch per member" cryptographically (RFC 17) and
**plugs into relay as a gossipsub validator** (`mountRlnRelay` → `relay.addValidator`).

- **Validation** (`rln.nim:validateMessage`): parse `msg.proof` → timestamp within 20 s → epoch matches → Merkle **root in the accepted window (≤ 50 roots)** → **zk-SNARK verify** of the signal (`payload ++ contentTopic ++ BE(timestamp)`) → **double-signal check** against the nullifier log (`Spam ⇒ Reject`).
- **Membership** comes from an on-chain Ethereum contract via web3 (`OnchainGroupManager`): no local Merkle tree; it caches this node's Merkle proof and refreshes accepted roots from `root()`/`getRecentRoots()`. A static/off-chain mode also exists.
- **Rate-limit enforcement is dual**: client-side `NonceManager` (monotonic message-id per epoch, `NonceLimitReached` at the limit) *and* cryptographic — exceeding the limit reuses a slot, producing two Shamir shares on one line under the same nullifier, which (a) flags spam and (b) lets anyone interpolate the offender's identity secret (slashing primitive; on-chain slashing is a TODO).
- Proof **generation** at publish is broker-mediated (`RequestGenerateRlnProof`); the lightpush server attaches a proof if one is missing.

### 2.7 Mix — sender anonymity (opt-in)
`waku/waku_mix/protocol.nim` — `WakuMix = ref object of MixProtocol`, a thin wrapper over
the external `libp2p_mix` **Sphinx mixnet** library. Sending is not a custom publish: the
caller wraps a normal lightpush stream via `wakuMix.toConnection(MixDestination.exitNode(peer), WakuLightPushCodec, MixParameters(...))` — per-hop exponential delay (mean 50) defeats timing
correlation, SURBs enable anonymous replies. The mix pubkey (Curve25519) is advertised via
rendezvous peer records, `WakuInfo`, and Kademlia. Disabled by default; min pool size 4.

### 2.8 Incentivization (PoC, **not wired in**)
`waku/incentivization/` — RFC 73 proof-of-concept: on-chain ETH-transfer txid eligibility
verification (`EligibilityManager`) + a ternary peer reputation table. Present and tested but
**not connected to any live path** (verified by grep).

---

## 3. The node integration hub (`waku/node/` + `waku/factory/`)

- **`WakuNode`** (`node/waku_node.nim`): a `ref object` holding *every* protocol instance
  (relay, archive, store(+client/resume/sync/transfer), filter(+client), rln, lightpush(+legacy+clients),
  peer exchange, metadata, mix, kademlia, rendezvous, libp2p ping, peer manager, switch, broker context,
  subscription manager). Each protocol is attached by a `mount*` proc; `start`/`stop` cascade the lifecycle.
  Publish/subscribe/query APIs live in `node/waku_node/{relay,lightpush,filter,store,…}.nim`.
- **`WakuConf`** (`factory/waku_conf.nim`): one validated config object. Convention:
  **`Option[...]Conf` being `some` enables that protocol.** Assembled by per-concern
  `conf_builder/*` builders.
- **`node_factory.nim`**: `setupNode → builder.build (switch/peerManager/WakuNode.new) →
  setupProtocols (conditional mount*, order matters: metadata → mix → kademlia → store →
  autosharding → **relay** → rendezvous/ping → **RLN (after relay)** → lightpush/filter/px) →
  startNode (connect bootstrap, start peer manager)`.

---

## 4. The messaging API (`logos_delivery/messaging/` + `logos_delivery/api/`)

This layer adds **delivery confirmation** and **offline backfill** on top of raw transport.

- **`MessageEnvelope`** (`api/types.nim`): `{contentTopic, payload, ephemeral, meta}` →
  `toWakuMessage` stamps the timestamp. **`RequestId`** is a correlation handle returned by
  `send`, and it is **shared across all three layers** — that is what lets the channel layer
  correlate its segments with messaging-layer events.
- **`MessagingClient.send`**: auto-subscribes to the content topic (so the node sees its own
  broadcast), mints a `RequestId`, builds a `DeliveryTask`, fires it at the `SendService`, and
  returns the id immediately (fire-and-forget; completion arrives as events).
- **SendService** (reinforced publish): a fallback **processor chain** — `RelaySendProcessor`
  (primary, gossipsub) → `LightpushSendProcessor` (fallback for edge/light nodes) — plus a 1 s
  service loop that retries and, when `useP2PReliability` is on, **validates delivery by querying
  a store node** for the message hash. State→event mapping:
  - `SuccessfullyPropagated` → **`MessagePropagatedEvent`** (reached neighbors)
  - `SuccessfullyValidated` → **`MessageSentEvent`** (confirmed archived in a store node)
  - `FailedToDeliver` → **`MessageErrorEvent`**
- **RecvService**: dedups inbound (by hash), emits **`MessageReceivedEvent`**, and on
  offline→online reconnect **backfills** missed messages from a store node over the offline gap.

---

## 5. The reliable channel API (`logos_delivery/channels/`)

A `ReliableChannel` gives an **end-to-end ordered, de-duplicated, gap-repairing** channel on
top of the messaging client. Spec: *reliable-channel-api*. One channel = one `ChannelId`
(= SDS channel id).

**Egress pipeline:** `segmentation → SDS (reliability) → rate-limit → encryption → dispatch`.
**Ingress pipeline:** the reverse. The manager builds a default `SendHandler` over
`MessagingClient.send`, so callers never wire transport.

### The reliability mechanism (SDS)
The actual state machine is the external **nim-sds** library (`ReliabilityManager`);
`channels/scalable_data_sync/` is the adapter mapping one manager to one channel. The scheme:

- **Outgoing**: each message gets a unique `SdsMessageID = keccak256(participantId ++ wrap-time-ns ++ content)`. `wrapOutgoingMessage` attaches a **Lamport timestamp** (channel clock) and a **causal history** (the last N delivered message IDs, N = `causalHistorySize`, default 2), and registers it in the outgoing buffer awaiting acknowledgement.
- **Acknowledgement** is implicit: a sent message is acked when it is **observed as a causal dependency of some peer's later message**. Unacked messages are **retransmitted** every `acknowledgementTimeoutMs` (default 5 s) up to `maxRetransmissions` (default 5).
- **Incoming**: deserialize, drop foreign channels, dedup against history (bloom/history), then:
  - duplicate ⇒ consumed;
  - **missing causal dependencies ⇒ park** the segment in `pendingContent` (bounded 32) until deps arrive;
  - otherwise ⇒ deliver this message *plus* any parked segments that just became deliverable — **in causal order** (ingress is serialized by a lock).
- **SDS-R repair**: an `onRepairReady` callback rebroadcasts a full SDS envelope (skips the rate-limit queue, always `ephemeral`) to heal gaps for peers.
- **Persistence** (`waku/persistency/sds_persistency.nim`): snapshot model — lamport clock + outgoing/incoming + repair buffers persisted to SQLite; history reconstructed by sorting on `(lamportTimestamp, messageId)` — the same total order SDS uses for delivery. Channel state survives restart.

### Per-message-send bookkeeping
`ReliableChannel.send` segments the payload, SDS-wraps each segment, records a
`ChannelReqState{totalExpectedSegments, awaitingDispatch, inflightMessagingIds, confirmed, failed}`,
and enqueues. On dispatch each segment is encrypted (`Encrypt` request broker), tagged with
`meta = "RELIABLE-CHANNEL-API/1"` (the ingress-routing marker), and sent via the messaging client.
The channel listens for the messaging-layer `MessageSentEvent`/`MessageErrorEvent` (correlated by
the shared `RequestId`) and, when all segments resolve, emits **`ChannelMessageSentEvent`** or
**`ChannelMessageErrorEvent`**. Inbound, it filters by the `meta` marker + content topic, then
`Decrypt → SDS handleIncoming → reassemble → ChannelMessageReceivedEvent`.

> **Component maturity (as of this study):** `segmentation` is currently a skeleton (one segment
> = whole payload; Reed-Solomon parity planned), `rate_limit_manager` is a pass-through (RLN-epoch
> budgeting planned), and `encryption` ships a no-op provider you must opt into. The SDS reliability
> core is real (delegated to nim-sds). Encryption requires installing an `Encrypt`/`Decrypt`
> provider on the broker or the request errors.

---

## 6. The C FFI library (`library/`)

Wraps `LogosDelivery` as a shared/static C library (`liblogosdelivery.{so,dylib,a}`). All FFI
plumbing (threading, request marshalling, callbacks, Nim runtime init) is delegated to the
external **nim-ffi** framework (pinned, not vendored in this checkout).

### Two-tier C API
- **Stable tier** `logosdelivery_*` (`library/logos_delivery_api/`, header `liblogosdelivery.h`):
  `create_node`, `start_node`, `stop_node`, `destroy`, `subscribe`/`unsubscribe`, `send`,
  `set_event_callback`. Calls into the **high-level** messaging client; protocol selection is hidden.
- **Kernel tier** `waku_*` (`library/kernel_api/`, header `liblogosdelivery_kernel.h`, "use at your
  own risk"): ~45 functions reaching **straight into the node's protocols** — relay pub/sub,
  filter, lightpush, store query, peer manager, discovery, ping. Raw `WakuMessage`/pubsub-level access.

Both tiers are `include`d into a single compilation unit and share one `FFIContext`; the split is
header/stability, not a binary boundary. The tiers mirror `LogosDelivery`'s own composition
(kernel→Waku node, stable→MessagingClient, events surface the reliable-channel layer).

### Calling & threading model
- Universal callback: `void (*FFICallBack)(int callerRet, const char *msg, size_t len, void *userData)`; return codes `RET_OK=0 / RET_ERR=1 / RET_MISSING_CALLBACK=2`.
- Universal shape: `fn(void *ctx, FFICallBack cb, void *userData, …args)` returns a synchronous
  dispatch status; the **real result/JSON/error arrives asynchronously via the callback**.
- **One worker thread, one chronos event loop.** `ctx` is an `FFIContext[LogosDelivery]` owning a
  dedicated thread + watchdog + an SPSC request channel + signals. A C call packs args into an
  `FFIThreadRequest`, hands it across the channel, and the worker runs the async body and fires the
  callback **on the worker thread** (so callbacks must be fast, non-blocking, thread-safe). The C
  example bridges back with `volatile` flags + polling.

### Event system
Two callback channels: (1) per-call result callbacks, and (2) a single **event callback**
(`set_event_callback`) fired repeatedly for the node's lifetime. Events are JSON strings. Two
families:
- **Low-level handlers** (wired at node creation): `message`, `relay_topic_health_change`, `connection_change`, `node_health_change`.
- **High-level broker events** (registered in `start_node`): `message_sent`, `message_error`, `message_propagated`, `message_received`, `connection_status_change`.

> Known rough edges flagged during the study: connection status surfaces under two different
> `eventType` strings (`node_health_change` vs `connection_status_change`), and `MESSAGE_EVENTS.md`
> documents only three of the message events.

---

## 7. End-to-end: the life of a message

**Sending (full app stack):**
1. App calls `ReliableChannel.send(channelId, payload)`.
2. Segmentation → SDS wrap (lamport ts + causal history, registered for ack) → rate-limit queue → encrypt → tag `meta="RELIABLE-CHANNEL-API/1"`.
3. `MessagingClient.send` → auto-subscribe + `DeliveryTask` → `SendService` chain: `relay.publish` (RLN proof attached via broker), or lightpush fallback.
4. Relay validators (incl. RLN) accept → gossipsub propagates → `MessagePropagatedEvent`.
5. SendService later queries a store node for the hash → `MessageSentEvent` (confirmed durable).
6. Channel tallies segment confirmations → `ChannelMessageSentEvent`.

**Receiving:**
1. Relay delivers the message; `subscription_manager` fan-out → filter, **archive (persist)**, store-sync mirror, and `MessageSeenEvent`.
2. `RecvService` dedups → `MessageReceivedEvent`.
3. Channel (matching `meta` + content topic) → decrypt → SDS `handleIncoming` (causal ordering, parks gaps, repairs) → reassemble → `ChannelMessageReceivedEvent`.
4. If the node was offline, `RecvService`/store-resume backfills the gap from a store node; SDS-R repairs any causal holes.

**Light node variant:** steps 3–4 of sending use the **lightpush client** instead of joining the
mesh; receiving uses the **filter client** (with PINGs to keep the 5-min subscription alive),
plus store backfill.

---

## 8. Dependency summary

- Everything depends on **`waku_core`** (WakuMessage, topics, sharding, digest, codecs).
- **relay** is the hub; **lightpush** depends on relay (via the push handler) and RLN; **filter**
  is decoupled at compile time and coupled only at node assembly.
- **store / store-sync / store-resume** all depend on **archive**; archive depends only on its
  driver + core.
- **discovery** (discv5/DNS/kademlia/rendezvous/PX) all converge on `peerManager.addPeer`;
  **metadata** gates connections by cluster.
- **RLN** plugs into relay as a validator; reads membership from an on-chain contract.
- **mix** layers under lightpush; advertised via rendezvous/kademlia.
- The **broker context** decouples cross-layer calls (encryption, shard/health resolution, RLN proof gen) and carries the events the upper layers and the FFI subscribe to.
- The three API layers stack `Waku ← MessagingClient ← ReliableChannelManager`; the **FFI** wraps
  all three and runs them on a single dedicated worker thread.

---

## Appendix — where to look

| Concern | Start here |
|---|---|
| Top-level wiring & lifecycle | `logos_delivery/logos_delivery.nim` |
| Messaging API | `logos_delivery/messaging/messaging_client.nim`, `api/types.nim` |
| Send reliability / store validation | `logos_delivery/messaging/delivery_service/` |
| Reliable channels | `logos_delivery/channels/reliable_channel.nim`, `…/reliable_channel_manager.nim` |
| SDS adapter | `logos_delivery/channels/scalable_data_sync/scalable_data_sync.nim` |
| Core data types | `logos_delivery/waku/waku_core/` |
| Node hub & mounting | `logos_delivery/waku/node/waku_node.nim`, `factory/node_factory.nim` |
| Relay | `logos_delivery/waku/waku_relay/protocol.nim` |
| Lightpush / Filter | `logos_delivery/waku/waku_lightpush/`, `waku_filter_v2/` |
| Store / Archive / Sync | `logos_delivery/waku/waku_store/`, `waku_archive/`, `waku_store_sync/` |
| Peers & discovery | `logos_delivery/waku/node/peer_manager/`, `discovery/`, `waku_enr/` |
| RLN anti-spam | `logos_delivery/waku/rln/` |
| Mix privacy | `logos_delivery/waku/waku_mix/protocol.nim` |
| C FFI | `library/` (+ `library/README.md`, `MESSAGE_EVENTS.md`) |
