## Cross-thread broker declarations for the persistency library.
##
## One EventBroker (writes, fire-and-forget) and five RequestBrokers (reads
## + acked delete). All in multi-thread (mt) mode: the listener / provider runs on the
## job's storage thread; callers on any thread reach it via the shared
## BrokerContext owned by the Job.
##
## ## Error type, important
##
## nim-brokers' RequestBroker macro hard-codes the response shape as
## `Future[Result[ResponseType, string]]` — the error channel is `string`,
## not our `PersistencyError`. We honour the broker contract here and lift
## back to `PersistencyError` at the public facade (persistency.nim). The
## convention for the broker-level string is `"<kind>: <msg>"` so the
## facade can reconstruct the `PersistencyErrorKind`.
##
## ## Response shapes
##
## The five Kv* types are *response* objects (the value the provider
## returns). Per-request inputs sit on the `signature` proc parameters.

{.push raises: [].}

import std/[options, strutils]
import chronos, results
import brokers/[event_broker, request_broker, broker_context]
import brokers/internal/mt_codec
import ./types

export broker_context

# ── mt codec overloads for non-POD library types ────────────────────────
#
# brokers 2.0.0's mtMarshalValue / mtUnmarshalValue handle scalars, enums,
# strings, seqs, arrays, and plain object/tuple recursion -- but they do
# not see through `distinct seq[byte]`, nor do they know how to dispatch
# a variant (case) object. We provide explicit overloads for the types
# that appear in our broker payloads.

proc mtMarshalValue*(
    buf: ptr UncheckedArray[byte], cap: int, value: Key, pos: var int
): bool {.gcsafe.} =
  ## Encode a Key as the raw seq[byte] it wraps.
  mtMarshalValue(buf, cap, bytes(value), pos)

proc mtUnmarshalValue*(
    buf: ptr UncheckedArray[byte], len: int, value: var Key, pos: var int
): bool {.gcsafe.} =
  var s: seq[byte]
  if not mtUnmarshalValue(buf, len, s, pos):
    return false
  value = Key(s)
  return true

proc mtMarshalValue*(
    buf: ptr UncheckedArray[byte], cap: int, value: TxOp, pos: var int
): bool {.gcsafe.} =
  ## TxOp is a case object: write the discriminator, then only the
  ## fields that belong to the active branch.
  if not mtMarshalValue(buf, cap, value.category, pos):
    return false
  if not mtMarshalValue(buf, cap, value.key, pos):
    return false
  let kind = uint8(ord(value.kind))
  if not mtMarshalValue(buf, cap, kind, pos):
    return false
  case value.kind
  of txPut:
    if not mtMarshalValue(buf, cap, value.payload, pos):
      return false
  of txDelete:
    discard
  return true

proc mtUnmarshalValue*(
    buf: ptr UncheckedArray[byte], len: int, value: var TxOp, pos: var int
): bool {.gcsafe.} =
  var
    category: string
    key: Key
    kindByte: uint8
  if not mtUnmarshalValue(buf, len, category, pos):
    return false
  if not mtUnmarshalValue(buf, len, key, pos):
    return false
  if not mtUnmarshalValue(buf, len, kindByte, pos):
    return false
  case TxOpKind(kindByte)
  of txPut:
    var payload: seq[byte]
    if not mtUnmarshalValue(buf, len, payload, pos):
      return false
    value = TxOp(category: category, key: key, kind: txPut, payload: payload)
  of txDelete:
    value = TxOp(category: category, key: key, kind: txDelete)
  return true

EventBroker(mt):
  type PersistEvent* = object
    ops*: seq[TxOp]

RequestBroker(mt):
  type KvGet* = object
    value*: Option[seq[byte]]

  proc signature*(category: string, key: Key): Future[Result[KvGet, string]] {.async.}

RequestBroker(mt):
  type KvExists* = object
    value*: bool

  proc signature*(
    category: string, key: Key
  ): Future[Result[KvExists, string]] {.async.}

RequestBroker(mt):
  type KvScan* = object
    rows*: seq[KvRow]

  proc signature*(
    category: string, range: KeyRange, reverse: bool
  ): Future[Result[KvScan, string]] {.async.}

RequestBroker(mt):
  type KvCount* = object
    n*: int

  proc signature*(
    category: string, range: KeyRange
  ): Future[Result[KvCount, string]] {.async.}

RequestBroker(mt):
  type KvDelete* = object
    existed*: bool

  proc signature*(
    category: string, key: Key
  ): Future[Result[KvDelete, string]] {.async.}

# ── string<->PersistencyError boundary helpers ──────────────────────────

const ErrSep = ": "

proc encodeErr*(e: PersistencyError): string =
  ## Encode a PersistencyError into the broker's string channel. The facade
  ## decodes via `decodeErr`.
  $e.kind & ErrSep & e.msg

proc decodeErr*(s: string): PersistencyError =
  ## Inverse of encodeErr. Falls back to peBackend if the prefix is missing.
  let idx = s.find(ErrSep)
  if idx < 0:
    return persistencyErr(peBackend, s)
  let head = s[0 ..< idx]
  let tail = s[idx + ErrSep.len .. ^1]
  for k in PersistencyErrorKind:
    if $k == head:
      return persistencyErr(k, tail)
  persistencyErr(peBackend, s)

{.pop.}
