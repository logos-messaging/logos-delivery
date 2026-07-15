# Phase 2 — `WakuMessage` mutation-site audit

Review artifact for the value-`object` → `ref object` change. Every hit of the
field-mutation sweep is classified below. Sweep command (plan Step 2.3):

```
grep -rn --include='*.nim' -E '\.(payload|meta|proof|timestamp|ephemeral|version|contentTopic) *=[^=]' logos_delivery library apps
```

plus the nil-safety declaration sweep (plan Step 3):

```
grep -rn --include='*.nim' -E 'var [a-zA-Z_]+: WakuMessage\b|: WakuMessage$' logos_delivery library apps
```

Legend: **FINE** = freshly constructed / owned in the same scope, or not a
`WakuMessage` at all; **FIXED** = mutated a shared/held message under ref
semantics, corrected.

## Field-mutation hits

| # | Site | What it does | Class | Action |
|---|---|---|---|---|
| 1 | `logos_delivery/api/types.nim:81` | `# wm.proof = ...` | FINE | commented-out dead code, no effect |
| 2 | `logos_delivery/waku/rln/proof.nim:93` (`attachRLNProof`) | `msgWithProof.proof = ...` on `var msgWithProof = message` | **FIXED** | outbound path; caller still holds `message`. Changed to `let msgWithProof = message.clone()` |
| 3 | `logos_delivery/waku/rest_api/endpoint/relay/handlers.nim:73` (`attachRlnProofAndValidate`) | `msg.proof = ...` on `var msg = message` | **FIXED** | same aliasing as #2. Changed to `let msg = message.clone()` |
| 4 | `logos_delivery/waku/waku_relay/protocol.nim:680` (`publish`) | `var message = wakuMessage; message.timestamp = ...` | **FIXED** | caller's message mutated. Replaced with `let message = wakuMessage.ensureTimestampSet()` |
| 5 | `logos_delivery/waku/waku_core/message/message.nim:31` (`ensureTimestampSet`) | `result = message; result.timestamp = ...` | **FIXED** | aliased+mutated the shared input. Rewritten to clone-when-unset (non-mutating) |
| 6 | `logos_delivery/waku/waku_core/message/codec.nim:32–72` (`decode`) | `msg.payload/…=` on `var msg = WakuMessage()` | FINE | freshly constructed in same scope |
| 7 | `logos_delivery/waku/waku_archive/driver/postgres_driver/postgres_driver.nim:284–288` | field writes on `var wakuMessage` | FINE after fix | fresh per loop iteration; needed nil-init (see nil-safety #A) — no cross-row aliasing |
| 8 | `postgres_driver.nim:832` | `m.timestamp = l.timestamp` | FINE | inside a SQL query string literal, not Nim code |
| 9 | `logos_delivery/waku/persistency/sds_persistency.nim:136` | `data.meta = ...` | FINE | `data` is `ChannelData`, not `WakuMessage` |
| 10 | `apps/chat2/chat2.nim:96` | `msg.timestamp = ...` | FINE | `msg` is a `Chat2Message`, not `WakuMessage` |
| 11 | `apps/chat2/chat2.nim:200` | `message.proof = proofRes.get()` | FINE | `message` freshly constructed locally at chat2.nim:184 (`var message = WakuMessage(...)`), owned in scope |
| 12 | `apps/chat2mix/chat2mix.nim:118` | `msg.timestamp = ...` | FINE | `msg` is a `Chat2Message`, not `WakuMessage` |

## Nil-safety hits (`var x: WakuMessage` now defaults to `nil`)

| # | Site | Class | Action |
|---|---|---|---|
| A | `postgres_driver.nim:260` — `var wakuMessage: WakuMessage` in the row-decode loop | **FIXED** | default-init is now `nil`; following field writes would deref nil. Changed to `= WakuMessage()` |
| B | `not_delivered_storage.nim:22` — `msg: WakuMessage` field of `TrackedWakuMessage` | FINE | `TrackedWakuMessage` is not constructed on any active path (`archiveMessage` is a stub returning `ok()`); no nil deref reachable |
| C | `recv_service.nim:63` — `let otherwiseMsg = WakuMessage()` | FINE | explicit construction used as `Option.get` default; non-nil |

## Codec / container decode paths (plan Step 3 verification)

All decoders that populate a `WakuMessage`-typed field construct explicitly, so
none rely on nil default-init:

- `waku_core/message/codec.nim:25` — `var msg = WakuMessage()`
- `waku_filter_v2/rpc_codec.nim:93` — `rpc.wakuMessage = ?WakuMessage.decode(message)`
- `waku_lightpush/rpc_codec.nim:38` / `waku_lightpush_legacy/rpc_codec.nim` — `rpc.message = ?WakuMessage.decode(...)`
- `waku_store/rpc_codec.nim:167/170` — `keyValue.message = some(?WakuMessage.decode(...))` / `none(WakuMessage)` (Opt wrapper kept, not collapsed to nil)
- sqlite `queries.nim:35` / postgres row decode — `return WakuMessage(...)` / `WakuMessage()`

`Option[WakuMessage]` / `Opt[WakuMessage]` occurrences (store RPC, filter) keep
their wrapper semantics; nil-ref and `none` are **not** conflated.

## Other diagnostic fix

- `logos_delivery/waku/rln/rln.nim:75` — `msgHash = msg.hash` (a chronicles log
  field) resolved to the generic `std/hashes` object hash under value semantics;
  a ref no longer matches it. Changed to `msg[].hash` to preserve the exact
  prior diagnostic value. Not a mutation; surfaced by the type change.
