{.used.}

import std/times
import chronos, results, testutils/unittests
import brokers/[broker_context, request_broker]
import logos_delivery/waku/persistency/persistency
import logos_delivery/waku/rln/rln_evm/[message_id_store, nonce_manager, proof]
import logos_delivery/waku/rln/rln_evm/group_manager_base
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
      idCredentials: Opt.some(IdentityCredential(idSecretHash: secret))
    ),
    nonceManager: NonceManager.init(nonceLimit = 100),
    reserveLock: newAsyncLock(),
    rlnEpochSizeSec: TestEpochSizeSec,
    rlnMaxTimestampGap: 20,
    brokerCtx: ctx,
  )

proc currentEpoch(): uint64 =
  uint64(epochTime() / float64(TestEpochSizeSec))

suite "RLN message id store":
  test "storeKey is stable per identity and differs between identities":
    check:
      storeKey(@[1'u8, 2, 3]) == storeKey(@[1'u8, 2, 3])
      storeKey(@[1'u8, 2, 3]) != storeKey(@[1'u8, 2, 4])

  asyncTest "an identity with no row loads as none":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(RlnJobId).get()

    let loaded = await job.loadIds(storeKey(@[1'u8]))
    check:
      loaded.isOk()
      loaded.get().isNone()

  asyncTest "saveIds then loadIds round-trips, and a later save replaces the row":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(RlnJobId).get()
    let k = storeKey(@[1'u8])

    # Zero values are stored, not dropped: a released id 0 saves nextId 0.
    let saved1 = await job.saveIds(k, 7, 0)
    check saved1.isOk()
    let first = (await job.loadIds(k)).get().get()
    check:
      first.epochIndex == 7
      first.nextId == 0

    let saved2 = await job.saveIds(k, 8, 3)
    check saved2.isOk()
    let second = (await job.loadIds(k)).get().get()
    check:
      second.epochIndex == 8
      second.nextId == 3

  asyncTest "two identities on one job keep separate rows":
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    let job = p.openJob(RlnJobId).get()
    let a = storeKey(@[1'u8])
    let b = storeKey(@[2'u8])

    let savedA = await job.saveIds(a, 7, 4)
    let savedB = await job.saveIds(b, 9, 1)
    check:
      savedA.isOk()
      savedB.isOk()

    let rowA = (await job.loadIds(a)).get().get()
    let rowB = (await job.loadIds(b)).get().get()
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
    let k = storeKey(@[1'u8])

    # Written under the store's category ("rln") with bytes that are not a
    # message id row.
    let written = await job.putAcked("rln", k, @[0xff'u8, 0xff])
    check written.isOk()
    let loaded = await job.loadIds(k)
    check loaded.isErr()

  asyncTest "a closed job is an error, not an empty row":
    let p = Persistency.new(InMemoryStoragePath).get()
    let job = p.openJob(RlnJobId).get()
    p.close()

    let loaded = await job.loadIds(storeKey(@[1'u8]))
    let saved = await job.saveIds(storeKey(@[1'u8]), 7, 1)
    check:
      loaded.isErr()
      saved.isErr()

  test "openIdStore fails while no persistency is provided":
    let ctx = NewBrokerContext()
    check openIdStore(ctx).isErr()

  test "openIdStore opens the rln job of the provided persistency":
    let ctx = NewBrokerContext()
    let p = Persistency.new(InMemoryStoragePath).get()
    defer:
      p.close()
    discard GetPersistency.reprovideIt(ctx):
      ok(p)
    defer:
      GetPersistency.clearProvider(ctx)

    let job = openIdStore(ctx).get()
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

    let res = await rln.ensureIdsLoaded()
    check:
      res.isErr()
      res.error.kind == RlnErrorKind.NotReady
      rln.idStore.isNil()

  asyncTest "without a persistency it is NotReady, and a later call loads":
    let ctx = NewBrokerContext()
    let rln = testRlnEvm(ctx)

    let before = await rln.ensureIdsLoaded()
    check:
      before.isErr()
      before.error.kind == RlnErrorKind.NotReady
      rln.idStore.isNil()

    let p = providedStore(ctx)
    defer:
      p.close()
      GetPersistency.clearProvider(ctx)
    let after = await rln.ensureIdsLoaded()
    check:
      after.isOk()
      not rln.idStore.isNil()

  asyncTest "no stored row leaves the full budget":
    let ctx = NewBrokerContext()
    let p = providedStore(ctx)
    defer:
      p.close()
      GetPersistency.clearProvider(ctx)
    let rln = testRlnEvm(ctx)

    let res = await rln.ensureIdsLoaded()
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
    let saved = await job.saveIds(storeKey(@[1'u8]), epoch, 5)
    check saved.isOk()

    let res = await rln.ensureIdsLoaded()
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
    let saved = await job.saveIds(storeKey(@[1'u8]), epoch - 1, 7)
    check saved.isOk()

    let res = await rln.ensureIdsLoaded()
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
    let saved = await job.saveIds(storeKey(@[1'u8]), epoch + 3, 2)
    check saved.isOk()

    let res = await rln.ensureIdsLoaded()
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

    let first = await rln.ensureIdsLoaded()
    check first.isOk()

    # A row written after the load is not picked up by a second call.
    let job = p.openJob(RlnJobId).get()
    let saved = await job.saveIds(storeKey(@[1'u8]), epoch, 9)
    check saved.isOk()

    let second = await rln.ensureIdsLoaded()
    check:
      second.isOk()
      rln.nonceManager.reserve(epoch).get() == 0
