# Phase 2 — `WakuMessage` becomes a `ref object` (executor plan)

> Self-contained implementation plan. Context: [async_copy_analysis.md](async_copy_analysis.md),
> [async_copy_fix_plan.md](async_copy_fix_plan.md). Prerequisite: Phase 1 benchmark exists
> and `docs/analysis/bench_baseline.md` is recorded.
>
> **Objective**: change `WakuMessage` from a value `object` to a `ref object` so every
> assignment, async-closure capture, and Result/Option bind-out of a message costs a
> pointer + refcount instead of deep-copying 3 seqs + a string. No proc signatures change.
> Expected result (verify with Phase 1 bench): ~50–60 % reduction in alloc volume per
> message; decode/hash counters unchanged.
>
> **The danger of this phase is not the diff size — it is aliasing.** Code written under
> value semantics may mutate "its copy" of a message; under ref semantics that mutation is
> now shared with every other holder. Every mutation site must be found and either cloned
> or proven to own a freshly constructed message.

## Constraints

Same as Phase 1 (refc, nph, gitnexus impact/detect_changes, no push, verify by running).
Additionally: run `gitnexus_impact({target: "WakuMessage", direction: "upstream"})` first
and report the blast radius before editing.

## Step 1 — The type change (`logos_delivery/waku/waku_core/message/message.nim`)

Current (lines 12–29): `type WakuMessage* = object` with `payload: seq[byte]`,
`contentTopic: ContentTopic`, `meta: seq[byte]`, `version: uint32`,
`timestamp: Timestamp`, `ephemeral: bool`, `proof: seq[byte]`.

1. `type WakuMessage* = ref object` — construction syntax `WakuMessage(payload: ...)` is
   unchanged, so the 27 src + ~1,324 test constructions (1,174 via `fakeWakuMessage`,
   `tests/testlib/wakucore.nim:74`) compile as-is.
2. Add a **structural `==`** (~12 LOC): both-nil → true, one-nil → false, else field-wise
   compare. Without this, ~107 test assertions comparing messages break on ref identity.
3. Add `proc clone*(msg: WakuMessage): WakuMessage` — field-wise copy into a fresh ref
   (deep-copies the seqs; that is the point: cloning is now *explicit and rare*).
4. **Fix `ensureTimestampSet` (lines 31–34).** Current body `result = message;
   result.timestamp = ...` aliases the input under ref semantics and mutates the *shared*
   message. Rewrite non-mutating:
   ```nim
   proc ensureTimestampSet*(message: WakuMessage): WakuMessage =
     if message.timestamp != 0:
       return message
     var m = message.clone()
     m.timestamp = getNowInNanosecondTime()
     m
   ```
5. Doc comment at the type: messages are **immutable by convention after construction**;
   mutate only freshly constructed or explicitly `clone()`d instances. Also note the
   deliberate deviation from the AGENTS.md `Ref`-suffix rule (renaming ~2,100 occurrences
   has no semantic value).

## Step 2 — Known aliasing sites (fix, don't just audit)

1. **Relay publish** `logos_delivery/waku/waku_relay/protocol.nim:680-682`:
   ```nim
   var message = wakuMessage
   if message.timestamp == 0:
     message.timestamp = getNowInNanosecondTime()
   ```
   Under ref this mutates the caller's message. Replace with
   `let message = wakuMessage.ensureTimestampSet()` (safe after Step 1.4).
2. **RLN proof attachment** — search `logos_delivery/waku/waku_rln_relay/` for procs taking
   `msg: var WakuMessage` or assigning `msg.proof = ` (e.g. `appendRLNProof`). These run on
   the *outbound* path on a message the API caller still holds. Decision rule: if the
   message came in through a public API, `clone()` before mutating (or restructure to
   build-then-assign locally).
3. **Sweep for every other field mutation**:
   `grep -rn --include='*.nim' '\.\(payload\|meta\|proof\|timestamp\|ephemeral\|version\|contentTopic\) *=' logos_delivery library apps`
   Classify each hit: (a) freshly constructed in the same scope (e.g. the protobuf decode
   at `waku_core/message/codec.nim:23` building `var msg = WakuMessage()`) → fine;
   (b) received/parameter/stored message → `clone()` first or restructure. Record the
   classification of every hit in the phase notes (this list is the review artifact).

## Step 3 — Nil-safety audit

`var m: WakuMessage` now defaults to `nil`, not an empty object; field access on it crashes.

- `grep -rn --include='*.nim' 'var [a-zA-Z_]*: WakuMessage\b\|: WakuMessage$' logos_delivery library apps` —
  any declaration relying on default-init must become `= WakuMessage()`.
- Check emptiness idioms: `== WakuMessage()` / `== default(WakuMessage)` comparisons and
  `Table[..., WakuMessage].getOrDefault` consumers (getOrDefault now yields `nil`).
- Fields of type `WakuMessage` inside other objects (e.g. `MessagePush.wakuMessage` in
  `waku_filter_v2/rpc.nim`, store RPC types, `queue_driver`'s
  `SortedSet[Index, WakuMessage]`) — their decode paths must construct explicitly; verify
  each codec assigns a constructed message (`rpc_codec.nim` files for filter/lightpush/store).
- `Option[WakuMessage]`/`Opt[WakuMessage]` (only 2 src occurrences): `none`/absent now also
  representable as nil ref — do NOT collapse the two; keep the Opt wrapper semantics as-is.

## Step 4 — Tests

- Full `make test`. Expected failure classes: nil-default (Step 3 misses), ref-identity
  assumptions (tests mutating a fixture then asserting the original unchanged — now shared),
  and `check msg1 == msg2` (covered by structural `==`).
- Do NOT weaken test assertions to make them pass; fix the production/nil issue instead.
- Add new unit tests in `tests/waku_core/` (~40 LOC): structural `==` incl. nil cases;
  `clone()` independence (mutating clone leaves original untouched); `ensureTimestampSet`
  returns same ref when timestamp set / fresh ref when not.

## Step 5 — Memory-model verification (mandatory before "done")

- refc: full suite + the Phase 1 benchmark; record the checkpoint numbers next to
  `bench_baseline.md` (expect alloc-volume drop, identical decode/hash counters, identical
  message throughput or better).
- ASAN run of the message-path tests (clang, refc) — this is the net that catches
  a use-after-free from the new shared lifetimes: at minimum
  `tests/waku_relay`, `tests/waku_archive`, `tests/waku_filter_v2`, `tests/node`.
- Statement for the record (per FFI rules): `library/` C bindings deep-copy message fields
  via `copyMem` into JSON events (`library/json_message_event.nim:72-95`), so no message
  ref crosses the FFI boundary; refc vs ORC behavior of the ref itself is standard RC —
  no finalizers, no cycles (WakuMessage has no back-references).

## Acceptance criteria

1. Full `make test` green; ASAN run clean.
2. Step 2.3 mutation-site classification list produced (in PR description or phase notes).
3. Phase 1 bench re-run recorded: alloc volume down ≥ 40 % (projection is 50–60 %),
   decode/hash counters unchanged vs baseline. If alloc volume barely moves, something
   still deep-copies — investigate before closing the phase (prime suspects: a `var`
   parameter forcing a copy, or a leftover value-type field of WakuMessage inside a
   container that the compiler still copies).
4. `gitnexus_detect_changes()` reviewed; commit (no push).

## Estimated diff

~35 new LOC, ~160–340 changed LOC (dominated by Steps 2.3/3 fixes and test adjustments).
Budget: 2–3 days, most of it audit + verification, not typing.
