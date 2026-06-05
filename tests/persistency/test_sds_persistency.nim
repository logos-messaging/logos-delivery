{.used.}

## Behavioural tests for the SDS Persistence adapter (nim-sds 0.3.0 snapshot
## model). Importing `sds_persistency` also compile-checks the real adapter.
##
## Writes go through the fire-and-forget Job path (the Future resolves when
## the op is queued, not applied — Persistency v1), so every read-back polls
## until the row appears/disappears.

import std/[options, os, times]
import chronos, results
import testutils/unittests
import logos_delivery/waku/persistency/persistency
import logos_delivery/waku/persistency/keys
import logos_delivery/waku/persistency/sds_persistency

proc tmpRoot(label: string): string =
  let p = getTempDir() / ("sds_persistency_test_" & label & "_" & $epochTime().int)
  removeDir(p)
  p

proc pollExists(
    t: Job, category: string, k: Key, timeoutMs = 1000
): Future[bool] {.async.} =
  let deadline = epochTime() + (timeoutMs.float / 1000.0)
  while epochTime() < deadline:
    let r = await t.exists(category, k)
    if r.isOk and r.get():
      return true
    await sleepAsync(chronos.milliseconds(2))
  return false

proc pollGone(
    t: Job, category: string, k: Key, timeoutMs = 1000
): Future[bool] {.async.} =
  let deadline = epochTime() + (timeoutMs.float / 1000.0)
  while epochTime() < deadline:
    let r = await t.exists(category, k)
    if r.isOk and not r.get():
      return true
    await sleepAsync(chronos.milliseconds(2))
  return false

proc mkMsg(channelId: SdsChannelID, msgId: SdsMessageID, lamport: int64): SdsMessage =
  SdsMessage.init(
    messageId = msgId,
    lamportTimestamp = lamport,
    causalHistory = @[],
    channelId = channelId,
    content = @[byte(1), byte(2)],
    bloomFilter = @[],
  )

suite "SDS persistency adapter (0.3.0 snapshot model)":
  asyncTest "saveChannelMeta + updateHistory round-trip via loadChannel":
    let root = tmpRoot("roundtrip")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let job = p.openJob("sds").get()
    let persistence = newSdsPersistence(job)
    let channelId = "chan-1".SdsChannelID

    var meta = ChannelMeta.init()
    meta.lamportTimestamp = 42
    check (await persistence.saveChannelMeta(channelId, meta)).isOk
    check (await job.pollExists(CatMeta, toKey(channelId)))

    # append out of (lamport) order on purpose; loadChannel must sort.
    var upd = HistoryUpdate.init()
    upd.append = @[mkMsg(channelId, "m2", 2), mkMsg(channelId, "m1", 1)]
    check (await persistence.updateHistory(channelId, upd)).isOk
    check (await job.pollExists(CatLog, key(channelId, "m2")))

    let data = (await persistence.loadChannel(channelId)).valueOr:
      check false
      return
    check data.meta.lamportTimestamp == 42
    check data.messageHistory.len == 2
    check data.messageHistory[0].messageId == "m1"
    check data.messageHistory[1].messageId == "m2"

  asyncTest "loadChannel on a fresh channel returns empty ChannelData":
    let root = tmpRoot("empty")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let job = p.openJob("sds").get()
    let persistence = newSdsPersistence(job)

    let data = (await persistence.loadChannel("nope".SdsChannelID)).valueOr:
      check false
      return
    check data.meta.lamportTimestamp == 0
    check data.messageHistory.len == 0

  asyncTest "updateHistory evict removes a log row":
    let root = tmpRoot("evict")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let job = p.openJob("sds").get()
    let persistence = newSdsPersistence(job)
    let channelId = "c".SdsChannelID

    var upd = HistoryUpdate.init()
    upd.append = @[mkMsg(channelId, "a", 1), mkMsg(channelId, "b", 2)]
    check (await persistence.updateHistory(channelId, upd)).isOk
    check (await job.pollExists(CatLog, key(channelId, "b")))

    var ev = HistoryUpdate.init()
    ev.evict = @["a".SdsMessageID]
    check (await persistence.updateHistory(channelId, ev)).isOk
    check (await job.pollGone(CatLog, key(channelId, "a")))

    let data = (await persistence.loadChannel(channelId)).valueOr:
      check false
      return
    check data.messageHistory.len == 1
    check data.messageHistory[0].messageId == "b"

  asyncTest "dropChannel wipes meta and log":
    let root = tmpRoot("drop")
    defer:
      removeDir(root)
    let p = Persistency.instance(root).get()
    defer:
      Persistency.reset()
    let job = p.openJob("sds").get()
    let persistence = newSdsPersistence(job)
    let channelId = "d".SdsChannelID

    var meta = ChannelMeta.init()
    meta.lamportTimestamp = 7
    check (await persistence.saveChannelMeta(channelId, meta)).isOk
    var upd = HistoryUpdate.init()
    upd.append = @[mkMsg(channelId, "x", 1)]
    check (await persistence.updateHistory(channelId, upd)).isOk
    check (await job.pollExists(CatMeta, toKey(channelId)))
    check (await job.pollExists(CatLog, key(channelId, "x")))

    check (await persistence.dropChannel(channelId)).isOk
    check (await job.pollGone(CatMeta, toKey(channelId)))

    let data = (await persistence.loadChannel(channelId)).valueOr:
      check false
      return
    check data.meta.lamportTimestamp == 0
    check data.messageHistory.len == 0
