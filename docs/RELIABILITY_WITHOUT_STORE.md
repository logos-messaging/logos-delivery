# Store-Independent Reliability for the Messaging API — Design Research & Proposal

> **Question.** Make the Store protocol a *startup-only* dependency (used to sync
> history at boot), and after start give the **Messaging API** layer a
> reliable, store-free network. Reliable Channels already get this from SDS — what
> is the equivalent for plain Messaging-API users, and do we need a new protocol?
>
> **Answer (one line).** Replace the two runtime store couplings with **one runtime
> peer-to-peer anti-entropy subsystem** (reuse the existing Range-Based Set
> Reconciliation engine, decoupled from the archive). The same subsystem provides
> *both* receive-side gap recovery *and* send-side delivery confirmation — by
> swapping **"is my message in a store node?"** for **"is my message in N peers'
> reconciliation sets?"**. Store stays only for cold-start history. No store at runtime.

---

## 1. Executive summary / recommendation

Reliability decomposes into two independent guarantees, and **today both are
store-backed**:

| Guarantee | Today (store-backed) | Proposed (store-free, runtime) |
|---|---|---|
| **Send-side confirmation** — "my message got out / is durable" | `SendService` periodically queries a **store node** for the message hash → `MessageSentEvent` | Message hash observed present in **≥N distinct peers' anti-entropy sets** → `MessageSentEvent` |
| **Receive-side completeness** — "I have everything on my topics" | `RecvService` queries a **store node** on reconnect to backfill the offline gap | **Runtime RBSR anti-entropy** with mesh peers over a rolling window + gossipsub IHAVE/IWANT for the live path |

The decisive insight from the research: **SDS cannot simply be "lifted" from the
channel layer to the messaging layer**, because SDS's reliability is a property of a
*bounded set of participants exchanging bidirectional traffic* (its acknowledgement is
"my message was observed as a causal dependency of a peer's later message"). The plain
Messaging API is open, sessionless, unbounded pub/sub — a pure publisher with no
responders gets **no implicit acks ever**. So we need a different primitive.

That primitive already exists in the codebase: the **store-sync Range-Based Set
Reconciliation (RBSR)** engine (`waku_store_sync/`). It is libp2p-native, peer-symmetric
(not client/server), and its reconciliation math runs over a pure in-memory hash set —
its *only* coupling to "store" is that it currently seeds from / writes to the local
archive. Decouple it from the archive, run it on a rolling window of recently-seen
messages, and it becomes a **general runtime anti-entropy service** that answers both
reliability questions without any store node.

**Recommendation:** introduce a **Network Reliability Service (NRS)** — runtime,
store-independent, RBSR-based — mounted on reliability-seeking nodes. Keep the store
protocol mounted **only** for (a) startup `StoreResume` (already cleanly startup-only)
and (b) an optional fallback "retrieval-hint" hash query. Phase it in behind the
existing `useP2PReliability` flag.

This is also **exactly the direction Waku itself has committed to**: *"No store in the
Messaging API; store functions reduced to hash queries that support SDS retrieval hints
and nothing more."* (sources in §9).

---

## 2. Goal & constraints (restated)

- **G1.** Store protocol used **only at startup** to catch up history; no runtime store loop.
- **G2.** After start, the network must be reliable on its own (peer-to-peer / e2e).
- **G3.** Reliable Channels keep SDS (unchanged). The gap to close is the **Messaging API** layer (`logos_delivery/messaging/**`) used by non-channel callers.
- **C1.** Must keep emitting the existing broker events the upper layers depend on — especially `MessageSentEvent` (the Reliable Channel layer correlates per-segment on it by `RequestId`) and `MessageReceivedEvent`.
- **C2.** Must work for both full/relay nodes and light nodes (different capabilities).
- **C3.** Must not open a spam/replay hole (RLN must still gate recovered messages).

---

## 3. Current state — how reliability works today

### 3.1 The only two runtime store couplings to remove

From the exhaustive dependency inventory, **only two** usages are runtime-reliability
(everything else is startup, server-side, or REST/FFI/debug surface):

1. **Send-side validation** — `SendService.checkMsgsInStore`
   (`logos_delivery/messaging/delivery_service/send_service/send_service.nim:132-182`).
   Every ~3 s it runs `wakuStoreClient.queryToAny(StoreQueryRequest(includeData:false,
   messageHashes:…))` for propagated-but-unvalidated hashes. Presence flips the task to
   `SuccessfullyValidated`, which is the **only** producer of `MessageSentEvent`
   (`:196-200`). Remove it with nothing in its place ⇒ `MessageSentEvent` is *never*
   emitted; callers get only `MessagePropagatedEvent` (reached a neighbor), and the
   Reliable Channel layer never sees segment confirmations.

2. **Receive-side backfill** — `RecvService.checkStore`
   (`recv_service.nim:106-170`). On an offline→online edge
   (`onConnectionStatusChange`, `:155-170`), it queries a store node over the offline
   gap window, diffs against `recentReceivedMsgs`, fetches missing bodies
   (`getMissingMsgsFromStore`, `:57-77`), and replays them as `MessageReceivedEvent`.
   Remove it with nothing in its place ⇒ messages missed while offline are lost unless
   SDS (channel layer) happens to detect the gap.

### 3.2 What is already store-independent

- **Live receive path** is already store-free: relay's per-message fan-out
  (`node/subscription_manager.nim:57-78`) emits `MessageSeenEvent`, which `RecvService`
  turns into `MessageReceivedEvent` with hash-dedup over a 7-min window. Gossipsub
  itself self-heals short-horizon gaps via IHAVE/IWANT (≈6 s history, 2-min seen-TTL).
- **Send path** (relay publish + lightpush fallback + retry loop) is store-free; only
  the *confirmation* step is store-backed.

### 3.3 What is already cleanly startup-only (keep as-is)

- **`StoreResume`** (`waku_store/resume.nim`) runs **once** at boot (3 retries), queries
  `max(lastOnline, now−6h) → now`, writes results into the local archive, and its only
  ongoing task just persists a "last online" timestamp. This is already the model we
  want to generalize — it is *not* a runtime reliability loop.

### 3.4 Why gossipsub alone isn't enough

`WakuRelay` is a thin `GossipSub` subclass and exposes **no** extended gap-recovery API.
Native gossipsub gives eager push + IHAVE/IWANT lazy pull, but the recovery window is
only ~6 s (`historyLength`) / 2 min (`seenTTL`); a node offline or partitioned longer
**misses the message entirely**, and light nodes (not in the mesh) get no lazy-pull at
all. Gossipsub is a best-effort *substrate*, not a guarantee.

---

## 4. The core problem decomposition

Two orthogonal questions, and **no single mechanism answers both store-free unless we
reframe them onto the same primitive**:

- **Receive-side:** "Do I have all messages published on my subscribed content topics?"
  This is a **set-completeness** question → solved by anti-entropy (reconcile my set with
  peers' sets, pull the difference).
- **Send-side:** "Did my message reach / become durable in the network?" In open
  broadcast there is *no recipient set*, so "delivered to whom?" is undefined. But we can
  answer a well-defined proxy: **"is my message now present in the reconciliation sets of
  N independent peers?"** — i.e. it propagated and is being retained/served by the mesh.
  This is the *same* set-presence signal store-validation uses today, just sourced from
  **peers instead of a store server**.

**This is the unifying idea of the proposal: send-side confirmation and receive-side
recovery are the same anti-entropy protocol observed from two directions.** One
subsystem, two guarantees.

### Why not just generalize SDS? (the rejected obvious answer)

SDS needs three things the Messaging API doesn't have: a **channel/session id**, a
**participant set**, and **bidirectional traffic** so messages get acked by appearing in
others' causal history. It also imposes **Lamport causal ordering** the Messaging API
explicitly doesn't want. Applied to an open content topic with possibly zero responders,
every message would retransmit its max attempts and be reported unacked. SDS is the right
tool for *channels* (bounded, bidirectional) and the wrong tool for *broadcast*. (Full
options matrix in §8.)

---

## 5. Proposed architecture — the Network Reliability Service (NRS)

```
   Messaging API caller
        │ send(envelope)                              ▲ MessageReceivedEvent
        ▼                                             │ MessageSentEvent
  ┌───────────────────────────────────────────────────────────────┐
  │  MessagingClient  (SendService / RecvService)                 │
  │   • publish: relay (primary) → lightpush (fallback)           │  ← unchanged
  │   • live receive: MessageSeenEvent → dedup → emit             │  ← unchanged
  │   • confirmation & recovery: delegate to NRS  ◄── NEW SEAM    │
  └───────────────┬───────────────────────────────────────────────┘
                  │ register hash / observe presence / pull gaps
                  ▼
  ┌───────────────────────────────────────────────────────────────┐
  │  Network Reliability Service (NRS)   = runtime RBSR anti-entropy│
  │   • in-memory SeqStorage per subscribed content topic          │
  │     (rolling window, fed by MessageSeenEvent — NOT the archive) │
  │   • reconciliation/1.0.0  +  transfer/1.0.0  with mesh peers    │
  │   • emits: "hash present in ≥N peers" + "here are missed msgs"  │
  └───────────────┬───────────────────────────────────────────────┘
                  │ libp2p
                  ▼
            WakuRelay (gossipsub eager push + IHAVE/IWANT lazy pull)
                  │
  ── store protocol: mounted ONLY for StoreResume (boot) + optional hint query ──
```

### 5.1 Receive-side completeness (replaces `RecvService.checkStore`)

- **Live path (unchanged):** gossipsub eager push → `MessageSeenEvent` → dedup →
  `MessageReceivedEvent`; gossipsub IHAVE/IWANT heals sub-10s gaps for mesh members.
- **Recovery path (new, store-free):** the NRS maintains an in-memory `SeqStorage`
  (`{timestamp, msgHash}` set) **per subscribed content topic**, fed by the same
  `MessageSeenEvent` stream over a rolling window (reuse the existing 7-min
  `MaxMessageLife`, tunable). On a timer (and opportunistically on reconnect) it runs the
  existing **reconciliation** protocol with a few mesh peers; any hashes a peer has that
  we don't are pulled via the **transfer** protocol and **replayed through
  `processIncomingMessage`** so they surface as ordinary `MessageReceivedEvent`s. This is
  a drop-in functional replacement for `checkStore`, with no store node involved.

### 5.2 Send-side confirmation (replaces `SendService.checkMsgsInStore`)

- On `send`, register the message hash with the NRS as "awaiting confirmation."
- The NRS already learns, through reconciliation fingerprints, **which of our hashes are
  present in which peers' sets**. When a hash is observed in **≥N distinct peers'**
  reconciliation sets (N configurable, e.g. 2–3), mark the `DeliveryTask`
  `SuccessfullyValidated` → emit **`MessageSentEvent`** (preserving constraint **C1**).
- Until then, the existing `serviceLoop` keeps the task `NextRoundRetry` and
  **periodically re-broadcasts** (ephemeral) — this machinery already exists
  (`send_service.nim:265-280`); we simply use *peer-set presence* instead of *store
  presence* as the stop condition, with the same `MaxTimeInCache` timeout →
  `MessageErrorEvent` on no confirmation.

**Net effect:** `MessageSentEvent` is now produced by peer-set presence, not a store
query — same contract, no store. The Reliable Channel layer keeps working unchanged
because it only cares about the event keyed by `RequestId`.

### 5.3 Store: startup-only

- Keep `StoreResume` at boot for history older than the NRS rolling window (cold start,
  long offline). Optionally trigger one bounded resume-style query on a *long* offline
  reconnect (gap ≫ window) — startup-style, not a loop.
- Optionally keep store **hash queries** as a *fallback hint resolver* (matches Waku's
  "retrieval hints" direction): if the NRS knows a hash exists (from a peer fingerprint)
  but no peer will transfer the body, fall back to a one-shot store fetch. This keeps the
  store *client* available but off the steady-state path.
- A node that wants to *serve* others still mounts the store server + archive + store-sync
  as today — that's orthogonal server-side capability, not this node's own reliability.

---

## 6. Light-node handling (constraint C2)

Light nodes don't join the gossipsub mesh, so they have neither eager push nor IHAVE/IWANT
nor a peer mesh to reconcile against. Options, in preference order:

1. **NRS against service peers.** A light node runs reconciliation/transfer against one or
   two *service* nodes that advertise the capability (same way it already picks store /
   filter / lightpush service peers via `serviceSlots`). This is bounded (1–2 sessions),
   not a broadcast mesh, and replaces the per-reconnect store query with a per-interval
   reconciliation that *also* yields send-side confirmation.
2. **Send-side via lightpush response.** Lightpush v3 already returns `relayPeerCount`;
   treat "relayed to ≥1 peer" as propagation and let NRS-against-service-peer upgrade it to
   confirmation.
3. **Pragmatic fallback.** For ultra-thin clients, a bounded `StoreResume`-style query on
   reconnect (startup-style, not a loop) is acceptable and still satisfies "no runtime
   store *loop*."

---

## 7. What must change — seams & phased plan

### Prerequisites (must land first)

- **P0 — Close the RLN-on-transfer gap.** `waku_store_sync/transfer.nim:173-174` has
  `#TODO verify msg RLN proof`, and `archive.syncMessageIngress` skips the timestamp
  validator. Before any node ingests messages transferred from arbitrary peers, recovered
  messages **must pass the same RLN + timestamp validation** as relay ingress, or we open a
  spam/replay vector (constraint C3). This is the single most important precondition.

### Phase 1 — Decouple the RBSR engine from the archive
- Make `SyncReconciliation`/`SyncTransfer` constructible with a **pluggable backing set**
  and **pluggable ingress/egress sinks** instead of a hard `wakuArchive`
  (`reconciliation.nim:343-344`, `transfer.nim:117-130,175`). Default backing = the new
  in-memory rolling window; archive remains an option for store-server nodes.
- Add a `mountNetworkReliability` seam **independent of `storeServiceConf`**
  (today it's gated inside the store-service block, `node_factory.nim:220-230`).
- Advertise the `reconciliation`/`transfer` capability in the ENR bitfield (the `Sync`
  capability bit already exists) so peers can discover NRS-capable nodes.

### Phase 2 — Receive-side recovery via NRS
- Feed the NRS `SeqStorage` from `MessageSeenEvent` per subscribed content topic.
- Replace `RecvService.checkStore`/`onConnectionStatusChange` store calls
  (`recv_service.nim:106-170`) with NRS recovery; route transferred messages through
  `processIncomingMessage`. Keep `StoreResume` for boot/long-gap.

### Phase 3 — Send-side confirmation via NRS
- Register sent hashes with the NRS; expose a "hash present in ≥N peers" signal.
- Replace `SendService.checkMsgsInStore` (`send_service.nim:132-182`) with that signal as
  the trigger for `SuccessfullyValidated`/`MessageSentEvent`; keep the existing
  re-broadcast/timeout loop as the pacing/failure mechanism.

### Phase 4 — Make store startup-only by configuration
- Stop mounting the store *client* on the steady-state path; mount it for `StoreResume`
  (and optional hint-fallback) only. `mountStoreClient` is currently unconditional
  (`node_factory.nim:239`) — gate it.
- Light-node policy (§6) wired via service slots.

Each phase is independently shippable behind `useP2PReliability`; the contract
(`MessageSentEvent`/`MessageReceivedEvent` by `RequestId`) never changes, so the Reliable
Channel and FFI layers are untouched.

---

## 8. Alternatives considered (and why)

| Mechanism | Store-free? | Reuses code | New protocol | Main obstacle | Verdict |
|---|---|---|---|---|---|
| **RBSR runtime anti-entropy (NRS)** | Yes | High (whole `waku_store_sync`) | No (re-mount/decouple) | RLN-on-transfer; per-peer cost; recovers a *set* | **Chosen** — covers receive *and* (via peer-presence) send |
| Generalize SDS to per-topic/per-pair | Yes | High (`SdsHandler` generic) | meta marker | Needs bounded bidirectional participants; forces causal order | Rejected for broadcast; only the node-pair sub-case (≈ e2e ACK) |
| Lightweight e2e ACK/NACK (MVDS-style) | Yes | Medium (retry loop + RequestId) | Yes (ack codec/topic) | No recipient set in pub/sub; ACK storms; acks need own anti-spam | **Complement** — adopt for *known-recipient / request-response* flows |
| Periodic re-broadcast of unconfirmed | Yes | Very high (`serviceLoop` already retries) | No | No stop condition alone; bandwidth | **Adopted as the send-side pacing**, paired with NRS presence as the stop condition |
| Bloom/IBLT digest gossip | Yes | Low–medium | Yes (full protocol) | Duplicates RBSR; false-positive blind spots | Rejected — RBSR dominates it |
| Gossipsub IHAVE/IWANT only | Yes | n/a (native) | No | ~6 s horizon; nothing for light nodes | **Kept for the live path**, insufficient alone |

The **MVDS** explicit-ACK model (OFFER/REQUEST/MESSAGE/ACK with per-peer state and
exponential-backoff retransmission until ACK) is the textbook store-free reliability
protocol and is worth adopting as the **known-recipient / unicast** complement (e.g.
request/response, direct messages), where a recipient set *is* defined. For open broadcast
it doesn't apply (no one to ACK), which is why NRS is the primary mechanism.

---

## 9. Alignment with Waku's own roadmap (external validation)

This proposal is not a detour from upstream — it is the same destination:

- **"No store in the Messaging API."** Waku's Reliable Channel API work explicitly states:
  *"reducing the store API in Waku API: No store in Messaging API. Store related functions
  on the Waku API need to be sufficient for reliable channel (SDS) and nothing more — so
  exposing store hash queries, to find messages based on retrieval hints."* That is §5.3
  verbatim: store → startup + hint-fallback, reliability → e2e/peer.
- **SDS is a group/participant protocol.** Waku: *"application reliability is handled by
  data sync protocols, enabled by the fact that messages are published in groups with
  active participants."* Confirms SDS can't cover sessionless broadcast (§4).
- **Store-node reliability is itself moving to set reconciliation** (the store-sync /
  FTSTORE / Negentropy line of work), i.e. the same RBSR primitive we propose to reuse at
  runtime.
- **MVDS** remains Waku's reference store-free e2e protocol for the unicast case.

Sources:
- [Waku — Message Reliability and Waku API](https://blog.waku.org/2024-06-20-message-reliability/)
- [Waku — A unified stack for scalable and reliable P2P communication](https://blog.waku.org/explanation-series-a-unified-stack-for-scalable-and-reliable-p2p-communication/)
- [Vac forum — Introducing the Reliable Channel API](https://forum.research.logos.co/t/introducing-the-reliable-channel-api/580)
- [Vac forum — The future of Waku Store](https://forum.vac.dev/t/the-future-of-waku-store/588)
- [SDS protocol RFC (vacp2p/rfc-index)](https://github.com/vacp2p/rfc-index/blob/main/vac/raw/sds.md)
- [MVDS spec (status-im/bigbrother-specs)](https://github.com/status-im/bigbrother-specs/blob/master/data_sync/mvds.md)
- [Waku docs — Reliable Channels](https://docs.waku.org/build/javascript/reliable-channels)

---

## 10. Risks & open questions

1. **RLN on recovered messages (blocking).** Must validate transferred messages exactly
   like relay ingress before any of this is safe (`transfer.nim:173`). Non-negotiable.
2. **Privacy / metadata leak.** Reconciliation reveals which message hashes a node holds.
   Waku flags that a missed-message protocol can leak the social graph. Mitigate by scoping
   reconciliation strictly to content topics the node already subscribes to, and consider
   not reconciling on topics with tiny anonymity sets.
3. **Bandwidth & per-peer cost.** Every reliability-seeking node now runs O(peers)
   reconciliation sessions on a timer. RBSR is efficient for large sets but was sized for
   store servers; tune window size, peer count, and interval; cap on light nodes (§6).
4. **Confirmation semantics.** "Present in ≥N peers' sets" is a *propagation/retention*
   guarantee, not proof a specific human read it — which is the honest ceiling for open
   broadcast. Where the app needs true delivery-to-a-recipient, use the e2e-ACK complement.
5. **Convergence of send-confirmation.** Choose N and the reconciliation cadence so
   `MessageSentEvent` latency is comparable to today's ~3 s store-validation; validate under
   churn.
6. **Light-node anonymity.** NRS-against-service-peers concentrates trust/metadata on a few
   nodes; weigh against the bounded-store-resume fallback.

---

## 11. Bottom line

- **You do not need to invent a brand-new protocol.** The store-sync **RBSR engine already
  in the tree** is the right runtime anti-entropy primitive; it just needs to be unhooked
  from the archive and mounted as a first-class **Network Reliability Service** on regular
  nodes.
- **One subsystem, both guarantees:** receive-side recovery *and* send-side confirmation,
  by replacing **store-presence** with **peer-set-presence**.
- **SDS stays for channels; do not force it onto broadcast** — it structurally can't serve
  a sessionless, possibly-unidirectional Messaging API.
- **Add MVDS-style e2e ACK only for known-recipient / unicast** flows where a recipient set
  exists.
- **Store ends up exactly where you (and Waku) want it:** startup history sync + optional
  retrieval-hint fallback, and nothing on the steady-state path.
- **Hard prerequisite:** fix RLN verification on transferred/recovered messages before
  enabling peer-to-peer recovery.

This is implementable in four incremental phases behind the existing `useP2PReliability`
flag, with no change to the `MessageSentEvent`/`MessageReceivedEvent` contract that the
Reliable Channel and FFI layers depend on.
