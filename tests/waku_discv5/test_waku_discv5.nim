{.used.}

import
  std/[sequtils, algorithm, options, net],
  results,
  chronos,
  chronicles,
  testutils/unittests,
  libp2p/crypto/crypto as libp2p_keys,
  eth/keys as eth_keys,
  eth/enr/enr as ethEnr,
  libp2p/crypto/secp,
  libp2p/protocols/rendezvous

import
  waku/[
    waku_core/topics,
    waku_core/codecs,
    waku_enr,
    discovery/waku_discv5,
    waku_enr/capabilities,
    factory/conf_builder/conf_builder,
    factory/waku,
    node/waku_node,
    node/kernel_api,
    node/peer_manager,
  ],
  ../testlib/[wakucore, testasync, assertions, futures, wakunode, testutils],
  ../waku_enr/utils,
  ./utils as discv5_utils

suite "Waku Discovery v5":
  const validEnr =
    "enr:-K64QGAvsATunmvMT5c3LFjKS0tG39zlQ1195Z2pWu6RoB5fWP3EXz9QPlRXN" &
    "wOtDoRLgm4bATUB53AC8uml-ZtUE_kBgmlkgnY0gmlwhApkZgOKbXVsdGlhZGRyc4" &
    "CCcnOTAAAIAAAAAQACAAMABAAFAAYAB4lzZWNwMjU2azGhAwG-CMmXpAPj84f6dCt" &
    "MZ6xVYOa6bdmgAiKYG6LKGQlbg3RjcILqYIV3YWt1MgE"

  let
    rng = eth_keys.newRng()
    pk1 = eth_keys.PrivateKey.random(rng[])
    pk2 = eth_keys.PrivateKey.random(rng[])

  suite "shardingPredicate":
    var
      recordCluster21 {.threadvar.}: Record
      recordCluster22Indices1 {.threadvar.}: Record
      recordCluster22Indices2 {.threadvar.}: Record

    asyncSetup:
      recordCluster21 = block:
        let
          enrSeqNum = 1u64
          enrPrivKey = generatesecp256k1key()

        let
          clusterId: uint16 = 21
          shardIds: seq[uint16] = @[1u16, 2u16, 5u16, 7u16, 9u16, 11u16]

        let shardsTopics =
          RelayShards.init(clusterId, shardIds).expect("Valid shardIds")

        var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
        require builder.withWakuRelaySharding(shardsTopics).isOk()
        builder.withWakuCapabilities(Capabilities.Relay)

        let recordRes = builder.build()
        require recordRes.isOk()
        recordRes.tryGet()

      recordCluster22Indices1 = block:
        let
          enrSeqNum = 1u64
          enrPrivKey = generatesecp256k1key()

        let
          clusterId: uint16 = 22
          shardIds: seq[uint16] = @[2u16, 4u16, 5u16, 8u16, 10u16, 12u16]

        let shardsTopics =
          RelayShards.init(clusterId, shardIds).expect("Valid shardIds")

        var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
        require builder.withWakuRelaySharding(shardsTopics).isOk()
        builder.withWakuCapabilities(Capabilities.Relay)

        let recordRes = builder.build()
        require recordRes.isOk()
        recordRes.tryGet()

      recordCluster22Indices2 = block:
        let
          enrSeqNum = 1u64
          enrPrivKey = generatesecp256k1key()

        let
          clusterId: uint16 = 22
          shardIds: seq[uint16] = @[1u16, 3u16, 6u16, 7u16, 9u16, 11u16]

        let shardsTopics =
          RelayShards.init(clusterId, shardIds).expect("Valid shardIds")

        var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
        require builder.withWakuRelaySharding(shardsTopics).isOk()
        builder.withWakuCapabilities(Capabilities.Relay)

        let recordRes = builder.build()
        require recordRes.isOk()
        recordRes.tryGet()

    asyncTest "filter peer per contained shard":
      # When
      let predicateCluster21Op = shardingPredicate(recordCluster21)
      require predicateCluster21Op.isSome()
      let predicateCluster21 = predicateCluster21Op.get()

      let predicateCluster22Op = shardingPredicate(recordCluster22Indices1)
      require predicateCluster22Op.isSome()
      let predicateCluster22 = predicateCluster22Op.get()

      # Then
      check:
        predicateCluster21(recordCluster21) == true
        predicateCluster21(recordCluster22Indices1) == false
        predicateCluster21(recordCluster22Indices2) == false
        predicateCluster22(recordCluster21) == false
        predicateCluster22(recordCluster22Indices1) == true
        predicateCluster22(recordCluster22Indices2) == false

    asyncTest "filter peer per bootnode":
      let
        enrRelay = initRecord(
            1,
            pk2,
            {"waku2": @[1.byte], "rs": @[0.byte, 1.byte, 1.byte, 0.byte, 1.byte]},
          )
          .value()
        enrNoCapabilities =
          initRecord(1, pk1, {"rs": @[0.byte, 0.byte, 1.byte, 0.byte, 0.byte]}).value()
        predicateNoCapabilities =
          shardingPredicate(enrNoCapabilities, @[enrNoCapabilities]).get()
        predicateNoCapabilitiesWithBoth =
          shardingPredicate(enrNoCapabilities, @[enrNoCapabilities, enrRelay]).get()

      check:
        predicateNoCapabilities(enrNoCapabilities) == true
        predicateNoCapabilities(enrRelay) == false
        predicateNoCapabilitiesWithBoth(enrNoCapabilities) == true
        predicateNoCapabilitiesWithBoth(enrRelay) == true

      let
        predicateRelay = shardingPredicate(enrRelay, @[enrRelay]).get()
        predicateRelayWithBoth =
          shardingPredicate(enrRelay, @[enrRelay, enrNoCapabilities]).get()

      check:
        predicateRelay(enrNoCapabilities) == false
        predicateRelay(enrRelay) == true
        predicateRelayWithBoth(enrNoCapabilities) == true
        predicateRelayWithBoth(enrRelay) == true

    asyncTest "does not conform to typed record":
      let
        record = ethEnr.Record(raw: @[])
        predicateRecord = shardingPredicate(record, @[])

      check:
        predicateRecord.isNone()

    asyncTest "no relay sharding info":
      let
        enrNoShardingInfo = initRecord(1, pk1, {"waku2": @[1.byte]}).value()
        predicateNoShardingInfo =
          shardingPredicate(enrNoShardingInfo, @[enrNoShardingInfo])

      check:
        predicateNoShardingInfo.isNone()

  suite "findRandomPeers":
    proc buildNode(
        tcpPort: uint16,
        udpPort: uint16,
        bindIp: string = "0.0.0.0",
        extIp: string = "127.0.0.1",
        indices: seq[uint64] = @[],
        recordFlags: Option[CapabilitiesBitfield] = none(CapabilitiesBitfield),
        bootstrapRecords: seq[waku_enr.Record] = @[],
    ): (WakuDiscoveryV5, Record) {.raises: [ValueError, LPError].} =
      let
        privKey = generateSecp256k1Key()
        record = newTestEnrRecord(
          privKey = privKey,
          extIp = extIp,
          tcpPort = tcpPort,
          udpPort = udpPort,
          indices = indices,
          flags = recordFlags,
        )
        node = discv5_utils.newTestDiscv5(
          privKey = privKey,
          bindIp = bindIp,
          tcpPort = tcpPort,
          udpPort = udpPort,
          record = record,
          bootstrapRecords = bootstrapRecords,
        )

      (node, record)

    asyncTest "find random peers without predicate":
      # Given 3 nodes
      let
        (node1, record1) = buildNode(tcpPort = 61500u16, udpPort = 9000u16)
        (node2, record2) = buildNode(tcpPort = 61502u16, udpPort = 9002u16)
        (node3, record3) = buildNode(
          tcpPort = 61504u16, udpPort = 9004u16, bootstrapRecords = @[record1, record2]
        )

      let res1 = await node1.start()
      assertResultOk res1

      let res2 = await node2.start()
      assertResultOk res2

      let res3 = await node3.start()
      assertResultOk res3

      await sleepAsync(FUTURE_TIMEOUT)

      ## When we find random peers
      let res = await node3.findRandomPeers()

      var tcpPortList = res.mapIt(it.toTypedRecord().value().tcp.get())
      tcpPortList.sort()

      ## Then
      check:
        res.len == 2
        tcpPortList == @[61500, 61502]

      ## Cleanup
      await allFutures(node1.stop(), node2.stop(), node3.stop())

    asyncTest "find random peers with parameter predicate":
      let filterForStore: WakuDiscv5Predicate = proc(record: waku_enr.Record): bool =
        let typedRecord = record.toTyped()
        if typedRecord.isErr():
          return false

        let capabilities = typedRecord.value.waku2
        if capabilities.isNone():
          return false

        return capabilities.get().supportsCapability(Capabilities.Store)

      # Given 4 nodes
      let
        (node3, record3) = buildNode(
          tcpPort = 61504u16,
          udpPort = 9004u16,
          recordFlags =
            some(CapabilitiesBitfield.init(Capabilities.Relay, Capabilities.Filter)),
        )
        (node4, record4) = buildNode(
          tcpPort = 61506u16,
          udpPort = 9006u16,
          recordFlags =
            some(CapabilitiesBitfield.init(Capabilities.Relay, Capabilities.Store)),
        )
        (node2, record2) = buildNode(
          tcpPort = 61502u16,
          udpPort = 9002u16,
          recordFlags =
            some(CapabilitiesBitfield.init(Capabilities.Relay, Capabilities.Store)),
          bootstrapRecords = @[record3, record4],
        )
        (node1, record1) = buildNode(
          tcpPort = 61500u16,
          udpPort = 9000u16,
          recordFlags = some(CapabilitiesBitfield.init(Capabilities.Relay)),
          bootstrapRecords = @[record2],
        )

      # Start nodes' discoveryV5 protocols
      let res1 = await node1.start()
      assertResultOk res1

      let res2 = await node2.start()
      assertResultOk res2

      let res3 = await node3.start()
      assertResultOk res3

      let res4 = await node4.start()
      assertResultOk res4

      await sleepAsync(FUTURE_TIMEOUT)

      ## When
      let peers = await node1.findRandomPeers(some(filterForStore))

      ## Then
      check:
        peers.len >= 1
        peers.allIt(it.supportsCapability(Capabilities.Store))

      # Cleanup
      await allFutures(node1.stop(), node2.stop(), node3.stop(), node4.stop())

    xasyncTest "find random peers with instance predicate":
      ## This is skipped because is flaky and made CI randomly fail but is useful to run manually

      ## Setup
      # Records
      let
        (node3, record3) = buildNode(
          tcpPort = 61504u16,
          udpPort = 9004u16,
          recordFlags =
            some(CapabilitiesBitfield.init(Capabilities.Relay, Capabilities.Filter)),
        )
        (node4, record4) = buildNode(
          tcpPort = 61506u16,
          udpPort = 9006u16,
          recordFlags =
            some(CapabilitiesBitfield.init(Capabilities.Relay, Capabilities.Store)),
        )
        (node2, record2) = buildNode(
          tcpPort = 61502u16,
          udpPort = 9002u16,
          recordFlags =
            some(CapabilitiesBitfield.init(Capabilities.Relay, Capabilities.Store)),
          bootstrapRecords = @[record3, record4],
        )
      let (node1, record1) = buildNode(
        tcpPort = 61500u16,
        udpPort = 9000u16,
        recordFlags = some(CapabilitiesBitfield.init(Capabilities.Relay)),
        indices = @[0u64, 0u64, 1u64, 0u64, 0u64],
        bootstrapRecords = @[record2],
      )

      # Start nodes' discoveryV5 protocols
      let res1 = await node1.start()
      assertResultOk res1

      let res2 = await node2.start()
      assertResultOk res2

      let res3 = await node3.start()
      assertResultOk res3

      let res4 = await node4.start()
      assertResultOk res4

      ## leave some time for discv5 to act
      await sleepAsync(chronos.seconds(10))

      ## When
      let peers = await node1.findRandomPeers()

      ## Then
      check:
        peers.len >= 1
        peers.allIt(it.supportsCapability(Capabilities.Store))

      # Cleanup
      await allFutures(node1.stop(), node2.stop(), node3.stop(), node4.stop())

  suite "addBootstrapNode":
    asyncTest "address is valid":
      # Given an empty list of enrs
      var enrs: seq[Record] = @[]

      # When adding a valid enr
      addBootstrapNode(validEnr, enrs)
      var r: Record
      echo r.fromURI(validEnr)
      echo r

      # Then the enr is added to the list
      check:
        enrs.len == 1
        enrs[0].toBase64() == validEnr[4 ..^ 1]

    asyncTest "address is empty":
      # Given an empty list of enrs
      var enrs: seq[Record] = @[]

      # When adding an empty enr
      addBootstrapNode("", enrs)

      # Then the enr is not added to the list
      check:
        enrs.len == 0

    asyncTest "address is valid but starts with #":
      # Given an empty list of enrs
      var enrs: seq[Record] = @[]

      # When adding any enr that starts with #
      let enr = "#" & validEnr
      addBootstrapNode(enr, enrs)

      # Then the enr is not added to the list
      check:
        enrs.len == 0

    asyncTest "address is not valid":
      # Given an empty list of enrs
      var enrs: seq[Record] = @[]

      # When adding an invalid enr
      let enr = "enr:invalid"
      addBootstrapNode(enr, enrs)

      # Then the enr is not added to the list
      check:
        enrs.len == 0

  suite "waku discv5 initialization":
    asyncTest "Start waku and check discv5 discovered peers":
      let myRng = libp2p_keys.newRng()
      var confBuilder = defaultTestWakuConfBuilder()

      confBuilder.withNodeKey(libp2p_keys.PrivateKey.random(Secp256k1, myRng[])[])
      confBuilder.discv5Conf.withEnabled(true)
      confBuilder.discv5Conf.withUdpPort(9000.Port)
      let conf = confBuilder.build().valueOr:
        raiseAssert error

      let waku0 = (await Waku.new(conf)).valueOr:
        raiseAssert error
      (waitFor startWaku(addr waku0)).isOkOr:
        raiseAssert error

      confBuilder.withNodeKey(crypto.PrivateKey.random(Secp256k1, myRng[])[])
      confBuilder.discv5Conf.withBootstrapNodes(@[waku0.node.enr.toURI()])
      confBuilder.discv5Conf.withEnabled(true)
      confBuilder.discv5Conf.withUdpPort(9001.Port)
      confBuilder.withP2pTcpPort(60001.Port)

      let conf1 = confBuilder.build().valueOr:
        raiseAssert error

      let waku1 = (await Waku.new(conf1)).valueOr:
        raiseAssert error
      (waitFor startWaku(addr waku1)).isOkOr:
        raiseAssert error

      await waku1.node.mountPeerExchange()
      await waku1.node.mountRendezvous(conf.clusterId)

      confBuilder.discv5Conf.withBootstrapNodes(@[waku1.node.enr.toURI()])
      confBuilder.withP2pTcpPort(60003.Port)
      confBuilder.discv5Conf.withUdpPort(9003.Port)
      confBuilder.withNodeKey(crypto.PrivateKey.random(Secp256k1, myRng[])[])

      let conf2 = confBuilder.build().valueOr:
        raiseAssert error

      let waku2 = (await Waku.new(conf2)).valueOr:
        raiseAssert error
      (waitFor startWaku(addr waku2)).isOkOr:
        raiseAssert error

      # leave some time for discv5 to act
      await sleepAsync(chronos.seconds(10))

      # Connect peers via peer manager to ensure identify happens
      discard await waku0.node.peerManager.connectPeer(waku1.node.switch.peerInfo)

      var r = waku0.node.peerManager.selectPeer(WakuPeerExchangeCodec)
      assert r.isSome(), "could not retrieve peer mounting WakuPeerExchangeCodec"

      r = waku1.node.peerManager.selectPeer(WakuRelayCodec)
      assert r.isSome(), "could not retrieve peer mounting WakuRelayCodec"

      r = waku1.node.peerManager.selectPeer(WakuPeerExchangeCodec)
      assert r.isNone(), "should not retrieve peer mounting WakuPeerExchangeCodec"

      r = waku2.node.peerManager.selectPeer(WakuPeerExchangeCodec)
      assert r.isSome(), "could not retrieve peer mounting WakuPeerExchangeCodec"

      r = waku2.node.peerManager.selectPeer(WakuRendezVousCodec)
      assert r.isSome(), "could not retrieve peer mounting RendezVousCodec"

    asyncTest "Discv5 bootstrap nodes should be added to the peer store":
      var confBuilder = defaultTestWakuConfBuilder()
      confBuilder.discv5Conf.withEnabled(true)
      confBuilder.discv5Conf.withUdpPort(9003.Port)
      confBuilder.discv5Conf.withBootstrapNodes(@[validEnr])
      let conf = confBuilder.build().valueOr:
        raiseAssert error

      let waku = (await Waku.new(conf)).valueOr:
        raiseAssert error

      discard setupDiscoveryV5(
        waku.node.enr,
        waku.node.peerManager,
        waku.node.topicSubscriptionQueue,
        waku.conf.discv5Conf.get(),
        waku.dynamicBootstrapNodes,
        waku.rng,
        waku.conf.nodeKey,
        waku.conf.endpointConf.p2pListenAddress,
        waku.conf.portsShift,
      )

      check:
        waku.node.peerManager.switch.peerStore.peers().anyIt(
          it.enr.isSome() and it.enr.get().toUri() == validEnr
        )

    asyncTest "Invalid discv5 bootstrap node ENRs are ignored":
      var confBuilder = defaultTestWakuConfBuilder()
      confBuilder.discv5Conf.withEnabled(true)
      confBuilder.discv5Conf.withUdpPort(9004.Port)

      let invalidEnr = "invalid-enr"

      confBuilder.discv5Conf.withBootstrapNodes(@[invalidEnr])
      let conf = confBuilder.build().valueOr:
        raiseAssert error

      let waku = (await Waku.new(conf)).valueOr:
        raiseAssert error

      discard setupDiscoveryV5(
        waku.node.enr,
        waku.node.peerManager,
        waku.node.topicSubscriptionQueue,
        conf.discv5Conf.get(),
        waku.dynamicBootstrapNodes,
        waku.rng,
        waku.conf.nodeKey,
        waku.conf.endpointConf.p2pListenAddress,
        waku.conf.portsShift,
      )

      check:
        not waku.node.peerManager.switch.peerStore.peers().anyIt(
          it.enr.isSome() and it.enr.get().toUri() == invalidEnr
        )
