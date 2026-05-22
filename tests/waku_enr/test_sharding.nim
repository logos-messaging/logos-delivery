{.used.}

import
  stew/results,
  chronos,
  testutils/unittests,
  libp2p/crypto/crypto as libp2p_keys,
  eth/keys as eth_keys

import
  waku/[waku_enr, discovery/waku_discv5, waku_core, common/enr],
  ../testlib/wakucore,
  ../waku_discv5/utils,
  ./utils

suite "Sharding":
  suite "topicsToRelayShards":
    asyncTest "get shards from topics":
      ## Given
      let mixedTopics = @["/waku/2/thisisatest", "/waku/2/rs/0/2", "/waku/2/rs/0/8"]
      let shardedTopics = @["/waku/2/rs/0/2", "/waku/2/rs/0/4", "/waku/2/rs/0/8"]
      let namedTopics =
        @["/waku/2/thisisatest", "/waku/2/atestthisis", "/waku/2/isthisatest"]
      let gibberish =
        @["aedyttydcb/uioasduyio", "jhdfsjhlsdfjhk/sadjhk", "khfsd/hjfdsgjh/dfs"]
      let empty: seq[string] = @[]

      let shardsTopics =
        RelayShards.init(0, @[uint16(2), uint16(4), uint16(8)]).expect("Valid shardIds")

      ## When

      let mixedRes = topicsToRelayShards(mixedTopics)
      let shardedRes = topicsToRelayShards(shardedTopics)
      let namedRes = topicsToRelayShards(namedTopics)
      let gibberishRes = topicsToRelayShards(gibberish)
      let emptyRes = topicsToRelayShards(empty)

      ## Then
      assert mixedRes.isErr(), $mixedRes.value
      assert shardedRes.isOk(), shardedRes.error
      assert shardedRes.value.isSome()
      assert shardedRes.value.get() == shardsTopics, $shardedRes.value.get()
      assert namedRes.isOk(), namedRes.error
      assert namedRes.value.isNone(), $namedRes.value
      assert gibberishRes.isErr(), $gibberishRes.value
      assert emptyRes.isOk(), emptyRes.error
      assert emptyRes.value.isNone(), $emptyRes.value

  suite "containsShard":
    asyncTest "update ENR from subscriptions":
      ## Given
      let
        shard1 = "/waku/2/rs/0/1"
        shard2 = "/waku/2/rs/0/2"
        shard3 = "/waku/2/rs/0/3"
        privKey = generateSecp256k1Key()
        bindIp = "0.0.0.0"
        extIp = "127.0.0.1"
        tcpPort = 61500u16
        udpPort = 9000u16

      let record = newTestEnrRecord(
        privKey = privKey, extIp = extIp, tcpPort = tcpPort, udpPort = udpPort
      )

      let queue = newAsyncEventQueue[SubscriptionEvent](30)

      let node = newTestDiscv5(
        privKey = privKey,
        bindIp = bindIp,
        tcpPort = tcpPort,
        udpPort = udpPort,
        record = record,
        queue = queue,
      )

      let res = await node.start()
      assert res.isOk(), res.error

      ## Then
      queue.emit((kind: PubsubSub, topic: shard1))
      queue.emit((kind: PubsubSub, topic: shard2))
      queue.emit((kind: PubsubSub, topic: shard3))

      await sleepAsync(1.seconds)

      check:
        node.protocol.localNode.record.containsShard(shard1) == true
        node.protocol.localNode.record.containsShard(shard2) == true
        node.protocol.localNode.record.containsShard(shard3) == true

      queue.emit((kind: PubsubSub, topic: shard1))
      queue.emit((kind: PubsubSub, topic: shard2))
      queue.emit((kind: PubsubSub, topic: shard3))

      await sleepAsync(1.seconds)

      check:
        node.protocol.localNode.record.containsShard(shard1) == true
        node.protocol.localNode.record.containsShard(shard2) == true
        node.protocol.localNode.record.containsShard(shard3) == true

      queue.emit((kind: PubsubUnsub, topic: shard1))
      queue.emit((kind: PubsubUnsub, topic: shard2))

      await sleepAsync(1.seconds)

      check:
        node.protocol.localNode.record.containsShard(shard1) == false
        node.protocol.localNode.record.containsShard(shard2) == false
        node.protocol.localNode.record.containsShard(shard3) == true

      ## Cleanup
      await node.stop()

suite "Discovery Mechanisms for Shards":
  test "Index List Representation":
    # Given a valid index list and its representation
    let
      indicesList: seq[uint8] = @[0, 73, 2, 0, 1, 0, 10]
      clusterId: uint16 = 73 # bitVector's clusterId
      shardIds: seq[uint16] = @[1u16, 10u16] # bitVector's shardIds

    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    # When building an ENR with the index list
    var builder = EnrBuilder.init(enrPrivKey, enrSeqNum)
    builder.addFieldPair(ShardingIndicesListEnrField, indicesList)
    let
      record = builder.build().tryGet()
      relayShards = record.toTyped().tryGet().relayShardingIndicesList().get()

    # Then the ENR should be correctly parsed
    check:
      relayShards == RelayShards.init(clusterId, shardIds).expect("Valid Shards")

  test "Bit Vector Representation":
    # Given a valid bit vector and its representation
    let
      bitVector: seq[byte] = @[
        0, 73, 2, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ]
      clusterId: uint16 = 73 # bitVector's clusterId
      shardIds: seq[uint16] = @[1u16, 10u16] # bitVector's shardIds

    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    # When building an ENR with the bit vector
    var builder = EnrBuilder.init(enrPrivKey, enrSeqNum)
    builder.addFieldPair(ShardingBitVectorEnrField, bitVector)
    let
      record = builder.build().tryGet()
      relayShards = record.toTyped().tryGet().relayShardingBitVector().get()

    # Then the ENR should be correctly parsed
    check:
      relayShards == RelayShards.init(clusterId, shardIds).expect("Valid Shards")
