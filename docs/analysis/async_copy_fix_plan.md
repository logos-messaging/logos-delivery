# Async copy elimination — three-phase implementation plan

Companion to [async_copy_analysis.md](async_copy_analysis.md). Baseline: ~19 + F
full-payload copies and 4–6 SHA-256 passes per inbound relayed message (refc).

Executor-grade plans (self-contained, one per phase):
[Phase 1 — benchmark](plan_phase1_bench.md) ·
[Phase 2 — WakuMessage ref object](plan_phase2_wakumessage_ref.md) ·
[Phase 3 — WakuEnvelope](plan_phase3_wakuenvelope.md)

Measured blast radius (grep, 2026-07-14):

| Pattern | src (logos_delivery + library + apps) | tests |
|---|---|---|
| `WakuMessage` occurrences | ~420 in 88 files | 1,714 in 64 files |
| `WakuMessage(...)` constructions | 27 | 1,324 (**1,174 via `fakeWakuMessage`** in `tests/testlib/wakucore.nim:74`) |
| `message:/msg: WakuMessage` params | 88 | 100 |
| `computeMessageHash(` call sites | 28 | 208 |
| `WakuRelayHandler` references | 19 | 5 |
| structural `==` on messages | 5 | ~107 |

---

## Phase 1 — End-to-end performance harness (before/after proof)

Goal: reproducible numbers on master *before* any change; re-run after each phase.

Deliverables:
1. `tests/benchmarks/bench_message_path.nim` — two scenarios:
   - **micro**: inject N deterministic messages (fixed seed; payload mix 10/50/150 kB)
     directly into the relay topicHandler/`uniqueTopicHandler` with archive + filter
     (F = 1, 5, 20 subscribed peers) + sync mounted; measures the full internal pipeline
     without network noise.
   - **macro**: two in-process nodes over loopback gossipsub, publish → receive, same
     payload mix; captures libp2p-side copies too.
2. Instrumentation counters under `-d:msgPathCounters` in `waku_core`:
   `computeMessageHash` invocations, `WakuMessage.decode` invocations, bytes hashed,
   bytes materialized by decode. (~30–40 LOC, zero cost when not defined.)
3. Metrics emitted per run (CSV/JSON to stdout): msg/s, ns/msg (p50/p99),
   `getOccupiedMem()` delta, refc `GC_getStatistics()`, counter totals.
4. `make benchmark` target + baseline results committed to `docs/analysis/bench_baseline.md`.

| Item | New LOC | Changed LOC |
|---|---|---|
| bench harness (micro + macro) | ~280–380 | — |
| counters in waku_core | ~30–40 | ~10 |
| Makefile / nimble task | ~15 | — |
| baseline results doc | ~40 | — |
| **Total** | **~370–480** | **~10** |

Verify: harness runs deterministically twice with <5 % variance; counters match the
analysis predictions (≥4 decodes, 4–6 hashes per message) — this *validates the analysis*
before we change anything.

**Time: 1–1.5 days.**

---

## Phase 2 — `WakuMessage` becomes a `ref object`

Goal: every assignment/capture/bind-out of a message becomes a pointer + RC op instead of
a 3-seq deep copy — no signature changes anywhere.

What actually changes (`logos_delivery/waku/waku_core/message/message.nim`):
- `WakuMessage* = ref object` (construction syntax `WakuMessage(payload: ...)` is
  unchanged, so the 27 src + 1,324 test constructions compile as-is).
- **Structural `==`** proc (~12 LOC) — otherwise ref-identity comparison breaks the ~107
  test assertions.
- `clone*(msg: WakuMessage): WakuMessage` helper (~10 LOC) for deliberate-mutation sites.
- Known aliasing fix: relay publish timestamp patch
  ([waku_relay/protocol.nim:680-682](../../logos_delivery/waku/waku_relay/protocol.nim))
  currently relies on value-copy semantics — must become `clone()` (or set the timestamp
  before entering publish).
- Nil-safety audit: `var msg: WakuMessage` now defaults to `nil`, not an empty object.
  88 src param sites reviewed; expected actual fixes small (decode already does
  `var msg = WakuMessage()`).
- Aliasing audit: any post-construction mutation of a received message (queue_driver
  retention becomes a *shared* ref — that's the intended win, but document
  immutable-by-convention in message.nim).
- Style-guide deviation note: AGENTS.md prescribes `Ref` suffix for ref object types;
  renaming to `WakuMessageRef` would touch ~2,100 occurrences for zero semantic value —
  keep the name, document the deviation at the type.

| Item | New LOC | Changed LOC |
|---|---|---|
| message.nim (ref + `==` + clone + doc comment) | ~35 | ~10 |
| relay publish mutation fix | — | ~10 |
| nil/aliasing audit fixes across src (est.) | — | ~60–120 |
| test fixes (nil defaults, identity assumptions; `==` covers the rest) | — | ~80–200 |
| **Total** | **~35** | **~160–340** |

Effect on copy budget (per message, from 19 + F): decode bind-outs −4, dispatch env
captures −7, archive/filter wrap −2 → **~6 + F remaining** (the 4 redundant decode
*materializations* and all hashing remain). Expected from Phase 1 harness: **~50–60 %
reduction in alloc volume**, hashes unchanged.

Memory-model note (refc/ORC): under refc, ref copy = pointer + RC increment (cheap,
non-atomic); no cycles are introduced (WakuMessage has no back-references), so refc's
cycle collector is not engaged. Under a future ORC build, same story with ORC RC. FFI
(`library/`) already deep-copies fields via `copyMem` into JSON events — unaffected;
ref gives a stable pointer, which is FFI-friendly.

Verify: full `make test` green, benchmark re-run recorded, ASAN/refc build of the
message-path tests clean (lifetimes now shared — this is the run that would catch a
premature-free or unexpected-mutation bug).

**Time: 2–3 days** (LOC is small; the cost is the aliasing audit + full-suite verification).

---

## Phase 3 — API break: `WakuEnvelope` (WakuMessage, PubsubTopic, msgHash)

Goal: decode once, hash once, carry both through the whole internal dispatch as one ref.

Design (`logos_delivery/waku/waku_core/message/envelope.nim`, new):
```nim
type WakuEnvelope* = ref object
  msg*: WakuMessage
  pubsubTopic*: PubsubTopic
  hash*: WakuMessageHash

proc init*(T: type WakuEnvelope, pubsubTopic: PubsubTopic, msg: WakuMessage): T =
  WakuEnvelope(msg: msg, pubsubTopic: pubsubTopic,
               hash: computeMessageHash(pubsubTopic, msg))
```

Changes:
1. **Relay decode-once** (`waku_relay/protocol.nim`): ordered validator decodes and builds
   the envelope; `onRecv`/`onValidated`/`onSend` observers and the subscribe topicHandler
   consume the envelope instead of re-decoding (removes 3 decodes + validator-side hash).
   Mechanism: msgId-keyed handoff (small TimedCache) or restructured observer chain.
2. **`WakuRelayHandler`** becomes `proc(envelope: WakuEnvelope): Future[void]` — 19 src +
   5 test references.
3. **Dispatch** (`node/subscription_manager.nim`): `uniqueTopicHandler` + 6 sub-handlers
   (trace/filter/archive/sync/internal/legacyApp) + `MessageSeenEvent` take the envelope.
4. **Consumers**: `archive.handleMessage`, `filter_v2.handleMessage`, sync ingress,
   lightpush→relay callbacks, REST/API + `library/` event emission — use `envelope.hash`,
   deleting ~10–14 of the 28 src `computeMessageHash` call sites.
5. **Filter per-peer buffer share** (folded in here): encode `MessagePush` once, pass
   `ref seq[byte]` (or raw-async `pushToPeer`) — removes the F per-peer buffer copies.

| Item | New LOC | Changed LOC |
|---|---|---|
| envelope.nim + export | ~50 | — |
| relay decode-once + observer restructure | ~60 | ~120–180 |
| WakuRelayHandler + subscription_manager | — | ~90–130 |
| archive / filter / sync / lightpush / events / library | — | ~150–250 |
| filter shared push buffer | — | ~25 |
| tests (relay, node, archive, filter, sync handler tests) | ~40 | ~250–400 |
| **Total** | **~150** | **~640–990** |

Effect on copy budget: **~6 + F → ~3 copies, 4–6 → 1 hash pass** (plus 1 encode + hash on
the outbound leg). Combined with Phase 2 this is the full projected gain: ~75–80 % less
copy volume, ~70–80 % less hashing → ~4× single-core throughput headroom at the
10/50/150 kB profile.

Verify: full suite + benchmark re-run vs Phase-1 baseline and Phase-2 checkpoint; counter
assertion in the micro bench: exactly 1 decode + 1 hash per inbound message.

**Time: 4–6 days.**

---

## Summary

| Phase | New LOC | Changed LOC | Time | Copies (of 19 + F) | Hashes (of 4–6) |
|---|---|---|---|---|---|
| 1 — perf harness | ~370–480 | ~10 | 1–1.5 d | — (measures baseline) | — |
| 2 — WakuMessage ref | ~35 | ~160–340 | 2–3 d | → ~6 + F | 4–6 (unchanged) |
| 3 — WakuEnvelope | ~150 | ~640–990 | 4–6 d | → ~3 | → 1 |
| **Total** | **~555–665** | **~810–1,340** | **7–10.5 d (~2 wks)** | **−84 %** | **−80 %** |

Risks to watch:
- Phase 2 aliasing: any code that mutated its by-value copy now mutates a shared message —
  the relay timestamp patch is the one known site; the ASAN run + full suite is the net.
- Phase 3 relay observer restructure is the only genuinely fiddly part (gossipsub gives no
  validator→handler side channel); the msgId cache must be bounded (TimedCache) and
  eviction-safe.
- Test LOC ranges are dominated by handler-signature churn in Phase 3; the 1,174
  `fakeWakuMessage` call sites are untouched in all phases.
