{.used.}

import std/[random, sequtils], testutils/unittests, chronos, results
import
  ../../logos_delivery/waku/waku_core,
  ../../logos_delivery/waku/waku_store_sync/common,
  ../../logos_delivery/waku/waku_store_sync/promises,
  ../testlib/wakucore,
  ./sync_utils

proc newIds(rng: var Rand, count: int): seq[SyncID] =
  toSeq(1 .. count).mapIt(SyncID(time: Timestamp(it), hash: rng.randomHash()))

proc newPeerId(): PeerId =
  PeerId.init(generateSecp256k1Key()).tryGet()

suite "Waku Sync: promises":
  var rng {.threadvar.}: Rand
  var peerA {.threadvar.}: PeerId
  var peerB {.threadvar.}: PeerId
  var t0 {.threadvar.}: Moment

  setup:
    rng = initRand(4765)
    peerA = newPeerId()
    peerB = newPeerId()
    t0 = Moment.now()

  test "a round stays pending while its peer delivers, and ends one timeout after":
    var promises = Promises.init(1.seconds, 10.seconds, 60.seconds)
    let ids = rng.newIds(3)
    check promises.promise(peerA, ids, t0) == ids

    discard promises.arrive(ids[0].hash, Opt.some(peerA), t0 + 800.milliseconds)
    check:
      promises.expire(t0 + 1799.milliseconds).ended.len == 0
      promises.isPending(ids[1].hash)

    check promises.expire(t0 + 1800.milliseconds).ended == ids[1 .. 2]
    check:
      not promises.isPending(ids[1].hash)
      promises.isWanted(ids[1].hash)

  test "a delivery of a later round ends the rounds before it":
    var promises = Promises.init(1.seconds, 10.seconds, 60.seconds)
    let
      first = rng.newIds(2)
      second = rng.newIds(2)
    discard promises.promise(peerA, first, t0)
    discard promises.promise(peerA, second, t0)

    discard promises.arrive(second[0].hash, Opt.some(peerA), t0 + 100.milliseconds)

    check:
      promises.expire(t0 + 200.milliseconds).ended == first
      promises.isPending(second[1].hash)

  test "a delivery of an earlier round keeps a later round pending":
    var promises = Promises.init(1.seconds, 10.seconds, 60.seconds)
    let
      first = rng.newIds(2)
      second = rng.newIds(2)
    discard promises.promise(peerA, first, t0)
    discard promises.promise(peerA, second, t0 + 500.milliseconds)

    discard promises.arrive(first[0].hash, Opt.some(peerA), t0 + 1400.milliseconds)

    check:
      promises.expire(t0 + 2399.milliseconds).ended.len == 0
      promises.isPending(second[0].hash)
      promises.expire(t0 + 2400.milliseconds).ended.len == 3

  test "an arrival by relay or from another peer does not keep a round pending":
    var promises = Promises.init(1.seconds, 10.seconds, 60.seconds)
    let ids = rng.newIds(3)
    discard promises.promise(peerA, ids, t0)

    discard promises.arrive(ids[0].hash, Opt.none(PeerId), t0 + 800.milliseconds)
    discard promises.arrive(ids[1].hash, Opt.some(peerB), t0 + 800.milliseconds)

    check promises.expire(t0 + 1.seconds).ended == @[ids[2]]

  test "a round ends at maxPending, also while its peer delivers":
    var promises = Promises.init(1.seconds, 6.seconds, 60.seconds)
    let ids = rng.newIds(2)
    discard promises.promise(peerA, ids, t0)

    discard promises.arrive(ids[0].hash, Opt.some(peerA), t0 + 5400.milliseconds)

    check:
      promises.expire(t0 + 5999.milliseconds).ended.len == 0
      promises.expire(t0 + 6.seconds).ended == @[ids[1]]

  test "an ended round is wanted until the accept window ends":
    var promises = Promises.init(1.seconds, 6.seconds, 10.seconds)
    let ids = rng.newIds(2)
    discard promises.promise(peerA, ids, t0)
    check promises.expire(t0 + 1.seconds).ended == ids

    check:
      promises.arrive(ids[0].hash, Opt.some(peerA), t0 + 2.seconds) == Arrival.Late
      promises.arrive(ids[0].hash, Opt.some(peerA), t0 + 2.seconds) == Arrival.Unwanted
      promises.expire(t0 + 9999.milliseconds).dropped.len == 0
      promises.isWanted(ids[1].hash)
      promises.expire(t0 + 10.seconds).dropped == @[ids[1].hash]
      not promises.isWanted(ids[1].hash)

  test "a peer that let an element go cannot make it pending again":
    var promises = Promises.init(1.seconds, 6.seconds, 60.seconds)
    let ids = rng.newIds(1)
    discard promises.promise(peerA, ids, t0)
    check promises.expire(t0 + 1.seconds).ended == ids

    check:
      promises.promise(peerA, ids, t0 + 2.seconds).len == 0
      promises.isWanted(ids[0].hash)
      not promises.isPending(ids[0].hash)
      promises.promise(peerB, ids, t0 + 3.seconds) == ids
      promises.isPending(ids[0].hash)
