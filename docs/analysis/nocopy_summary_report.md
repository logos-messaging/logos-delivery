# λ Async Copy Elimination in the Message Path — Summary Report

Deep-copy and hash-recomputation analysis of Logos Messaging under chronos / refc, and the
measured result of removing them.

> **Logos Messaging (Nim) · logos-delivery · 2026-07-15**
> Nim 2.2.4 · `--mm:refc` · chronos 4.2.2 · Apple M4
>
> Branch train: `master` → `experimental/chore-nocopy-e2e-perf-harness` (2a4da679)
> → `experimental/chore-nocopy-wakumessage-refobj` (3d98a28d)
> → `experimental/chore-nocopy-wakuenvelop` (a6f1065a · be6bfed6)
>
> HTML version: [`nocopy_summary_report.html`](nocopy_summary_report.html)

---

## 01 — Hypothesis & Static Analysis

**Hypothesis.** Under `--mm:refc`, chronos async gates and Result/Option idioms force deep copies
of every `seq`-carrying value they touch. A single inbound relayed `WakuMessage` (three heap seqs +
a string) was predicted to cost on the order of **19 + F full-payload copies** (F = filter peers)
and **4–6 SHA-256 passes**, almost all redundant. A secondary memory hypothesis was stated up
front: *no real gain in retained memory is expected (the copies are temporaries), but a slower
heap-allocation elevation pattern on the GC side.* Both were put to measurement.

### Where chronos deep-copies (root mechanics)

| Copy point | Mechanism | refc | ORC |
|---|---|---|---|
| Every `{.async.}` call, per seq/string param | params lambda-lifted into the closure-iterator env (`asyncmacro.nim:445-517`) | deep copy per param | elided (move) |
| `complete(future, val)` | `val: T` not `sink`; `internalValue = val` (`asyncfutures.nim:198-202`); `move()` degrades to copy under refc | 1–2 copies | 1 copy |
| `let x = await f(...)` | `value()` returns `lent T`; the bind to `x` copies | 1 copy | 1 copy |
| Result/Option bind-out (`valueOr`, `?`, `get`) | accessors are `lent`/templates; the `let` bind of a large value copies; `valueOr`/`?` also copy an lvalue Result | 1 copy per bind | usually moved |

### Accumulated per-message budget on the inbound relay path (static count, verified by counters)

| Cost class | Sites | Count / msg |
|---|---|---|
| **Redundant proto decodes** of the same bytes | `waku_relay/protocol.nim` — ordered validator :543 · onRecv observer :271 · onValidated :326 · topicHandler :603 (+ onSend :341 outbound) | 4 (receiver), ≈2 avoidable copies each |
| **Async closure env captures** of the decoded message | `node/subscription_manager.nim` — uniqueTopicHandler :72 + trace/filter/archive/sync/internal/legacyApp handlers :45–82 | 7 deep copies |
| **Hash recomputation** (`computeMessageHash`) | relay :217/:553/:571/:686 · archive :101 · filter :195/:246 · store-sync :78 · node publish :148 | 4–6 SHA-256 passes |
| **Per-peer buffer copy** (filter push) | `waku_filter_v2/protocol.nim:170` — `{.async.}` by-value buffer per subscribed peer | F copies |
| **Total** | vs. theoretical minimum ≈ 3 (decode once · hash once · encode once) | **≈ 19 + F copies, 4–6 hashes** |

Phase 1 instrumentation confirmed the static analysis before any fix: the two-node benchmark
measured 6.0 decodes / 5.0 hashes per message process-wide — the receiver alone decoding the
identical proto bytes 4×. At the 10/50/150 kB payload profile this amplifies a 50 kB message into
≈ 1 MB of heap traffic.

---

## 02 — Three Phases, One Branch Train

Each phase lives on its own local branch, chained for a PR train off `master`. Every phase ends
with the same harness re-run, so each claim is a measured delta, not a projection.

### Phase 01 — Measure first: e2e performance harness

`experimental/chore-nocopy-e2e-perf-harness` · 4 commits → `2a4da679`

- Micro + macro benchmark (`apps/benchmarks/message_path_bench.nim`), deterministic fixed-seed workload.
- `-d:msgPathCounters`: counters inside `WakuMessage.decode` and `computeMessageHash` — zero cost when undefined.
- Baseline committed (`bench_baseline.md`) before touching production code.

> **Gate:** counters must confirm ≥ 4 decodes and 4–6 hashes/msg — **passed** (6.0 / 5.0 aggregate).

### Phase 02 — Copies become pointers: WakuMessage as `ref object`

`experimental/chore-nocopy-wakumessage-refobj` · 5 commits → `3d98a28d`

- Every assignment / async capture / Result bind of a message: 3-seq deep copy → pointer + refcount. No signature changes.
- Structural `==`, explicit `clone()`, immutable-by-convention.
- Aliasing audit of all mutation sites; **5 real fixes** (publish timestamp, `ensureTimestampSet`, 2× RLN proof attach, postgres nil-init). ASAN clean.

> **Gate:** decode/hash counters byte-identical to baseline (no behavior change) — **passed** (2/2 · 6/5 unchanged).

### Phase 03 — Decode once, hash once: WakuEnvelope API break

`experimental/chore-nocopy-wakuenvelop` · 7 commits → `a6f1065a`

- `WakuEnvelope` = (msg · pubsubTopic · hash) as one ref; `WakuRelayHandler` takes the envelope; archive/filter/sync/FFI reuse `envelope.hash`.
- Unused onRecv observer decode deleted; onValidated/onSend decodes gated to DEBUG.
- Filter push buffer shared across peers (no per-peer copy).

> **Gate:** receiver-side ≤ 2 decodes and exactly 1 hash per message — **passed** (2.0 / 1.0).

---

## 03 — Measurement Method

| Scenario | Entry endpoint | Exit endpoint (measured) | What it isolates |
|---|---|---|---|
| **micro** — in-process, no network | raw proto bytes into the relay's registered *ordered validator*, then its *topicHandler* | return of the full dispatch chain (trace → archive insert → store-sync → internal event) | the receiver pipeline, low-noise (0.4–4 % variance) |
| **macro** — end-to-end | `nodeA.publish()` — public node API → gossipsub → loopback TCP | application-level relay handler on node B, firing only after validation, decode, dispatch and archive insert complete | the full pipeline incl. libp2p observers |

Workload: fixed seed 42, payload mix **10 / 50 / 150 kB at 25 / 50 / 25 %**, N = 1000 + 100 warmup,
unique payload prefix + timestamp (no gossipsub dedup). Publisher flow-controlled to a 32-message
window. Decode/hash counters live inside the codec and hash procs themselves — they count reality,
not expectations. Peak heap via `getMaxMem()`; heap series sampled every 50 messages; retained
delta via `getOccupiedMem()` after `GC_fullCollect()`.

Final comparison ran both branch heads back-to-back in one session on the same machine (one
post-refactor pass discarded for a >5 % variance load spike, rerun within bounds). Not covered by
these numbers: RLN validation, filter push to remote peers, REST/FFI boundary, real network latency.

---

## 04 — Measured Gains — Before vs. After

"Before" = pre-Phase-2 head (`2a4da679`: original production code + harness).
"After" = post-Phase-3 head (`a6f1065a`). Same-session A/B.

| | | |
|---|---|---|
| **+86 %** micro throughput (1,223 → 2,274 msg/s) | **+57 %** e2e throughput (225 → 353 msg/s) | **−21 %** peak heap (515 → 408 MB macro) |

### Full comparison

| Metric | Before | After | Δ |
|---|---:|---:|---:|
| micro msg/s | 1,222.8 | 2,273.7 | **+85.9 %** |
| micro p50 / p99 per msg | 630 µs / 1.94 ms | 338 µs / 1.09 ms | −46 % / −44 % |
| micro decodes / hashes per msg | 2.0 / 2.0 | 2.0 / 1.0 | hash −50 % |
| macro msg/s (e2e) | 225.5 | 353.1 | **+56.6 %** |
| macro p50 / p99 inter-arrival | 3.55 ms / 10.7 ms | 2.29 ms / 7.5 ms | −35 % / −30 % |
| macro decodes / hashes per msg (aggregate) | 6.0 / 5.0 | 3.0 / 3.0 | −50 % / −40 % |
| — receiver-side only | 4 dec / 3 hash | **2 dec / 1 hash** | gate met |
| bytes decoded / hashed per 1000 msgs | 390 / 325 MB | 195 / 195 MB | −50 % / −40 % |
| peak heap `getMaxMem` (micro / macro) | 333.6 / 514.9 MB | 263.6 / 408.4 MB | **−21 % both** |
| GC collections (micro / macro) | 7–8 / 10 | 7–8 / 10 | identical |
| retained-mem slope, macro | ≈ 12.6 MB / 100 msg | ≈ 13.2 MB / 100 msg | flat (archive-driven) |

### Memory hypothesis — verdict

**(a) No real retained-memory gain — CONFIRMED.** Retention slope is identical before and after —
it is the archive holding the same 1000 messages. The eliminated copies were temporaries, exactly
as hypothesized.

**(b) Slower heap-elevation pattern — REFUTED; level shift instead.** Slope and collection counts
are unchanged: under refc the transient copies were refcount-freed deterministically and never
accumulated toward collection triggers. The win manifests as a **−21 % peak heap** and a
~65–75 MB lower level throughout the run — the copies cost CPU (memcpy + alloc/free churn) and
peak footprint, not GC-cycle pressure. Quantifying raw churn would require cumulative-allocation
counters or malloc profiling.

---

## Conclusions & Open Items

The message path now performs one decode per trust boundary and one hash per message, carried by
reference through every async gate. Verification at each phase: representative suites green
(~160+ tests), ASAN clean on the dispatch path, counters byte-exact where no change was claimed.

- Per-shard payload byte gauges (`waku_relay_*_msg_bytes_per_shard`) now populate only at DEBUG/TRACE — decide before merge if dashboards need them.
- Archive/filter keep thin `(topic, msg)` compat overloads; removable later.
- Lightpush `validateMessage` double-encode deferred (needs `PushMessageHandler` signature change).
- Under a future ORC build the remaining `complete()`/await-bind copies persist — returning refs from async procs stays best practice.

Sources: `async_copy_analysis.md` · `async_copy_fix_plan.md` · `plan_phase{1,2,3}_*.md` ·
`bench_baseline.md` · `phase2_mutation_audit.md` · `speed_gain_pre2_post3.md` — all committed on
the branch train.

*Logos.co · λ Logos Messaging · Engineering Report · 2026-07-15*
