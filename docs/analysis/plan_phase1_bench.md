# Phase 1 — Message-path performance benchmark (executor plan)

> Self-contained implementation plan. Context: [async_copy_analysis.md](async_copy_analysis.md)
> and [async_copy_fix_plan.md](async_copy_fix_plan.md). Read both before starting.
>
> **Objective**: a reproducible before/after benchmark of the WakuMessage inbound/outbound
> pipeline, plus decode/hash counters that verify the analysis claims (≥4 decodes and 4–6
> SHA-256 passes per inbound relayed message on the current code). This phase changes **no
> production behavior** — counters must compile to nothing without the define.

## Constraints (apply to all phases)

- Nim 2.2.4, `--mm:refc` (enforced by nimble tasks). Build via `make` / nimble tasks only.
- Format all touched files with nph (`make nph/<file>` or the pre-commit hook).
- Run `gitnexus_impact` before editing cross-module symbols and `gitnexus_detect_changes()`
  before committing (project rule in AGENTS.md). Commit at the end of the phase; **never push**.
- Verify claims by running things, not by reasoning ("should work" is not done).

## Existing infrastructure to reuse

- `apps/benchmarks/benchmarks.nim` — existing RLN benchmark; nimble task at
  `logos_delivery.nimble:391-393` (`task benchmarks` → `buildBinary name, "apps/benchmarks/"`).
  Mirror this pattern; note it already imports from `tests/` (`tests/waku_rln_relay/utils_onchain`),
  so importing `tests/testlib/*` from `apps/benchmarks/` is accepted practice.
- `tests/testlib/wakucore.nim` — `fakeWakuMessage*` (line ~74) for deterministic messages.
- `tests/testlib/wakunode.nim` (verify exact name) — node construction helpers used by all
  node tests; use these for the macro scenario.

## Step 1 — Instrumentation counters (`-d:msgPathCounters`)

New file `logos_delivery/waku/waku_core/message/path_counters.nim` (~35 LOC):

```nim
when defined(msgPathCounters):
  type MsgPathCounters* = object
    decodeCalls*, hashCalls*: int64
    decodedBytes*, hashedBytes*: int64
  var msgPathCounters* {.global.}: MsgPathCounters
  template countDecode*(bytes: int) = ...   # inc calls, add bytes
  template countHash*(bytes: int) = ...
  proc resetMsgPathCounters*() = ...
else:
  template countDecode*(bytes: int) = discard
  template countHash*(bytes: int) = discard
```

Hook points (one line each, guarded template — zero cost when undefined):
- `logos_delivery/waku/waku_core/message/codec.nim:23` — inside
  `proc decode*(T: type WakuMessage, buffer: seq[byte])`: `countDecode(buffer.len)`.
- `logos_delivery/waku/waku_core/message/digest.nim:53` — inside `computeMessageHash`:
  `countHash(msg.payload.len + msg.meta.len)`.

Export via `waku_core` module as needed. Single-threaded chronos — plain int64, no atomics.

## Step 2 — Micro benchmark (in-process pipeline, no network)

New file `apps/benchmarks/message_path_bench.nim` (~250–320 LOC total with Step 3).

Setup: one WakuNode with relay mounted + archive (SQLite **in-memory** driver) + store-sync
(reconciliation) mounted; subscribe one shard so `registerRelayHandler`
(`logos_delivery/waku/node/subscription_manager.nim:29`) installs the full
`uniqueTopicHandler` chain (trace/filter/archive/sync/internal handlers, :45-82).

Injection: per message, replicate the gossipsub inbound sequence using WakuRelay's own
registered artifacts (both are stored in public tables on `WakuRelay`,
`waku_relay/protocol.nim:624,632`):
1. `let data = msg.encode().buffer` (prepared up front, excluded from timing)
2. `discard await relay.topicValidator[shard](shard, Message(topic: shard, data: data))`
   — exercises the ordered-validator decode (`protocol.nim:543`)
3. `await relay.topicHandlers[shard](shard, data)` — exercises topicHandler decode
   (`protocol.nim:603`) + full dispatch chain

Note in the output that observer decodes (`protocol.nim:271,326,341`) are NOT exercised by
the micro bench (they fire only in real gossipsub dispatch) — the macro scenario covers them.
If `topicValidator`/`topicHandlers` turn out not to be exported, add a
`when defined(msgPathCounters)` accessor to `waku_relay/protocol.nim` rather than exporting
the fields unconditionally.

Workload: fixed-seed generator (xorshift or `std/random` with `randomize(42)` equivalent —
NO time-based seed), payload mix **10 kB / 50 kB / 150 kB at 25 % / 50 % / 25 %**, unique
timestamps/nonce per message (avoid dedup), N = 1,000 messages + 100 warmup (excluded).

## Step 3 — Macro benchmark (two nodes, loopback gossipsub)

Same file, second scenario: two in-process nodes (testlib helpers), connected, both
subscribed to the shard; node B additionally has archive + sync mounted. Node A publishes
the same workload; node B counts arrivals via an app handler; stop timing when all N
received (with a sane timeout). This path includes libp2p rpcHandler + observers, so
counters here should show the full ≥4 decodes/message.

## Step 4 — Metrics & output

Per scenario emit one human block + one machine-readable CSV line to stdout:

```
scenario,msgs,payload_profile,wall_ms,msg_per_s,ns_per_msg_p50,ns_per_msg_p99,
decodes_per_msg,hashes_per_msg,hashed_MB,decoded_MB,occupied_mem_delta_MB,gc_collections
```

Sources: `getMonoTime` deltas per message for p50/p99; `getOccupiedMem()` before/after;
refc `GC_getStatistics()` (print raw string); counters from Step 1 (reset between scenarios).

## Step 5 — Build task + baseline capture

- Add nimble task `benchMessagePath` to `logos_delivery.nimble` mirroring the existing
  `benchmarks` task (:391-393), with `-d:msgPathCounters` added to its flags.
- Run it on the **current branch before Phases 2/3**; save both scenario outputs verbatim
  into `docs/analysis/bench_baseline.md` with the commit hash and machine info
  (`sysctl -n machdep.cpu.brand_string`, macOS version).

## Acceptance criteria

1. `make test` still fully green (production code untouched except no-op templates).
2. A production build **without** `-d:msgPathCounters` compiles and the counter templates
   vanish (verify: `nim c` of wakunode2 target still succeeds).
3. Two consecutive micro runs differ by < 5 % on msg/s (determinism check).
4. Macro scenario counters confirm the analysis: `decodes_per_msg ≥ 4`,
   `hashes_per_msg` in 4–6 on the receiving node. **If not, STOP and report the measured
   numbers before proceeding to Phase 2 — the analysis (and the expected gains) must be
   recalibrated first.**
5. `docs/analysis/bench_baseline.md` committed with the numbers.

## Estimated diff

~370–480 new LOC, ~10 changed LOC, no behavior change. Budget: 1–1.5 days.
