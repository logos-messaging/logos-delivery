{.used.}

import chronos, results, testutils/unittests
import brokers/[broker_context, request_broker]
import logos_delivery/waku/persistency/persistency
import logos_delivery/waku/rln/rln_evm/message_id_store

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
