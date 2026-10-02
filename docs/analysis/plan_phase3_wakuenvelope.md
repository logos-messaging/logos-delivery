# Phase 3 — `WakuEnvelope` API break: decode once, hash once (executor plan)

> Self-contained implementation plan. Context: [async_copy_analysis.md](async_copy_analysis.md),
> [async_copy_fix_plan.md](async_copy_fix_plan.md). Prerequisites: Phases 1 and 2 merged
> (WakuMessage is a `ref object`; benchmark + counters exist).
>
> **Objective**: introduce `WakuEnvelope` (message + pubsubTopic + msgHash, one ref) as the
> unit that flows through internal dispatch, eliminate redundant proto decodes and
> `computeMessageHash` recomputation, and stop copying the filter push buffer per peer.
> Target, verified by Phase 1 counters: **≤ 2 decodes and 1 hash per inbound relayed
> message** (from ≥ 4 and 4–6), plus 1 encode + 1 hash on the outbound publish leg.
>
> This is a deliberate **internal API break**: `WakuRelayHandler` changes shape, and every
> registered handler follows.

## Constraints

Same as previous phases (refc, nph, gitnexus impact/detect_changes, no push, verify by
running). Run `gitnexus_impact({target: "WakuRelayHandler", direction: "upstream"})` and
report before editing.

## Design decisions (already made — do not re-litigate)

1. **No validator→handler cache.** The gossipsub validator and the topic handler have no
   shared side channel, and keying a handoff cache by a non-cryptographic hash of the raw
   bytes would allow attacker-crafted collisions to substitute messages. We accept **2**
   decodes (validator + topicHandler); the envelope kills the other 2–3 decodes and all
   re-hashing. A keyed cache can be a later optimization with its own security review.
2. **The `onRecv` observer decode is deleted outright** — its decoded message is unused
   (see Step 2).
3. `WakuEnvelope` is a `ref object` and immutable by convention, same as WakuMessage.

## Step 1 — The type

New file `logos_delivery/waku/waku_core/message/envelope.nim` (~50 LOC), exported from
`waku_core`:

```nim
type WakuEnvelope* = ref object
  msg*: WakuMessage
  pubsubTopic*: PubsubTopic
  hash*: WakuMessageHash

proc init*(T: type WakuEnvelope, pubsubTopic: PubsubTopic, msg: WakuMessage): T =
  WakuEnvelope(msg: msg, pubsubTopic: pubsubTopic,
               hash: computeMessageHash(pubsubTopic, msg))
```

Plus `shortLog`/`$` helper for chronicles fields (hash as 0x-hex).

## Step 2 — WakuRelay (`logos_delivery/waku/waku_relay/protocol.nim`)

Current inbound anatomy (line refs at time of writing):
- ordered validator decodes (`generateOrderedValidator`, :536-565, decode at :543,
  hash-on-reject at :553)
- observers (`initRelayObservers`, :255-353): `onRecv` :301 decodes via
  `decodeRpcMessageInfo` (:256) but `updateMetrics` (:283) **never uses the decoded
  message** — only sizes; `onValidated` :324 decodes only to log; `onSend` :339 decodes
  to log + metrics
- topicHandler wrapper (`subscribe`, :596-634, decode at :603) → calls the
  `WakuRelayHandler`
- `publish` (:674-695): timestamp fix (Phase 2 made it `ensureTimestampSet`), encode,
  hash, gossipsub publish

Changes:
1. **`WakuRelayHandler`** (type in this module; 19 src + 5 test references repo-wide)
   becomes `proc(envelope: WakuEnvelope): Future[void] {.gcsafe, raises: [].}` (keep the
   existing pragma set).
2. **topicHandler wrapper** (:600-616): after the (kept) decode, build
   `let envelope = WakuEnvelope.init(pubsubTopic, decMsg)` — the **single hash
   computation** for the inbound path — and call `handler(envelope)`.
3. **Ordered validator** (:536-565): decode stays (validators need the message). The
   reject-path hash (:553) may stay — it only runs on rejected messages.
4. **Observers**:
   - `onRecv` (:301-322): delete the `decodeRpcMessageInfo` call; keep control-message
     handling and byte metrics computed from `msg.data.len + msg.topic.len` directly.
   - `onValidated` (:324-337): decodes only for `logMessageInfo`. Wrap in a compile-time
     or log-level gate (chronicles `logLevel >= some threshold` pattern used elsewhere in
     the repo) so production INFO builds do not pay a decode per message; alternatively
     downgrade to logging msgId + topic only (no decode). Pick whichever keeps current
     log content at DEBUG/TRACE.
   - `onSend` (:339-348): same treatment as onValidated.
5. **`publish`** (:674-695): after encode, `computeMessageHash` stays (outbound leg,
   1 hash) — no structural change beyond what Phase 2 did.
6. `validateMessage` (:567-594, lightpush entry): currently re-encodes just for the size
   check and re-hashes for logging. Add an overload/param taking the already-encoded
   buffer length and an optional precomputed hash so the lightpush path (which has the
   buffer) stops double-encoding. Small, contained.

## Step 3 — Dispatch (`logos_delivery/waku/node/subscription_manager.nim:29-85`)

`registerRelayHandler`: `traceHandler`/`filterHandler`/`archiveHandler`/`syncHandler`/
`internalHandler` (:45-70), `uniqueTopicHandler` (:72-84), and the
`legacyAppHandlers: Table[PubsubTopic, WakuRelayHandler]` all switch to the envelope
signature. Inside, replace `(topic, msg)` argument pairs with `envelope` and use
`envelope.msg.payload.len` etc. `MessageSeenEvent.emit(node.brokerCtx, topic, msg)` (:70):
change the event to carry the envelope (see Step 5).

## Step 4 — Consumers (each loses its own `computeMessageHash`)

28 src `computeMessageHash` call sites exist; ~10–14 die here. For each consumer, change
the entry point signature and use `envelope.hash`:

| Consumer | Entry point | Redundant hash removed |
|---|---|---|
| Archive | `waku_archive/archive.nim:98` `handleMessage` | :101 |
| Filter | `waku_filter_v2/protocol.nim:243` `handleMessage` | :246 and :195 |
| Store-sync | `waku_store_sync/reconciliation.nim` `messageIngress` (called from subscription_manager:67) | :78 |
| Lightpush→relay | `waku_lightpush*/callbacks.nim:16-24` (builds the relay publish) | :24 (hash once when building the envelope/publish result) |
| API/REST relay | `api/relay.nim` (:30) and any REST messaging handler registering a WakuRelayHandler (this branch's messaging REST endpoints) | :30 |
| library/FFI events | `library/json_message_event.nim` (:88) via MessageSeenEvent | :88 |

Keep `computeMessageHash` call sites that hash *other* messages (store queries hashing
stored rows, sync transfer :171, filter rpc :95 on the client side, etc.) — only remove
recomputation of an inbound message's own hash where an envelope is in hand.

## Step 5 — Broker event

`MessageSeenEvent` (`logos_delivery/api/events/kernel_events`): change payload from
`(topic, msg)` to the envelope (or add hash alongside, whichever keeps broker codegen
simplest). Update its listeners — notably the library/JSON event path, which then uses
`envelope.hash` instead of recomputing (:88) — and any messaging-REST event cache on this
branch that listens to MessageSeenEvent.

## Step 6 — Filter per-peer buffer share (`waku_filter_v2/protocol.nim`)

`handleMessage` → `pushToPeers` (:213-216) encodes `MessagePush` **once** (good) but then
`pushToPeer(peerId, buffer)` (:170) is `{.async.}` with a by-value `seq[byte]` — one
buffer deep-copy per subscribed peer. Fix: make `pushToPeer` `{.async: (raw: true).}` or
pass `ref seq[byte]`. One proc + call site, ~25 LOC.

## Step 7 — Tests

- Update every handler construction to the envelope signature (grep `WakuRelayHandler`
  in tests, plus tests calling `handleMessage(topic, msg)` on archive/filter and
  `messageIngress` directly): wrap with `WakuEnvelope.init(topic, msg)`.
- Add `toEnvelope(topic, msg)` convenience to `tests/testlib/wakucore.nim` if it reduces
  churn (thin alias of `WakuEnvelope.init`).
- New unit tests (~40 LOC): envelope init computes the same hash as `computeMessageHash`;
  relay topicHandler delivers an envelope whose hash matches an independently computed one.
- Affected suites to run individually while iterating: `tests/waku_relay`, `tests/node`,
  `tests/waku_archive`, `tests/waku_filter_v2`, `tests/waku_lightpush`,
  `tests/waku_store_sync`, plus the REST/API suites on this branch.

## Step 8 — Verification (mandatory)

1. Full `make test` green.
2. Phase 1 macro benchmark: **counter assertion is the acceptance gate** —
   `decodes_per_msg ≤ 2` and `hashes_per_msg == 1` on the receiving node
   (observer logging gated per Step 2.4; if the gate is log-level-based, run the bench at
   INFO). Micro bench: expect ~75–80 % alloc-volume reduction vs `bench_baseline.md` and
   the throughput gain in the analysis tables (~4× headroom at the 10/50/150 kB profile).
3. Record the after-numbers in `docs/analysis/bench_baseline.md` (append a "Phase 3"
   section with commit hash).
4. `gitnexus_detect_changes()` reviewed — the affected set must be: waku_core (new file),
   waku_relay, node/subscription_manager, waku_archive, waku_filter_v2, waku_lightpush,
   waku_store_sync, api/events + api/relay, library, tests. Anything outside that list is
   scope creep — stop and reassess.
5. Commit (no push).

## Estimated diff

~150 new LOC, ~640–990 changed LOC (tests ~250–400 of that). Budget: 4–6 days. The only
genuinely fiddly part is Step 2 (relay observers + handler wrapper); do it first, get
`tests/waku_relay` green, then fan out to consumers mechanically.
