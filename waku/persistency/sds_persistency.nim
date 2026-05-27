## Adapter that materialises the SDS `Persistence` contract on top of a
## waku-persistency `Job`. One `Job` (== one SQLite file, one worker thread)
## services all channels for a given SDS context; rows are namespaced by
## category and the channelId is the first key component so per-channel
## prefix scans stay cheap.
##
## ## Async contract
##
## Every `Persistence` proc field is async (`proc(..): Future[void]
## {.async: (raises: []), gcsafe.}`) — SDS awaits them on its own chronos
## loop. We map each onto the matching async `Job` op:
##
##  * **Writes (save*/remove*)** — call the fire-and-forget `Job.persist*` ops
##    through the `safePut`/`safeDelete` helpers, which trap any backend error
##    and log it rather than raising (the contract forbids raising). Note that
##    Persistency v1 only guarantees the event has been queued when the Future
##    resolves — reads immediately after an awaited write can still be racy.
##  * **`dropChannel`** — awaits `doDropChannel`, which batches every row of
##    the channel into one transactional `persist` (atomic when applied).
##  * **`loadAllForChannel`** — awaits `doLoadAll` and returns the snapshot
##    the SDS bootstrap path needs.
##
## ## Storage layout
##
## | Category         | Key                          | Value                                   |
## |------------------|------------------------------|-----------------------------------------|
## | `sds.lamport`    | `key(channelId)`             | 8 BE bytes (int64)                      |
## | `sds.log`        | `key(channelId, msgId)`      | encoded `SdsMessage`                    |
## | `sds.hint`       | `key(msgId)`                 | raw hint bytes                          |
## | `sds.outgoing`   | `key(channelId, msgId)`      | encoded `UnacknowledgedMessage`         |
## | `sds.incoming`   | `key(channelId, msgId)`      | encoded `IncomingMessage`               |
## | `sds.outRepair`  | `key(channelId, msgId)`      | `(msgId, OutgoingRepairEntry)` encoded  |
## | `sds.inRepair`   | `key(channelId, msgId)`      | `(msgId, IncomingRepairEntry)` encoded  |
##
## `messageHistory` is reconstructed in memory by sorting on
## `(lamportTimestamp, messageId)` — the same total order SDS uses for
## delivery (see sds/sds_utils.nim). Insertion order is not relied upon, so
## `removeLogEntry` works with the natural `(channelId, msgId)` key.

{.push raises: [].}

import std/[algorithm, options, sets, times]
import chronos, chronicles, results
import ./persistency
import ./payload_codec
import sds/types/persistence

export persistence, persistency

logScope:
  topics = "sds-persistency"

const
  CatLamport* = "sds.lamport"
  CatLog* = "sds.log"
  CatHint* = "sds.hint"
  CatOutgoing* = "sds.outgoing"
  CatIncoming* = "sds.incoming"
  CatOutRepair* = "sds.outRepair"
  CatInRepair* = "sds.inRepair"

# ── Blob codecs ─────────────────────────────────────────────────────────
#
# All SDS payload types round-trip through the generic, length-prefixed
# codec in payload_codec.nim. Each `BlobCodec(T)` emits writePart/
# readPart for `T` from its public fields (declaration order) and rebuilds
# via `T.init(...)`. Order matters: a field's type must be derived before
# the struct that contains it. The repair buffers store `(msgId, entry)`
# tuples, handled by the generic tuple codec. Lamport is a bare int64.

BlobCodec(HistoryEntry)
BlobCodec(SdsMessage)
BlobCodec(UnacknowledgedMessage)
BlobCodec(IncomingMessage)
BlobCodec(OutgoingRepairEntry)
BlobCodec(IncomingRepairEntry)

# ── Write helpers ───────────────────────────────────────────────────────
#
# The Persistence write fields are async with `raises: []`, but the Job ops
# raise `CatchableError`. These wrappers trap and log so the closures stay
# raise-free, preserving the "errors are logged, never raised" contract.

proc safePut(
    job: Job, category: string, k: Key, payload: seq[byte]
) {.async: (raises: []).} =
  try:
    await job.persistPut(category, k, payload)
  except CatchableError as e:
    warn "sds-persistency: put failed", category, err = e.msg

proc safeDelete(job: Job, category: string, k: Key) {.async: (raises: []).} =
  try:
    await job.persistDelete(category, k)
  except CatchableError as e:
    warn "sds-persistency: delete failed", category, err = e.msg

proc safePersist(job: Job, ops: seq[TxOp]) {.async: (raises: []).} =
  try:
    await job.persist(ops)
  except CatchableError as e:
    warn "sds-persistency: persist batch failed", opCount = ops.len, err = e.msg

# ── Async backing procs ─────────────────────────────────────────────────

proc doLoadAll(job: Job, channelId: SdsChannelID): Future[ChannelSnapshot] {.async.} =
  var snap = ChannelSnapshot()
  let chanKey = toKey(channelId)

  block lamport:
    let opt = (await job.get(CatLamport, chanKey)).valueOr:
      warn "sds-persistency: get lamport failed", channelId, err = $error
      break lamport
    if opt.isSome:
      try:
        snap.lamportTimestamp = fromBlob(opt.get, int64)
      except ValueError as e:
        warn "sds-persistency: invalid lamport bytes", channelId, err = e.msg

  block log:
    let rows = (await job.scanPrefix(CatLog, chanKey)).valueOr:
      warn "sds-persistency: scan log failed", channelId, err = $error
      break log
    var msgs = newSeq[SdsMessage]()
    for row in rows:
      try:
        msgs.add(fromBlob(row.payload, SdsMessage))
      except ValueError as e:
        warn "sds-persistency: invalid log row", channelId, err = e.msg
    msgs.sort do(a, b: SdsMessage) -> int:
      result = cmp(a.lamportTimestamp, b.lamportTimestamp)
      if result == 0:
        result = cmp(a.messageId, b.messageId)
    snap.messageHistory = msgs

  block outgoing:
    let rows = (await job.scanPrefix(CatOutgoing, chanKey)).valueOr:
      warn "sds-persistency: scan outgoing failed", channelId, err = $error
      break outgoing
    for row in rows:
      try:
        snap.outgoingBuffer.add(fromBlob(row.payload, UnacknowledgedMessage))
      except ValueError as e:
        warn "sds-persistency: invalid outgoing row", channelId, err = e.msg

  block incoming:
    let rows = (await job.scanPrefix(CatIncoming, chanKey)).valueOr:
      warn "sds-persistency: scan incoming failed", channelId, err = $error
      break incoming
    for row in rows:
      try:
        snap.incomingBuffer.add(fromBlob(row.payload, IncomingMessage))
      except ValueError as e:
        warn "sds-persistency: invalid incoming row", channelId, err = e.msg

  block outRepair:
    let rows = (await job.scanPrefix(CatOutRepair, chanKey)).valueOr:
      warn "sds-persistency: scan out-repair failed", channelId, err = $error
      break outRepair
    for row in rows:
      try:
        snap.outgoingRepairBuffer.add(
          fromBlob(row.payload, (SdsMessageID, OutgoingRepairEntry))
        )
      except ValueError as e:
        warn "sds-persistency: invalid out-repair row", channelId, err = e.msg

  block inRepair:
    let rows = (await job.scanPrefix(CatInRepair, chanKey)).valueOr:
      warn "sds-persistency: scan in-repair failed", channelId, err = $error
      break inRepair
    for row in rows:
      try:
        snap.incomingRepairBuffer.add(
          fromBlob(row.payload, (SdsMessageID, IncomingRepairEntry))
        )
      except ValueError as e:
        warn "sds-persistency: invalid in-repair row", channelId, err = e.msg

  return snap

proc doDropChannel(job: Job, channelId: SdsChannelID): Future[void] {.async.} =
  ## Delete every row belonging to the channel in one transactional batch.
  ## Uses txDeletePrefix to push bulk deletes to the worker thread — no
  ## caller-side scans needed. Hint rows (keyed by msgId, not channelId)
  ## are not cleaned here; they are cascade-deleted by removeLogEntry during
  ## normal rolling-history eviction, so by the time a channel is dropped
  ## the only remaining hints belong to the still-live log tail. Those
  ## become harmless orphans (never reloaded — hints are re-derived on
  ## demand from the onRetrievalHint callback).
  let chanKey = toKey(channelId)
  await safePersist(
    job,
    @[
      TxOp(category: CatLog, key: chanKey, kind: txDeletePrefix),
      TxOp(category: CatOutgoing, key: chanKey, kind: txDeletePrefix),
      TxOp(category: CatIncoming, key: chanKey, kind: txDeletePrefix),
      TxOp(category: CatOutRepair, key: chanKey, kind: txDeletePrefix),
      TxOp(category: CatInRepair, key: chanKey, kind: txDeletePrefix),
      TxOp(category: CatLamport, key: chanKey, kind: txDelete),
    ],
  )

# ── Public factory ──────────────────────────────────────────────────────

proc newSdsPersistence*(job: Job): Persistence {.gcsafe, raises: [].} =
  ## Build an SDS `Persistence` value backed by ``job``. One Job services
  ## all channels — channelId is part of every key.
  ##
  ## The closures capture ``job`` by ref. They must be invoked from a
  ## thread that owns a running chronos loop (the SDS context's worker
  ## thread satisfies this).
  doAssert not job.isNil, "newSdsPersistence: job is nil"

  # Built field-by-field via assignment rather than an object literal: every
  # field is an async closure whose body is an `await`/`return await` command
  # call, which cannot be followed by the `,` field separator a `Persistence(
  # ..)` literal would require (the parser cannot tell the comma from another
  # command argument). Assignments have no separator, so the bodies stay plain.
  var persistence = Persistence()

  persistence.saveLamport = proc(
      channelId: SdsChannelID, lamport: int64
  ): Future[void] {.async: (raises: []), gcsafe.} =
    await safePut(job, CatLamport, toKey(channelId), toBlob(lamport))

  persistence.appendLogEntry = proc(
      channelId: SdsChannelID, msg: SdsMessage
  ): Future[void] {.async: (raises: []), gcsafe.} =
    await safePut(job, CatLog, key(channelId, msg.messageId), toBlob(msg))

  persistence.removeLogEntry = proc(
      channelId: SdsChannelID, msgId: SdsMessageID
  ): Future[void] {.async: (raises: []), gcsafe.} =
    # Atomic batch: delete the log row and its associated retrieval hint in
    # one transaction so they can't diverge.
    await safePersist(
      job,
      @[
        TxOp(category: CatLog, key: key(channelId, msgId), kind: txDelete),
        TxOp(category: CatHint, key: toKey(msgId), kind: txDelete),
      ],
    )

  persistence.setRetrievalHint = proc(
      msgId: SdsMessageID, hint: seq[byte]
  ): Future[void] {.async: (raises: []), gcsafe.} =
    await safePut(job, CatHint, toKey(msgId), hint)

  persistence.saveOutgoing = proc(
      channelId: SdsChannelID, msg: UnacknowledgedMessage
  ): Future[void] {.async: (raises: []), gcsafe.} =
    await safePut(job, CatOutgoing, key(channelId, msg.message.messageId), toBlob(msg))

  persistence.removeOutgoing = proc(
      channelId: SdsChannelID, msgId: SdsMessageID
  ): Future[void] {.async: (raises: []), gcsafe.} =
    await safeDelete(job, CatOutgoing, key(channelId, msgId))

  persistence.saveIncoming = proc(
      channelId: SdsChannelID, msg: IncomingMessage
  ): Future[void] {.async: (raises: []), gcsafe.} =
    await safePut(job, CatIncoming, key(channelId, msg.message.messageId), toBlob(msg))

  persistence.removeIncoming = proc(
      channelId: SdsChannelID, msgId: SdsMessageID
  ): Future[void] {.async: (raises: []), gcsafe.} =
    await safeDelete(job, CatIncoming, key(channelId, msgId))

  persistence.saveOutgoingRepair = proc(
      channelId: SdsChannelID, msgId: SdsMessageID, entry: OutgoingRepairEntry
  ): Future[void] {.async: (raises: []), gcsafe.} =
    await safePut(job, CatOutRepair, key(channelId, msgId), toBlob((msgId, entry)))

  persistence.removeOutgoingRepair = proc(
      channelId: SdsChannelID, msgId: SdsMessageID
  ): Future[void] {.async: (raises: []), gcsafe.} =
    await safeDelete(job, CatOutRepair, key(channelId, msgId))

  persistence.saveIncomingRepair = proc(
      channelId: SdsChannelID, msgId: SdsMessageID, entry: IncomingRepairEntry
  ): Future[void] {.async: (raises: []), gcsafe.} =
    await safePut(job, CatInRepair, key(channelId, msgId), toBlob((msgId, entry)))

  persistence.removeIncomingRepair = proc(
      channelId: SdsChannelID, msgId: SdsMessageID
  ): Future[void] {.async: (raises: []), gcsafe.} =
    await safeDelete(job, CatInRepair, key(channelId, msgId))

  persistence.dropChannel = proc(
      channelId: SdsChannelID
  ): Future[void] {.async: (raises: []), gcsafe.} =
    try:
      await doDropChannel(job, channelId)
    except CatchableError as e:
      error "sds-persistency: dropChannel failed", channelId, err = e.msg

  persistence.loadAllForChannel = proc(
      channelId: SdsChannelID
  ): Future[ChannelSnapshot] {.async: (raises: []), gcsafe.} =
    try:
      return await doLoadAll(job, channelId)
    except CatchableError as e:
      error "sds-persistency: loadAllForChannel failed", channelId, err = e.msg
      return ChannelSnapshot()

  return persistence

{.pop.}
