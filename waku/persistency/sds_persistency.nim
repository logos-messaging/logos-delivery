## Adapter that materialises the SDS `Persistence` contract (nim-sds 0.3.0,
## snapshot model) on top of a waku-persistency `Job`. One `Job` (== one
## SQLite file, one worker thread) services all channels for a given SDS
## context; rows are namespaced by category and the channelId is the first
## key component so per-channel prefix scans stay cheap.
##
## ## Snapshot contract (nim-sds 0.3.0)
##
## The fine-grained per-row callbacks of 0.2.4 are gone. SDS now persists via
## five procs, all `Future[Result[void, string]]` (load returns
## `Result[ChannelData, string]`), `{.async: (raises: []), gcsafe.}`:
##
##  * **`saveChannelMeta`** — the complete fast-changing per-channel state
##    (lamport clock, outgoing/incoming buffers, both SDS-R repair buffers)
##    as ONE blob. Idempotent; a missed write self-heals on the next save.
##  * **`updateHistory`** — append newly-delivered messages / evict the
##    oldest past the cap, applied as one transactional batch.
##  * **`loadChannel`** — bootstrap: returns the prior `ChannelData`
##    (meta + ordered message history) or an empty one. Surfaces errors.
##  * **`dropChannel`** — wipe all state for a channel. Surfaces errors.
##  
## Failure policy mirrors the interface docs: save/update/hint are non-fatal
## (we log and still return the error string); load/drop are durability-intent
## and propagate their error to the caller.
##
## ## Codec
##
## The blob transform is owned by nim-sds: `ChannelMeta` round-trips through
## `sds/snapshot_codec` (protobuf, schema-versioned — refuses unknown
## versions), and each persisted `SdsMessage` log row through the SDS wire
## codec in `sds/protobuf`. We do not maintain a second codec for these
## shapes (the previous `payload_codec`/`BlobCodec` path is retired).
##
## ## Retrieval hints
##
## `setRetrievalHint` is intentionally a no-op: persisted hints are never read
## back — `loadChannel` returns `ChannelData` (meta + messageHistory) with no
## hint field, and `ChannelMeta` carries none. Hints are supplied live via the
## `onRetrievalHint` provider, so persisting them would be write-only dead
## data. The closure still exists because the field is required by the
## `Persistence` object (SDS calls it from `getRecentHistoryEntries`).
##
## ## Storage layout
##
## | Category      | Key                      | Value                                  |
## |---------------|--------------------------|----------------------------------------|
## | `sds.meta`    | `key(channelId)`         | `ChannelMeta` (snapshot_codec protobuf)|
## | `sds.log`     | `key(channelId, msgId)`  | `SdsMessage` (sds wire protobuf)       |
##
## `messageHistory` is reconstructed in memory by sorting on
## `(lamportTimestamp, messageId)` — the same total order SDS uses for
## delivery (see sds/sds_utils.nim).

{.push raises: [].}

import std/[algorithm, options]
import chronos, chronicles, results
import libp2p/protobuf/minprotobuf
import ./persistency
import ./keys
import types/persistence
import snapshot_codec
import protobuf

export persistence, persistency

logScope:
  topics = "sds-persistency"

const
  CatMeta* = "sds.meta"
  CatLog* = "sds.log"

# ── Public factory ──────────────────────────────────────────────────────

proc newSdsPersistence*(job: Job): Persistence {.gcsafe, raises: [].} =
  ## Build an SDS `Persistence` value backed by ``job``. One Job services
  ## all channels — channelId is part of every key.
  ##
  ## The closures capture ``job`` by ref. They must be invoked from a thread
  ## that owns a running chronos loop (the SDS context's worker thread
  ## satisfies this).
  doAssert not job.isNil, "newSdsPersistence: job is nil"

  # Built field-by-field via assignment rather than an object literal: every
  # field is an async closure whose body uses `await`/`return` statements,
  # which cannot be followed by the `,` field separator a `Persistence(..)`
  # literal would require. Assignments have no separator, so bodies stay plain.
  var persistence = Persistence()

  persistence.saveChannelMeta = proc(
      channelId: SdsChannelID, meta: ChannelMeta
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
    try:
      await job.persistPut(CatMeta, toKey(channelId), encode(meta).buffer)
      return ok()
    except CatchableError as e:
      warn "sds-persistency: saveChannelMeta failed", channelId, err = e.msg
      return err(e.msg)

  persistence.updateHistory = proc(
      channelId: SdsChannelID, update: HistoryUpdate
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
    if update.isEmpty:
      return ok()
    # One transactional batch: append rows (txPut) and evictions (txDelete).
    var ops = newSeq[TxOp]()
    for m in update.append:
      ops.add TxOp(
        category: CatLog,
        key: key(channelId, m.messageId),
        kind: txPut,
        payload: encode(m).buffer,
      )
    for id in update.evict:
      ops.add TxOp(category: CatLog, key: key(channelId, id), kind: txDelete)
    try:
      await job.persist(ops)
      return ok()
    except CatchableError as e:
      warn "sds-persistency: updateHistory failed",
        channelId, appended = update.append.len, evicted = update.evict.len, err = e.msg
      return err(e.msg)

  persistence.loadChannel = proc(
      channelId: SdsChannelID
  ): Future[Result[ChannelData, string]] {.async: (raises: []), gcsafe.} =
    let chanKey = toKey(channelId)
    var data = ChannelData.init()
    try:
      block meta:
        let opt = (await job.get(CatMeta, chanKey)).valueOr:
          return err("loadChannel: get meta: " & $error)
        if opt.isSome:
          # schema-versioned decode; refuses unknown versions loudly.
          data.meta = ChannelMeta.decode(opt.get).valueOr:
            return err("loadChannel: corrupt or unsupported ChannelMeta blob")

      block history:
        let rows = (await job.scanPrefix(CatLog, chanKey)).valueOr:
          return err("loadChannel: scan log: " & $error)
        var msgs = newSeq[SdsMessage]()
        for row in rows:
          let m = SdsMessage.decode(row.payload).valueOr:
            warn "sds-persistency: skipping undecodable log row", channelId
            continue
          msgs.add(m)
        msgs.sort do(a, b: SdsMessage) -> int:
          result = cmp(a.lamportTimestamp, b.lamportTimestamp)
          if result == 0:
            result = cmp(a.messageId, b.messageId)
        data.messageHistory = msgs

      return ok(data)
    except CatchableError as e:
      return err("loadChannel: " & e.msg)

  persistence.dropChannel = proc(
      channelId: SdsChannelID
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
    let chanKey = toKey(channelId)
    try:
      await job.persist(
        @[
          TxOp(category: CatLog, key: chanKey, kind: txDeletePrefix),
          TxOp(category: CatMeta, key: chanKey, kind: txDelete),
        ]
      )
      return ok()
    except CatchableError as e:
      error "sds-persistency: dropChannel failed", channelId, err = e.msg
      return err(e.msg)

  return persistence

{.pop.}
