{.used.}

import
  results,
  std/net,
  testutils/unittests,
  chronos,
  libp2p/[switch, peerId, crypto/crypto],
  eth/[common/keys, p2p/discoveryv5/enr],
  brokers/broker_context

import
  logos_delivery/waku/[
    waku_node,
    node/peer_manager,
    discovery/waku_discv5,
    waku_peer_exchange/protocol,
    common/enr/builder,
  ],
  ../testlib/[wakucore, wakunode, testasync],
  ./utils.nim

proc testRecord(): enr.Record =
  var builder = EnrBuilder.init(generateSecp256k1Key())
  builder.withIpAddressAndPorts(
    Opt.some(parseIpAddress("127.0.0.1")), Opt.some(Port(60000)), Opt.none(Port)
  )
  return builder.build().expect("valid ENR")

proc walkOf(records: seq[enr.Record]): PxRandomWalk =
  return proc(): Future[seq[enr.Record]] {.async: (raises: [CancelledError]).} =
    return records

suite "Waku Peer Exchange - cache liveness":
  asyncTest "Only the cached peers that answer a ping are served":
    let
      wpx = WakuPeerExchange.new(PeerManager.new(newTestSwitch()))
      alive = testRecord()
      gone = testRecord()
    proc answersIfAlive(
        record: enr.Record
    ): Future[bool] {.async: (raises: [CancelledError]).} =
      return record == alive

    wpx.startCacheRefresh(walkOf(@[alive, gone]), answersIfAlive)
    defer:
      await wpx.stopCacheRefresh()

    checkUntilTimeout:
      wpx.cacheLen() == 1
    check:
      wpx.getEnrsFromCache(uint64.high) == @[alive]

  asyncTest "A cached peer is not served before it answers its ping":
    let
      wpx = WakuPeerExchange.new(PeerManager.new(newTestSwitch()))
      record = testRecord()
      pong = Future[bool].Raising([CancelledError]).init()
      pinged = newFuture[void]()
    proc answersOnRelease(
        r: enr.Record
    ): Future[bool] {.async: (raises: [CancelledError]).} =
      pinged.complete()
      return await pong

    wpx.startCacheRefresh(walkOf(@[record]), answersOnRelease)
    defer:
      await wpx.stopCacheRefresh()

    await pinged
    check:
      wpx.cacheLen() == 1
      wpx.getEnrsFromCache(uint64.high).len == 0

    pong.complete(true)
    checkUntilTimeout:
      wpx.getEnrsFromCache(uint64.high) == @[record]

  asyncTest "A discv5 ping answers for a running node and fails once it stops":
    lockNewGlobalBrokerContext:
      let
        bindIp = parseIpAddress("0.0.0.0")
        nodeKey1 = generateSecp256k1Key()
        node1 = newTestWakuNode(nodeKey1, bindIp, Port(0))
        nodeKey2 = generateSecp256k1Key()
        node2 = newTestWakuNode(nodeKey2, bindIp, Port(0))
      await allFutures(node1.start(), node2.start())
      defer:
        await allFutures(node1.stop(), node2.stop())

      let disc1 = (
        await startDiscv5WithAutoPort(node1, keys.PrivateKey(nodeKey1.skkey), bindIp)
      ).valueOr:
        raiseAssert "disc1: " & error
      defer:
        await disc1.stop()
      let disc2 = (
        await startDiscv5WithAutoPort(node2, keys.PrivateKey(nodeKey2.skkey), bindIp)
      ).valueOr:
        raiseAssert "disc2: " & error
      let record2 = disc2.protocol.getRecord()
      let pingFromDisc1 = disc1.discv5Ping()

      check:
        await pingFromDisc1(record2)

      await disc2.stop()
      check:
        not (await pingFromDisc1(record2))

  asyncTest "A discv5 ping fails for a record with no UDP endpoint":
    lockNewGlobalBrokerContext:
      let
        bindIp = parseIpAddress("0.0.0.0")
        nodeKey = generateSecp256k1Key()
        node = newTestWakuNode(nodeKey, bindIp, Port(0))
      await node.start()
      defer:
        await node.stop()
      let disc = (
        await startDiscv5WithAutoPort(node, keys.PrivateKey(nodeKey.skkey), bindIp)
      ).valueOr:
        raiseAssert "disc: " & error
      defer:
        await disc.stop()

      check:
        not (await disc.discv5Ping()(testRecord()))
