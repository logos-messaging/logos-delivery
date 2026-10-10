{.used.}

import std/times
import chronos, results, testutils/unittests
import brokers/[broker_context, request_broker]
import logos_delivery/waku/persistency/persistency
import logos_delivery/waku/rln/rln_evm/[message_id_store, nonce_manager, proof, rln_evm]
import logos_delivery/waku/rln/rln_evm/group_manager_base
import logos_delivery/waku/rln/rln_plugin
import logos_delivery/waku/rln/rln_evm/types as rln_evm_types
import logos_delivery/waku/rln/types as rln_api_types

const TestEpochSizeSec = 3600'u64
  ## Long epochs, so a test does not cross a boundary between computing the
  ## current epoch and loading the store.

proc providedStore(ctx: BrokerContext): Persistency =
  ## An in-memory persistency provided under `ctx`, as `Waku.start` provides
  ## the node's.
  let p = Persistency.new(InMemoryStoragePath).get()
  discard GetPersistency.reprovideIt(ctx):
    ok(p)
  return p

proc testRlnEvm(ctx: BrokerContext, secret: seq[byte] = @[1'u8]): RlnEvm =
  ## An EVM backend with an identity credential and no chain connection:
  ## enough for the message id store.
  RlnEvm(
    groupManager: RlnEvmGroupManagerBase(
      idCredentials: Opt.some(IdentityCredential(idSecretHash: secret)),
      userMessageLimit: Opt.some(UserMessageLimit(100)),
    ),
    nonceManager: NonceManager.init(nonceLimit = 100),
    reserveLock: newAsyncLock(),
    rlnEpochSizeSec: TestEpochSizeSec,
    rlnMaxTimestampGap: 20,
    brokerCtx: Opt.some(ctx),
  )

proc currentEpoch(): uint64 =
  uint64(epochTime() / float64(TestEpochSizeSec))

suite "RLN message id store":
  test "messageIdKey is stable per identity and differs between identities":
    check:
      messageIdKey(@[1'u8, 2, 3]) == messageIdKey(@[1'u8, 2, 3])
      messageIdKey(@[1'u8, 2, 3]) != messageIdKey(@[1'u8, 2, 4])

  asyncTest "an identity with no row loads as none":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(RlnJobId).get()

    let loaded = await job.loadMessageIds(messageIdKey(@[1'u8]))
    check:
      loaded.isOk()
      loaded.get().isNone()

  asyncTest "saveMessageIds then loadMessageIds round-trips, and a later save replaces the row":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(RlnJobId).get()
    let k = messageIdKey(@[1'u8])

    # Proto3 does not write a `nextId` of 0, and the decode reads the missing
    # field as 0. A `release` of id 0 saves `nextId` 0.
    let saved1 = await job.saveMessageIds(k, 7, 0)
    check saved1.isOk()
    let first = (await job.loadMessageIds(k)).get().get()
    check:
      first.epochIndex == 7
      first.nextId == 0

    let saved2 = await job.saveMessageIds(k, 8, 3)
    check saved2.isOk()
    let second = (await job.loadMessageIds(k)).get().get()
    check:
      second.epochIndex == 8
      second.nextId == 3

  asyncTest "a row that the minprotobuf codec stored loads with the same values":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(RlnJobId).get()
    let k = messageIdKey(@[1'u8])

    # The bytes that the `minprotobuf` codec wrote. Field 1 (epoch index) is 8.
    # Field 2 (next id) is 3, or an explicit 0.
    check (await job.putAcked("rln", k, @[0x08'u8, 0x08, 0x10, 0x03])).isOk()
    let first = (await job.loadMessageIds(k)).get(Opt.none(StoredMessageIds))
    check (await job.putAcked("rln", k, @[0x08'u8, 0x08, 0x10, 0x00])).isOk()
    let second = (await job.loadMessageIds(k)).get(Opt.none(StoredMessageIds))
    check:
      first == Opt.some(StoredMessageIds(epochIndex: 8, nextId: 3))
      second == Opt.some(StoredMessageIds(epochIndex: 8, nextId: 0))

    # The new codec writes the same bytes for values that are not zero.
    check:
      (await job.saveMessageIds(k, 8, 3)).isOk()
      (await job.get("rln", k)).get() == Opt.some(@[0x08'u8, 0x08, 0x10, 0x03])

  asyncTest "two identities on one job keep separate rows":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(RlnJobId).get()
    let a = messageIdKey(@[1'u8])
    let b = messageIdKey(@[2'u8])

    let savedA = await job.saveMessageIds(a, 7, 4)
    let savedB = await job.saveMessageIds(b, 9, 1)
    check:
      savedA.isOk()
      savedB.isOk()

    let rowA = (await job.loadMessageIds(a)).get().get()
    let rowB = (await job.loadMessageIds(b)).get().get()
    check:
      rowA.epochIndex == 7
      rowA.nextId == 4
      rowB.epochIndex == 9
      rowB.nextId == 1

  asyncTest "a row that does not decode is an error":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(RlnJobId).get()
    let k = messageIdKey(@[1'u8])

    # Written under the store's category ("rln") with bytes that are not a
    # message id row.
    let written = await job.putAcked("rln", k, @[0xff'u8, 0xff])
    check written.isOk()
    let loaded = await job.loadMessageIds(k)
    check loaded.isErr()

  asyncTest "a row without an epoch index is an error, not epoch 0":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(RlnJobId).get()
    let k = messageIdKey(@[1'u8])

    # Proto3 decodes an absent field as zero. This row has only `nextId` 5.
    let written = await job.putAcked("rln", k, @[0x10'u8, 0x05])
    check written.isOk()
    let loaded = await job.loadMessageIds(k)
    check loaded.isErr()

  asyncTest "a row without a next id is an error, not id 0":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(RlnJobId).get()
    let k = messageIdKey(@[1'u8])

    # This row has only `epochIndex` 5. A next id of 0 can reuse an id.
    let written = await job.putAcked("rln", k, @[0x08'u8, 0x05])
    check written.isOk()
    let loaded = await job.loadMessageIds(k)
    check loaded.isErr()

  asyncTest "a next id of 0 is stored and loads as 0":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(RlnJobId).get()
    let k = messageIdKey(@[1'u8])

    # A released id can lower the next id to 0, and the row keeps the field.
    check (await job.saveMessageIds(k, 7, 0)).isOk()
    let loaded = await job.loadMessageIds(k)
    check:
      loaded.isOk()
      loaded.get().isSome()
      loaded.get().get().epochIndex == 7
      loaded.get().get().nextId == 0

  asyncTest "a closed job is an error, not an empty row":
    let p = Persistency.new(InMemoryStoragePath).get()
    let job = p.openJob(RlnJobId).get()
    p.close()

    let loaded = await job.loadMessageIds(messageIdKey(@[1'u8]))
    let saved = await job.saveMessageIds(messageIdKey(@[1'u8]), 7, 1)
    check:
      loaded.isErr()
      saved.isErr()

  test "openMessageIdStore fails while no persistency is provided":
    let ctx = NewBrokerContext()
    check openMessageIdStore(ctx).isErr()

  test "openMessageIdStore opens the rln job of the provided persistency":
    let ctx = NewBrokerContext()
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    discard GetPersistency.reprovideIt(ctx):
      ok(p)
    defer:
      GetPersistency.clearProvider(ctx)

    let job = openMessageIdStore(ctx).get()
    check:
      job.id == RlnJobId
      p.hasJob(RlnJobId)

suite "RLN EVM: loading the message id store":
  asyncTest "without an identity credential it is NotReady":
    let ctx = NewBrokerContext()
    let p = providedStore(ctx)
    defer:
      p.close()
      GetPersistency.clearProvider(ctx)
    let rln = testRlnEvm(ctx)
    rln.groupManager.idCredentials = Opt.none(IdentityCredential)

    let res = await rln.ensureMessageIdsLoaded()
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady
      rln.messageIdStore.isNil()

  asyncTest "without a persistency it is NotReady, and a later call loads":
    let ctx = NewBrokerContext()
    let rln = testRlnEvm(ctx)

    let before = await rln.ensureMessageIdsLoaded()
    check:
      before.isErr()
      before.error.kind == RlnErrorKind.NotReady
      rln.messageIdStore.isNil()

    let p = providedStore(ctx)
    defer:
      p.close()
      GetPersistency.clearProvider(ctx)
    let after = await rln.ensureMessageIdsLoaded()
    check:
      after.isOk()
      not rln.messageIdStore.isNil()

  asyncTest "no stored row leaves the full budget":
    let ctx = NewBrokerContext()
    let p = providedStore(ctx)
    defer:
      p.close()
      GetPersistency.clearProvider(ctx)
    let rln = testRlnEvm(ctx)

    let res = await rln.ensureMessageIdsLoaded()
    check:
      res.isOk()
      rln.nonceManager.spent(currentEpoch()) == 0
      rln.refusedUntil == 0
      rln.nonceManager.reserve(currentEpoch()).get() == 0

  asyncTest "a row for the current epoch resumes at its next id":
    let ctx = NewBrokerContext()
    let p = providedStore(ctx)
    defer:
      p.close()
      GetPersistency.clearProvider(ctx)
    let rln = testRlnEvm(ctx)
    let epoch = currentEpoch()
    let job = p.openJob(RlnJobId).get()
    let saved = await job.saveMessageIds(messageIdKey(@[1'u8]), epoch, 5)
    check saved.isOk()

    let res = await rln.ensureMessageIdsLoaded()
    check:
      res.isOk()
      rln.refusedUntil == 0
      rln.nonceManager.reserve(epoch).get() == 5

  asyncTest "a row for an earlier epoch starts the current epoch fresh":
    let ctx = NewBrokerContext()
    let p = providedStore(ctx)
    defer:
      p.close()
      GetPersistency.clearProvider(ctx)
    let rln = testRlnEvm(ctx)
    let epoch = currentEpoch()
    let job = p.openJob(RlnJobId).get()
    let saved = await job.saveMessageIds(messageIdKey(@[1'u8]), epoch - 1, 7)
    check saved.isOk()

    let res = await rln.ensureMessageIdsLoaded()
    check:
      res.isOk()
      rln.refusedUntil == 0
      rln.nonceManager.reserve(epoch).get() == 0

  asyncTest "a row ahead of the clock sets refusedUntil and refuses earlier epochs":
    let ctx = NewBrokerContext()
    let p = providedStore(ctx)
    defer:
      p.close()
      GetPersistency.clearProvider(ctx)
    let rln = testRlnEvm(ctx)
    let epoch = currentEpoch()
    let job = p.openJob(RlnJobId).get()
    let saved = await job.saveMessageIds(messageIdKey(@[1'u8]), epoch + 3, 2)
    check saved.isOk()

    let res = await rln.ensureMessageIdsLoaded()
    let draw = rln.nonceManager.reserve(epoch)
    check:
      res.isOk()
      rln.refusedUntil == epoch + 3
      draw.isErr()
      draw.error.kind == RlnErrorKind.Permanent

  asyncTest "a loaded store is not read again":
    let ctx = NewBrokerContext()
    let p = providedStore(ctx)
    defer:
      p.close()
      GetPersistency.clearProvider(ctx)
    let rln = testRlnEvm(ctx)
    let epoch = currentEpoch()

    let first = await rln.ensureMessageIdsLoaded()
    check first.isOk()

    # A row written after the load is not picked up by a second call.
    let job = p.openJob(RlnJobId).get()
    let saved = await job.saveMessageIds(messageIdKey(@[1'u8]), epoch, 9)
    check saved.isOk()

    let second = await rln.ensureMessageIdsLoaded()
    check:
      second.isOk()
      rln.nonceManager.reserve(epoch).get() == 0

suite "RLN EVM: epoch quota from the message id store":
  asyncTest "the quota counts ids saved before a restart":
    let ctx = NewBrokerContext()
    let p = providedStore(ctx)
    defer:
      p.close()
      GetPersistency.clearProvider(ctx)
    let job = p.openJob(RlnJobId).get()
    let saved = await job.saveMessageIds(messageIdKey(@[1'u8]), currentEpoch(), 5)
    check saved.isOk()

    let plugin = testRlnEvm(ctx).toRlnPlugin()
    let quota = (await plugin.getEpochQuota(uint64(epochTime()))).get()
    check:
      quota.rateLimit == 100
      quota.remaining == 95

  asyncTest "a stored epoch ahead of the clock leaves earlier epochs without budget":
    let ctx = NewBrokerContext()
    let p = providedStore(ctx)
    defer:
      p.close()
      GetPersistency.clearProvider(ctx)
    let epoch = currentEpoch()
    let job = p.openJob(RlnJobId).get()
    let saved = await job.saveMessageIds(messageIdKey(@[1'u8]), epoch + 3, 2)
    check saved.isOk()

    let plugin = testRlnEvm(ctx).toRlnPlugin()
    let now = (await plugin.getEpochQuota(uint64(epochTime()))).get()
    let stored = (await plugin.getEpochQuota((epoch + 3) * TestEpochSizeSec)).get()
    check:
      now.remaining == 0
      stored.remaining == 98

  asyncTest "the quota is NotReady while the store cannot load":
    let ctx = NewBrokerContext()
    let plugin = testRlnEvm(ctx).toRlnPlugin()

    let quota = await plugin.getEpochQuota(uint64(epochTime()))
    check:
      quota.isErr()
      quota.error.kind == RlnErrorKind.NotReady
