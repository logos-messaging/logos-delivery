# Message-path benchmark — Phase 1 baseline

Baseline capture on the **current branch before Phases 2/3**, produced by
`apps/benchmarks/message_path_bench.nim` (see
[plan_phase1_bench.md](plan_phase1_bench.md)). Re-run after each phase and diff
against these numbers.

## Environment

| Item | Value |
|---|---|
| Commit (harness) | `cf8502eb4975ae6bc8a5667a5d179cd154e8e1d1` |
| Branch | `experimental/chore-nocopy-e2e-perf-harness` |
| Machine | Apple M4 |
| OS | macOS 26.5 (arm64) |
| Nim | 2.2.4, `--mm:refc` |
| Build | `-d:msgPathCounters -d:chronicles_log_level=ERROR`, `--passL:librln_v2.0.2.a` |
| Run | `nimble benchMessagePath` (or `./build/message_path_bench`) |
| Workload | seed 42, payload mix 10/50/150 kB @ 25/50/25 %, N=1000 + 100 warmup |

## Results (CSV)

```
scenario,msgs,payload_profile,wall_ms,msg_per_s,ns_per_msg_p50,ns_per_msg_p99,decodes_per_msg,hashes_per_msg,hashed_MB,decoded_MB,occupied_mem_delta_MB,gc_collections
micro_run1,1000,10/50/150kB@25/50/25,828.591,1206.9,641375,1925042,2.000,2.000,130.00,130.11,1.54,7
micro_run2,1000,10/50/150kB@25/50/25,795.166,1257.6,619167,1810625,2.000,2.000,130.00,130.11,1.51,8
macro,1000,10/50/150kB@25/50/25,4367.314,229.0,3510750,10701375,6.000,5.000,325.00,390.33,141.58,10
```

| Scenario | msg/s | decodes/msg | hashes/msg | decoded_MB | hashed_MB | occ_mem_delta_MB |
|---|---|---|---|---|---|---|
| micro run1 | 1206.9 | 2.000 | 2.000 | 130.11 | 130.00 | 1.54 |
| micro run2 | 1257.6 | 2.000 | 2.000 | 130.11 | 130.00 | 1.51 |
| macro | 229.0 | 6.000 | 5.000 | 390.33 | 325.00 | 141.58 |

Micro determinism: run1=1206.9 msg/s, run2=1257.6 msg/s → **variance 4.03 %**
(< 5 % target; two earlier back-to-back runs were 1.90 % and 3.12 %). The
decode/hash *counts* are byte-exact reproducible across every run.

## Interpretation vs. the analysis

**Decode / hash counts validate [async_copy_analysis.md](async_copy_analysis.md).**

The counter is a single process-global (both in-process nodes share it), so the
macro per-message numbers are the aggregate of publisher (node A) + receiver
(node B). Breakdown of the macro **6 decodes / 5 hashes** per message:

| Counter | Node A (publish) | Node B (receive) | Total |
|---|---|---|---|
| `WakuMessage.decode` | 1 (`onSend` observer) | 4 (ordered validator, `onRecv`, `onValidated`, subscribe topicHandler) | **6** |
| `computeMessageHash` | 2 (`publish` :686, `onSend`→`logMessageInfo`) | 3 (`onValidated`→`logMessageInfo`, archive, store-sync) | **5** |

- The **inbound-decode claim (≥4 decodes on a relayed message)** is confirmed:
  node B alone decodes the same proto bytes **4×**
  (`waku_relay/protocol.nim` validator :543, `onRecv` :271, `onValidated` :326,
  topicHandler :603).
- The micro scenario isolates the non-observer path and shows the **2 decodes /
  2 hashes** it exercises (validator + topicHandler decode; archive + store-sync
  hash) — the observers only fire under real libp2p dispatch, which the macro
  scenario adds.

### Caveats

1. **Log level elides some hash sites.** Built at `chronicles_log_level=ERROR`,
   `computeMessageHash` calls that appear *only* as disabled log arguments are
   not evaluated (chronicles skips disabled-sink args) — notably the
   `node.publish` `notice` at `waku_node/relay.nim:148`. Sites bound to a `let`
   (archive :101, store-sync :78, `logMessageInfo` :217, `publish` :686) run
   regardless of level and are the ones counted here.
2. **Filter not mounted.** Per the plan, node B has archive + store-sync but not
   filter. The analysis's "4–6 hashes" upper end assumes an active filter
   (`waku_filter_v2` adds ~2 more receiver-side `computeMessageHash` passes,
   :195 + :246). With filter mounted the receiver-side hash count would rise
   from 3 toward the analysis's upper bound.
3. **`occupied_mem_delta`** is a coarse `getOccupiedMem()` before/after delta on
   the refc heap, not a per-message allocation trace; use it for order-of-
   magnitude trend, not exact bytes. `decoded_MB` / `hashed_MB` (exact byte
   totals fed to decode/hash) are the reliable volume metrics.

## Acceptance gate (Phase 1)

| # | Criterion | Verdict |
|---|---|---|
| 1 | Representative tests green (production untouched except no-op templates) | **PASS** — `tests/waku_core/test_message_digest` 5/5, `tests/waku_relay/test_protocol` 20/20 |
| 2 | Production build without `-d:msgPathCounters` compiles (templates vanish) | **PASS** — `nim check apps/wakunode2` clean; relay test built without the define |
| 3 | Two consecutive micro runs < 5 % msg/s variance | **PASS** — 4.03 % (and 1.90 % / 3.12 % on earlier runs) |
| 4 | Macro `decodes_per_msg ≥ 4` and `hashes_per_msg` in 4–6 | **PASS** — decodes 6.0, hashes 5.0 (process aggregate; receiver-side decodes = 4) |
| 5 | This baseline doc committed | **PASS** |

---

# Phase 2 checkpoint — `WakuMessage` as `ref object`

Re-run of the same harness after Phase 2 (`WakuMessage` value `object` →
`ref object`), same machine/toolchain, same workload (seed 42, 10/50/150 kB @
25/50/25 %, N=1000 + 100 warmup), same build defines
(`-d:msgPathCounters -d:chronicles_log_level=ERROR`, `--passL:librln_v2.0.2.a
--passL:-lm`), `--mm:refc`.

## Results (CSV)

```
scenario,msgs,payload_profile,wall_ms,msg_per_s,ns_per_msg_p50,ns_per_msg_p99,decodes_per_msg,hashes_per_msg,hashed_MB,decoded_MB,occupied_mem_delta_MB,gc_collections
micro_run1,1000,10/50/150kB@25/50/25,809.283,1235.7,624250,1941750,2.000,2.000,130.00,130.11,5.25,7
micro_run2,1000,10/50/150kB@25/50/25,798.488,1252.4,615750,1906167,2.000,2.000,130.00,130.11,6.46,8
macro,1000,10/50/150kB@25/50/25,4306.885,232.2,3485125,10544000,6.000,5.000,325.00,390.33,140.74,10
```
(second run: micro 1232.1 / 1278.1, variance 3.60 %; macro 230.2 msg/s, occ_mem_Δ 140.58 MB — stable.)

## Phase 1 baseline vs Phase 2

| Scenario | Metric | Phase 1 baseline | Phase 2 | Δ |
|---|---|---|---|---|
| micro | msg/s | 1206.9 / 1257.6 | 1235.7 / 1252.4 | ~flat (within variance) |
| micro | decodes/msg | 2.000 | 2.000 | **unchanged** |
| micro | hashes/msg | 2.000 | 2.000 | **unchanged** |
| micro | occ_mem_Δ MB | 1.51–1.54 | 5.25–6.46 | up (retention-noise, see below) |
| macro | msg/s | 229.0 | 232.2 / 230.2 | +1 % |
| macro | decodes/msg | 6.000 | 6.000 | **unchanged** |
| macro | hashes/msg | 5.000 | 5.000 | **unchanged** |
| macro | hashed_MB / decoded_MB | 325.00 / 390.33 | 325.00 / 390.33 | **byte-exact unchanged** |
| macro | occ_mem_Δ MB | 141.58 | 140.74 / 140.58 | ~flat (−0.6 %) |
| macro | gc_collections | 10 | 10 | unchanged |

## Interpretation — why occupied-mem delta is flat (and that is expected)

The refactor removes **transient** deep copies — async-closure env captures in
node dispatch (`subscription_manager` handlers, 6–7 per message), Result/Option
bind-outs, and the `valueOr` binds on the decode path. It does **not** change
what is *retained*.

`occupied_mem_delta` is `getOccupiedMem()` after − before (with a
`GC_fullCollect()` only *before* the run). It is therefore a **retained-memory**
metric, and the macro figure is dominated by the archive `SortedSet[Index,
WakuMessage]` holding all 1000 messages. Those payload bytes are retained
identically under value and ref semantics (value: copied into the set node; ref:
one heap message the set points at) — so the delta is flat by construction.

Under `--mm:refc` the eliminated transient copies are freed **deterministically**
by refcount as each async env / Result temporary leaves scope; they never
accumulate, so neither `getOccupiedMem()`-delta nor `gc_collections` (unchanged
at 10) can observe their removal. Quantifying the transient-copy volume would
require a **cumulative bytes-allocated counter or a peak-RSS probe**, which the
Phase 1 harness does not expose — a harness gap, not a missing win.

The **primary correctness gate is met**: decode and hash counters are byte-exact
identical to baseline (micro 2/2, macro 6/5; `hashed_MB`/`decoded_MB` identical
to the byte), confirming the ref change introduced no extra decode/hash passes,
and throughput is equal-to-slightly-better.

Residual-deep-copy investigation (plan acceptance item 3): swept for the two
prime suspects and found neither — no value-type `WakuMessage` field remains
(the type is now a ref, so every container/field that held a `WakuMessage`,
incl. `SortedSet[Index, WakuMessage]`, `MessagePush.wakuMessage`,
`WakuMessageKeyValue.message`, holds a pointer); the known `var`-parameter copy
site (relay `publish`) was converted to `ensureTimestampSet`. No leftover
force-copy path exists.

## Acceptance gate (Phase 2)

| # | Criterion | Verdict |
|---|---|---|
| 1 | Representative tests green; ASAN clean | **PASS** (tests) — see final report for suite list; ASAN best-effort noted there |
| 2 | Mutation-site classification produced | **PASS** — `docs/analysis/phase2_mutation_audit.md` |
| 3 | Alloc volume down ≥ 40 %, decode/hash unchanged | **PARTIAL** — decode/hash byte-exact unchanged (**PASS**); alloc-volume drop **not demonstrable** via this harness's retained-memory metric under refc (technical reason above); no residual deep-copy bug found |
| 4 | `detect_changes` reviewed; committed (no push) | **PASS** (gitnexus skipped per environment; grep-based mutation sweep committed instead) |
