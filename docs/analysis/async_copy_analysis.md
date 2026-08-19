# Async deep-copy analysis — chronos, Option/Opt/Result, WakuMessage path

Environment: Nim 2.2.4, `--mm:refc`, chronos 4.2.2 (`nimbledeps/pkgs2/chronos-4.2.2-*`),
nim-results 0.5.1, nim-libp2p 2.0.0. All findings verified against these sources.

Key refc facts driving everything below:
- Assignment of `string`/`seq`/object-with-seqs = deep copy (`copyString`/`genericSeqAssign`). No `=sink` hooks.
- `system.move()` degrades to *copy + reset* under refc (move semantics require ARC/ORC).
- `lent` returns work under refc (true borrow, no copy at return) — the copy materializes when the borrow is bound to a `let`/`var` or passed by value.

---

## Table 1 — Where chronos generates deep copies

| # | Copy point | Mechanism (evidence) | refc | ORC |
|---|---|---|---|---|
| 1 | **Every `{.async.}` call: each seq/string/object param** | async transform moves body into a closure iterator (`chronos/internal/asyncmacro.nim:445-517`); params are lambda-lifted into the env object → `env.param = param` = `genericSeqAssign` | **1 deep copy per param per call** | move/cursor — free |
| 2 | **`complete(future, val)`** | `val: T` is **not `sink`** (`asyncfutures.nim:198-202`); `future.internalValue = val`. Macro calls `complete(fut, move(result))` (`asyncmacro.nim:160`) but `move` is a copy under refc | **1–2 deep copies per completion** | 1 copy (non-sink param survives ORC) |
| 3 | **Consuming the result: `let x = await f(...)`** | `Future.value()` returns `lent T` (`futures.nim:231-241`) — free at return, but binding the borrow to `x` copies | **1 deep copy per await** | 1 copy (can't move out of a borrow) |
| 4 | Callbacks / `futureContinue` | future passed by ref, callbacks `move`d (`asyncfutures.nim:187`) | none | none |
| 5 | `{.async: (raw: true).}` procs | no closure-iterator transform → no param capture | none | none |

Net: `let x = await f(a, b)` where `a`, `b`, and the result are seq-heavy costs
**~2 copies of each argument-side seq + 2–3 copies of the result** under refc.
Rows 2–3 are chronos API design (non-`sink` complete, `lent` read) and persist under ORC;
row 1 is refc-specific.

libp2p is aware of row 1: `pubsub.nim:415-427` uses `{.async: (raw: true).}` for `handleData`
"without copying data into closure" — but every downstream `TopicHandler` is a normal
`{.async.}` taking `(topic: string, data: seq[byte])` by value, so the copy fires there,
once per registered handler.

---

## Table 2 — Option[T], Opt[T], Result[T, E] (results 0.5.1, `resultsLent=true` on Nim 2.2.4)

| Accessor | Kind / returns | Copies under refc? | Evidence (results.nim) |
|---|---|---|---|
| `ok(x)` / `err(x)` | template, field-construct | copy of `x` into Result (move only if rvalue construction elides) | :451-454, :471-474 |
| `value()`, `get()`, `tryGet()`, `expect()` | `lent T` (or template → lent) | none at return; **deep copy when bound to `let`** | :870-879, :1072, :1078, :952 |
| `value()`/`get()` on `var` Result | `var T` borrow | none | :881-889, :1092 |
| `unsafeGet()`/`unsafeValue()` | template, in-place field access | none in place; copy on bind | :902-905, :1084 |
| `get(otherwise)` | **func returning `T` by value** | **always copies** (plus `otherwise` passed by value) | :1095 |
| `valueOr:` | template: `let s = (self)` then yields field | copies whole Result if `self` is lvalue (rvalue temp is sunk); **value deep-copied on the outer `let` bind** | :1396-1432 |
| `isOkOr:` | template: `let s = (self)` | copies Result (upstream `# TODO avoid copy`) | ~:1355 |
| `?` operator | template: `let v = (self)` | copies Result; value copied on bind | :1533-1544 |
| `std/options some(sink T)` | proc, sink param | move if rvalue, copy if lvalue | options.nim:125 |
| `std/options get()` | `lent T` | none at return; copy on bind | options.nim:191 |
| `std/options get(otherwise)` | proc returning `T` | **always copies** | options.nim:206 |

Rule of thumb: the wrappers themselves are fine; the cost is **one full deep copy each time a
large value is bound out** (`let msg = decode(...).valueOr: ...` = copy), and `valueOr`/`isOkOr`/`?`
additionally copy the whole Result when applied to an lvalue.

---

## WakuMessage path — hop-by-hop copy count

`WakuMessage` ([message.nim:12-29](logos_delivery/waku/waku_core/message/message.nim)) is a plain
object with three heap seqs (`payload`, `meta`, `proof`) plus `contentTopic: string` —
every deep copy touches ~4 heap allocations.

### A. Inbound relay — the same proto bytes are decoded ≥4×

| Hop | Site | Operation | Cost |
|---|---|---|---|
| A1 | [protocol.nim:543](logos_delivery/waku/waku_relay/protocol.nim:543) | `WakuMessage.decode(message.data)` in ordered validator | decode alloc + `valueOr` bind copy |
| A2 | [protocol.nim:271](logos_delivery/waku/waku_relay/protocol.nim:271) | decode again in `onRecv` observer | same |
| A3 | [protocol.nim:326](logos_delivery/waku/waku_relay/protocol.nim:326) | decode again in `onValidated` observer | same |
| A5 | [protocol.nim:603](logos_delivery/waku/waku_relay/protocol.nim:603) | decode again in subscribe topicHandler | same |
| (out) | [protocol.nim:341](logos_delivery/waku/waku_relay/protocol.nim:341) | decode in `onSend` observer (outbound leg) | same |

Each decode = fresh payload/meta/proof seqs (`codec.nim:23`) + `ok()` wrap + `valueOr` bind
≈ **2 avoidable full-message copies per decode site** on top of the one unavoidable materialization.

### B. Node dispatch — 6+ async closure captures of the decoded message

`registerRelayHandler` ([subscription_manager.nim:29](logos_delivery/waku/node/subscription_manager.nim))
builds `uniqueTopicHandler` (:72, `{.async.}`, msg by value → **env capture copy #1**), which
sequentially awaits trace(:45), filter(:51), archive(:57), sync(:63), internal(:69),
legacyApp(:82) handlers — **each a `{.async.}` proc taking `msg: WakuMessage` by value →
6 more env-capture deep copies**, plus `MessageSeenEvent.emit(...msg)` (:70) broker copy.

### C–F. Downstream

| Path | Sites | Copies |
|---|---|---|
| Archive | [archive.nim:98,101](logos_delivery/waku/waku_archive/archive.nim) | async capture + `computeMessageHash` (re-hash) + field copies into SQLite params; **queue_driver retains a full WakuMessage copy** in `SortedSet[Index, WakuMessage]` |
| Filter push | [protocol.nim:243-264,213,216,170](logos_delivery/waku/waku_filter_v2/protocol.nim) | async capture + re-hash ×2 + `MessagePush(wakuMessage: message)` wrap + one encode (good: **not** per-peer) + **per-peer buffer env-capture copy** in `pushToPeer` |
| Lightpush inbound | [protocol.nim:84,67](logos_delivery/waku/waku_lightpush/protocol.nim), callbacks.nim:16-24 | decode + hash + validateMessage re-encodes + re-hashes + relay publish re-encodes |
| Outbound publish | [relay/protocol.nim:674-690](logos_delivery/waku/waku_relay/protocol.nim:674) | explicit `var message = wakuMessage` copy (:680, for timestamp mutation) + encode + hash |
| FFI/JSON boundary | library/json_message_event.nim:72-95, relay_api.nim:115-121 | explicit `copyMem` of payload/meta/proof + base64 encode/decode string copies (inherent to the JSON API) |

### G. computeMessageHash — recomputed 4–6× per message

Call sites for the *same* inbound message: relay `:217`/validator, archive `:101`,
filter `:246` + `:195`, store-sync reconciliation `:78` — plus lightpush/API paths.
The hash itself doesn't copy (params feed `openArray` into sha256), but it's ~4–6 redundant
SHA-256 passes over the full payload per message.

### Copy budget (one inbound relayed message, archive + filter + sync active, F filter peers)

| Category | Full-payload copies |
|---|---|
| Redundant proto decodes (A) | ~8 (4 sites × ~2) |
| Dispatch env captures (B) | 7 |
| Archive + filter + push wrap/encode | ~4 + F (per filter peer) |
| **Total** | **~19 + F**, vs. theoretical minimum ≈ 3 (decode once, hash once, encode once) |

Plus 4–6 redundant SHA-256 passes. For a 1 MB payload that is ~20 MB of allocation +
memcpy + refc GC pressure per message.

---

## Recommendations (prioritized)

**Yes, this is worth fixing** — the relay hot path does ~6× more copying than necessary,
and it's all in per-message code.

1. **P1 — Decode once in WakuRelay** (`waku_relay/protocol.nim`). The validator (A1),
   both observers (A2/A3), and the topicHandler (A5) each decode independently. Decode in
   the ordered validator, cache `(msgId → decoded msg + hash)` in a small TimedCache (the
   gossipsub validator→handler API gives no side channel), or restructure so observers
   receive the already-decoded message. Removes ~6 full copies + 2–3 hash passes per message.
   No public API change.

2. **P2 — Pass a `ref` envelope through internal dispatch.** Introduce e.g.
   `MessageEnvelope = ref object` holding `msg: WakuMessage`, `hash: WakuMessageHash`,
   `pubsubTopic`, created once after validation; change `WakuRelayHandler`,
   `subscription_manager` handlers, `archive.handleMessage`, `filter.handleMessage`, and
   sync ingress to take the ref. Under refc a ref copy is pointer + refcount — kills all
   7 env-capture copies (Table 1 row 1) and all downstream re-hashing (compute once, carry
   it). This is the single highest-leverage internal refactor. (Immutable-by-convention;
   document that handlers must not mutate.)

3. **P3 — Filter `pushToPeer`: share the encoded buffer.** The buffer is already encoded
   once, but the `{.async.}` by-value param copies it per peer
   ([protocol.nim:170,216](logos_delivery/waku/waku_filter_v2/protocol.nim:170)). Pass a
   `ref seq[byte]` (or make `pushToPeer` `{.async: (raw: true).}`).

4. **P4 — Don't return large values from async procs.** Each such return costs 2–3 copies
   (Table 1 rows 2–3) that even ORC won't remove. Return `ref T`, or fill a caller-provided
   buffer. Applies to store query results (`seq[WakuMessage]`) and codec-heavy client calls.

5. **P5 — Result/Option idioms for large T.** Avoid `get(otherwise)` (always copies both
   sides); prefer in-place access (`.value.field`, `var`-borrow `get`) where the value
   isn't stored anyway. Low priority once P2 makes messages refs — Opt/Result over `ref` or
   small types is free.

6. **P6 — Upstream / longer term.**
   - chronos: make `complete()` take `sink T` (removes Table 1 row 2 under ORC; today it
     copies under *every* mm).
   - ORC migration removes row 1 (env captures become moves) — the biggest class of copies —
     but rows 2–3 remain, so P2/P4 stay valuable regardless.
   - The explicit `var message = wakuMessage` copy at publish
     ([protocol.nim:680](logos_delivery/waku/waku_relay/protocol.nim:680)) exists only to
     patch the timestamp — set the timestamp before entering publish and take the param
     immutably.

## Gains and effort estimate

Baseline per inbound relayed message (archive + filter + sync active, F filter peers):
**~19 + F full-payload copies, 4–6 SHA-256 passes.**

| Fix | Copies removed | Hash passes removed | Remaining after fix | Effort (dev-days) | Risk / blast radius |
|---|---|---|---|---|---|
| P1 decode-once in relay | ~6 (3 redundant decode sites × 2) | 2–3 | ~13 + F | 2–3 (incl. tests) | Contained to `waku_relay/protocol.nim`; needs msgId→decoded cache or observer restructure |
| P2 ref envelope through dispatch | ~9 (7 env captures + archive/filter captures) | 1–2 (hash carried) | ~4 + F | 3–5 | Internal API change: `WakuRelayHandler`, subscription_manager, archive, filter, sync + their tests |
| P3 shared filter buffer | F (per-peer buffer capture) | — | ~4 | 0.5 | One proc signature in `waku_filter_v2` |
| P4 no large async returns (store/query hot paths) | 2–3 per large-value await | — | — | 2–3 (hot paths only) | Store/query client APIs |
| P5 Result/Option idioms | marginal once P2 lands | — | — | opportunistic | none |
| P6 chronos `sink complete` / ORC | env-capture class (row 1) | — | — | weeks (upstream cycle) / months (ORC) | out of repo control |

**After P1+P2+P3: ~4 full-payload copies and 1–2 hash passes per message — a ~75–80 %
reduction in per-message memcpy/alloc volume and ~70 % less hashing CPU.** The remaining ~4
are near the floor: proto→WakuMessage materialization, envelope fill, outbound encode, DB row.

Concrete scale for the target payload profile (min 10 kB / avg 50 kB / max 150 kB).
Assumptions: copies 20 → 4 per message (F≈1), hash passes 5 → 1.5; effective alloc+memcpy
throughput under refc ≈ 1–2 GB/s per core (allocation-bound, not memcpy-bound); SHA-256 via
nimcrypto (pure Nim, no SHA-NI) ≈ 300–500 MB/s per core.

Per-message volume:

| Payload | Copied (baseline 20×) | Copied (after 4×) | Hashed (5×) | Hashed (1.5×) | Allocs/msg |
|---|---|---|---|---|---|
| 10 kB | 200 kB | 40 kB | 50 kB | 15 kB | ~60–80 → ~12–16 |
| 50 kB | 1.0 MB | 200 kB | 250 kB | 75 kB | " |
| 150 kB | 3.0 MB | 600 kB | 750 kB | 225 kB | " |

Sustained-rate CPU cost (share of one core spent purely on copy+hash overhead):

| Scenario | Baseline | After P1–P3 |
|---|---|---|
| 50 kB @ 100 msg/s | ~10–18 % | ~3–5 % |
| 50 kB @ 500 msg/s | ~50–90 % (near saturation) | ~13–22 % |
| 150 kB @ 100 msg/s | ~30–55 % | ~8–14 % |
| 10 kB @ 1000 msg/s | ~20–37 % | ~5–9 % |

Single-core throughput ceiling from overhead alone (copy+hash time per message):

| Payload | Baseline ceiling | After P1–P3 | Headroom gain |
|---|---|---|---|
| 10 kB | ~2,700–5,000 msg/s | ~11,000–20,000 msg/s | ~4× |
| 50 kB | ~550–1,000 msg/s | ~2,200–4,000 msg/s | ~4× |
| 150 kB | ~180–330 msg/s | ~740–1,300 msg/s | ~4× |

GC pressure: heap churn equals the copied volume — at 50 kB × 100 msg/s the baseline churns
~100 MB/s through the refc heap (that much garbage accumulates between collection cycles);
after the fixes ~20 MB/s. Fewer, larger GC cycles → visibly lower tail latency. Per-message
transient footprint at 150 kB drops from ~3 MB to ~0.6 MB.

These are arithmetic projections, not measurements — the day-one benchmark harness validates
them (and nimcrypto's actual SHA-256 rate, which sets how much of the win comes from P2's
hash-once).

Suggested order: benchmark harness first (0.5–1 day: fixed-seed message generator through
`uniqueTopicHandler`, measure allocs via `getOccupiedMem`/instrumented `computeMessageHash`
counter) → P3 → P1 → P2 → re-benchmark. Total ≈ **1.5–2 calendar weeks** for P1–P3 including
tests and verification; P4 as follow-up when touching store paths.

### Memory-model note (refc vs ORC)

| Copy class | refc | ORC | Fix |
|---|---|---|---|
| async param → closure env | deep copy | elided (move/cursor) | P2 (ref) now; ORC later |
| `complete(fut, val)` | 1–2 copies (`move` degrades) | 1 copy (non-sink) | P4 / upstream sink |
| `await` result bind | copy | copy (lent borrow) | P4 |
| `valueOr`/`?`/bind-out of Result | copy | usually moved (rvalue) | P5 |
