{.used.}

import
  results,
  std/[net, sequtils, strutils, tables],
  testutils/unittests,
  chronos,
  chronos/transports/[stream, datagram, common],
  metrics,
  metrics/chronos_httpserver,
  libp2p/[crypto/crypto, multiaddress, protocols/connectivity/relay/relay],
  eth/p2p/discoveryv5/enr

import tools/confutils/cli_args

import
  tests/testlib/[wakunode, wakucore],
  logos_delivery/waku/[
    waku_core,
    waku_node,
    waku_store/common,
    net/net_config,
    waku_enr,
    net/auto_port,
    discovery/waku_discv5,
    node/peer_manager,
    node/waku_metrics,
    waku_metadata,
    waku_filter_v2,
    common/rate_limit/setting,
  ],
  logos_delivery/waku/factory/[
    node_factory,
    internal_config,
    conf_builder/conf_builder,
    conf_builder/web_socket_conf_builder,
  ]

proc servicePeerGauge(codec, address: string): float64 =
  try:
    return logos_delivery_service_peers.value([codec, address])
  except KeyError:
    return 0.0

suite "Node Factory":
  asynctest "Set up a node based on default configurations":
    let conf = defaultTestWakuConf()

    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    check:
      not node.isNil()
      node.wakuArchive.isNil()
      node.wakuStore.isNil()
      node.wakuFilter.isNil()
      not node.wakuStoreClient.isNil()
      not node.wakuRendezvous.isNil()

  asynctest "Set up a node with Store enabled":
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.storeServiceConf.withEnabled(true)
    confBuilder.storeServiceConf.withDbUrl("sqlite://store.sqlite3")
    let conf = confBuilder.build().value

    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    check:
      not node.isNil()
      not node.wakuStore.isNil()
      not node.wakuArchive.isNil()

  asynctest "The command line default rate limits reach the mounted protocols":
    # Given the configuration of a binary started without --rate-limit
    let conf = defaultKernelConf().get().toWakuConf().valueOr:
        raiseAssert error

    # When the node is set up
    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then each protocol is mounted with the limit the command line assigns
    let
      filterLimit = node.wakuFilter.peerRequestRateLimiter.setting
      lightPushLimit = node.wakuLightPush.requestRateLimiter.setting
      peerExchangeLimit = node.wakuPeerExchange.requestRateLimiter.setting

    check:
      filterLimit == Opt.some((volume: 100, period: 1.seconds))
      lightPushLimit == Opt.some((volume: 5, period: 1.seconds))
      peerExchangeLimit == Opt.some((volume: 5, period: 1.seconds))

  asynctest "A command line lightpush rate limit keeps the filter and peer exchange defaults":
    # Given the configuration of a binary started with --rate-limit=lightpush:100/1s
    var cliConf = defaultKernelConf().get()
    cliConf.rateLimits = @["lightpush:100/1s"]
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then only lightpush changes, filter and peer exchange keep their defaults
    let
      filterLimit = node.wakuFilter.peerRequestRateLimiter.setting
      lightPushLimit = node.wakuLightPush.requestRateLimiter.setting
      peerExchangeLimit = node.wakuPeerExchange.requestRateLimiter.setting

    check:
      filterLimit == Opt.some((volume: 100, period: 1.seconds))
      lightPushLimit == Opt.some((volume: 100, period: 1.seconds))
      peerExchangeLimit == Opt.some((volume: 5, period: 1.seconds))

  asynctest "A command line rate limit without a protocol applies to every protocol":
    # Given the configuration of a binary started with --rate-limit=100/1s
    var cliConf = defaultKernelConf().get()
    cliConf.rateLimits = @["100/1s"]
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then every protocol takes the global limit
    let
      filterLimit = node.wakuFilter.peerRequestRateLimiter.setting
      lightPushLimit = node.wakuLightPush.requestRateLimiter.setting
      peerExchangeLimit = node.wakuPeerExchange.requestRateLimiter.setting

    check:
      filterLimit == Opt.some((volume: 100, period: 1.seconds))
      lightPushLimit == Opt.some((volume: 100, period: 1.seconds))
      peerExchangeLimit == Opt.some((volume: 100, period: 1.seconds))

  asynctest "A command line store rate limit keeps the service defaults":
    # Given the configuration of a binary started with --rate-limit=store:10/1s
    var cliConf = defaultKernelConf().get()
    cliConf.rateLimits = @["store:10/1s"]
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then filter, lightpush and peer exchange keep their defaults
    let
      filterLimit = node.wakuFilter.peerRequestRateLimiter.setting
      lightPushLimit = node.wakuLightPush.requestRateLimiter.setting
      peerExchangeLimit = node.wakuPeerExchange.requestRateLimiter.setting

    check:
      filterLimit == Opt.some((volume: 100, period: 1.seconds))
      lightPushLimit == Opt.some((volume: 5, period: 1.seconds))
      peerExchangeLimit == Opt.some((volume: 5, period: 1.seconds))

  asynctest "The command line default rate limits let the filter service accept 31 subscribes in a row":
    # Given a node set up from the configuration of a binary started without --rate-limit
    var cliConf = defaultKernelConf().get()
    cliConf.tcpPort = Port(0)
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error
    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # And a filter client
    let client = newTestWakuNode(generateSecp256k1Key(), clusterId = conf.clusterId)
    client.mountMetadata(conf.clusterId, @[]).isOkOr:
      raiseAssert error
    await allFutures(node.start(), client.start())
    defer:
      await allFutures(node.stop(), client.stop())
    await client.mountFilterClient()
    let serverRemotePeerInfo = node.switch.peerInfo.toRemotePeerInfo()

    # When the client sends 31 subscribes in a row
    var subscribeResults: seq[FilterSubscribeResult]
    for _ in 0 ..< 31:
      subscribeResults.add(
        await client.filterSubscribe(
          Opt.some(DefaultPubsubTopic), DefaultContentTopic, serverRemotePeerInfo
        )
      )

    # Then the filter service accepts all of them
    check subscribeResults.allIt(it.isOk())

  asynctest "A command line lightpush rate limit keeps the filter service accepting 31 subscribes in a row":
    # Given a node set up from the configuration of a binary started with --rate-limit=lightpush:100/1s
    var cliConf = defaultKernelConf().get()
    cliConf.tcpPort = Port(0)
    cliConf.rateLimits = @["lightpush:100/1s"]
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error
    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # And a filter client
    let client = newTestWakuNode(generateSecp256k1Key(), clusterId = conf.clusterId)
    client.mountMetadata(conf.clusterId, @[]).isOkOr:
      raiseAssert error
    await allFutures(node.start(), client.start())
    defer:
      await allFutures(node.stop(), client.stop())
    await client.mountFilterClient()
    let serverRemotePeerInfo = node.switch.peerInfo.toRemotePeerInfo()

    # When the client sends 31 subscribes in a row
    var subscribeResults: seq[FilterSubscribeResult]
    for _ in 0 ..< 31:
      subscribeResults.add(
        await client.filterSubscribe(
          Opt.some(DefaultPubsubTopic), DefaultContentTopic, serverRemotePeerInfo
        )
      )

    # Then the filter service accepts all of them
    check subscribeResults.allIt(it.isOk())

  asynctest "The storenode command line option fills the store service slot":
    # Given the configuration of a binary started with --storenode
    let
      storePeerId = PeerId.init(generateSecp256k1Key()).tryGet()
      storeAddress = "/ip4/127.0.0.1/tcp/60000"
    var cliConf = defaultKernelConf().get()
    cliConf.storenode = storeAddress & "/p2p/" & $storePeerId
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then that peer holds the store service slot
    check:
      node.peerManager.serviceSlots[WakuStoreCodec].peerId == storePeerId
      servicePeerGauge(WakuStoreCodec, storeAddress) == 1

  asynctest "The storenode command line option fills the store sync service slots":
    # Given the configuration of a binary started with --store, --store-sync and --storenode
    let
      storePeerId = PeerId.init(generateSecp256k1Key()).tryGet()
      storeAddress = "/ip4/127.0.0.1/tcp/60000"
    var cliConf = defaultKernelConf().get()
    cliConf.store = Opt.some(true)
    cliConf.storeMessageDbUrl = "sqlite://store.sqlite3"
    cliConf.storeSync = true
    cliConf.storenode = storeAddress & "/p2p/" & $storePeerId
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then that peer holds the reconciliation and transfer service slots
    check:
      node.peerManager.serviceSlots[WakuReconciliationCodec].peerId == storePeerId
      node.peerManager.serviceSlots[WakuTransferCodec].peerId == storePeerId

  asynctest "The filternode command line option fills the filter service slot":
    # Given the configuration of a binary started with --filternode
    let
      filterPeerId = PeerId.init(generateSecp256k1Key()).tryGet()
      filterAddress = "/ip4/127.0.0.1/tcp/60000"
    var cliConf = defaultKernelConf().get()
    cliConf.filternode = filterAddress & "/p2p/" & $filterPeerId
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then that peer holds the filter service slot
    check:
      node.peerManager.serviceSlots[WakuFilterSubscribeCodec].peerId == filterPeerId
      servicePeerGauge(WakuFilterSubscribeCodec, filterAddress) == 1

  asynctest "The lightpushnode command line option fills the lightpush service slot":
    # Given the configuration of a binary started with --lightpushnode
    let
      lightPushPeerId = PeerId.init(generateSecp256k1Key()).tryGet()
      lightPushAddress = "/ip4/127.0.0.1/tcp/60000"
    var cliConf = defaultKernelConf().get()
    cliConf.lightpushnode = lightPushAddress & "/p2p/" & $lightPushPeerId
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then that peer holds the lightpush service slot
    check:
      node.peerManager.serviceSlots[WakuLightPushCodec].peerId == lightPushPeerId
      servicePeerGauge(WakuLightPushCodec, lightPushAddress) == 1

  asynctest "The peer-exchange-node command line option fills the peer exchange service slot and fetches its peers at start":
    # Given a peer exchange responder that discovered a peer via Discv5
    let
      responder = newTestWakuNode(generateSecp256k1Key())
      discoveredNode = newTestWakuNode(generateSecp256k1Key())
    # The node disconnects a peer that does not report its cluster id through the metadata protocol.
    check:
      responder.mountMetadata(DefaultClusterId, @[]).isOk()
      discoveredNode.mountMetadata(DefaultClusterId, @[]).isOk()
    await allFutures(responder.start(), discoveredNode.start())
    defer:
      await allFutures(responder.stop(), discoveredNode.stop())
    await responder.mountPeerExchange()
    var discoveredPeer = discoveredNode.peerInfo.toRemotePeerInfo()
    discoveredPeer.enr = Opt.some(discoveredNode.enr)
    responder.peerManager.addPeer(discoveredPeer, PeerOrigin.Discv5)

    # And the configuration of a binary started with --peer-exchange-node naming the responder
    var cliConf = defaultKernelConf().get()
    cliConf.tcpPort = Port(0)
    cliConf.peerExchangeNode =
      "/ip4/127.0.0.1/tcp/" & $responder.boundTcpPort() & "/p2p/" &
      $responder.peerInfo.peerId
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up and started
    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error
    let startResult = await startNode(node, conf)
    defer:
      await node.stop()

    # Then the responder holds the peer exchange service slot, and the peer it discovered is in the peer store
    check:
      startResult.isOk()
      node.peerManager.serviceSlots[WakuPeerExchangeCodec].peerId ==
        responder.peerInfo.peerId
      node.peerManager.switch.peerStore.peers.anyIt(
        it.peerId == discoveredPeer.peerId and it.origin == PeerExchange
      )

  asynctest "A content topic's autoshard is advertised in the ENR and metadata":
    # Given a node subscribed to shard 0 and a content topic that maps to shard 3
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.withNumShardsInCluster(8)
    confBuilder.withContentTopics(@["/toychat/2/huilong/proto"])
    let conf = confBuilder.build().valueOr:
      raiseAssert error

    let node = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error
    let client = newTestWakuNode(generateSecp256k1Key(), clusterId = conf.clusterId)
    client.mountMetadata(conf.clusterId, @[]).isOkOr:
      raiseAssert error
    await allFutures(node.start(), client.start())
    defer:
      await allFutures(node.stop(), client.stop())

    # When a peer asks for its metadata
    let conn = (
      await client.peerManager.dialPeer(
        node.switch.peerInfo.toRemotePeerInfo(), WakuMetadataCodec
      )
    ).valueOr:
      raiseAssert "could not dial metadata"
    let metadata = (await client.wakuMetadata.request(conn)).valueOr:
      raiseAssert error

    # Then both the ENR and the metadata advertise the content topic's shard
    let enrShards = node.enr.toTyped().get().relaySharding().get()
    check:
      enrShards.shardIds == @[0'u16, 3'u16]
      metadata.shards == @[0'u32, 3'u32]

  test "ENR configuration trims multiaddrs until record fits":
    var conf = defaultTestWakuConf()
    let bindIp = conf.endpointConf.p2pListenAddress
    let bindPort = Port(30303)

    let oversizedMultiaddrs = (0 .. 11).mapIt(
      MultiAddress
        .init(
          "/dns4/very-long-logical-hostname-" & $it &
            ".example.logos.dev.status.im/tcp/30303/wss"
        )
        .get()
    )

    let netConfig = NetConfig.init(
      clusterId = conf.clusterId,
      bindIp = bindIp,
      bindPort = bindPort,
      extMultiAddrs = oversizedMultiaddrs,
      extMultiAddrsOnly = true,
      wakuFlags = Opt.some(conf.wakuFlags),
    ).valueOr:
      raiseAssert error

    let record = enrConfiguration(conf, netConfig).valueOr:
      raiseAssert error

    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let multiaddrsOpt = typedRecord.value.multiaddrs
    require multiaddrsOpt.isSome()

    let retainedMultiaddrs = multiaddrsOpt.get()
    check:
      retainedMultiaddrs.len < oversizedMultiaddrs.len
      retainedMultiaddrs.len > 0
      retainedMultiaddrs == oversizedMultiaddrs[0 ..< retainedMultiaddrs.len]

asynctest "Set up a node with Filter enabled":
  var confBuilder = defaultTestWakuConfBuilder()
  confBuilder.filterServiceConf.withEnabled(true)
  let conf = confBuilder.build().value

  let node = (await setupNode(conf, relay = Relay.new())).valueOr:
    raiseAssert error

  check:
    not node.isNil()
    not node.wakuFilter.isNil()
  echo "TEST END"

asynctest "Start a node based on default test configuration":
  let conf = defaultTestWakuConf()

  let node = (await setupNode(conf, relay = Relay.new())).valueOr:
    raiseAssert error

  assert not node.isNil(), "Node can't be nil"

  let startRes = catch:
    (await startNode(node, conf))

  assert not startRes.isErr(), "Exception starting node"
  assert startRes.get().isOk(), "Error starting node " & startRes.get().error

  check:
    node.started == true

  # Default conf has p2pTcpPort=0, so the OS must have assigned a real port.
  var hasNonZeroTcp = false
  for a in node.switch.peerInfo.listenAddrs:
    let s = $a
    if ("/tcp/" in s) and not ("/tcp/0" in s):
      hasNonZeroTcp = true
  check hasNonZeroTcp

  ## Cleanup
  await node.stop()

suite "Auto-port retry":
  asynctest "metrics binds on free TCP port, fails on taken":
    let taken = createStreamServer(initTAddress("127.0.0.1", Port(0)))
    defer:
      taken.stop()
      await taken.closeWait()
    let takenPort = taken.localAddress().port

    let freePort = block:
      let probe = createStreamServer(initTAddress("127.0.0.1", Port(0)))
      let p = probe.localAddress().port
      probe.stop()
      await probe.closeWait()
      p

    proc buildMetricsConf(port: Port): MetricsServerConf =
      var b = MetricsServerConfBuilder.init()
      b.withEnabled(true)
      b.withHttpPort(port)
      b.build().value.get()

    let failRes = await startMetricsServerAndLogging(buildMetricsConf(takenPort))
    check failRes.isErr()

    let okRes = await startMetricsServerAndLogging(buildMetricsConf(freePort))
    check okRes.isOk()
    if okRes.isOk():
      await okRes.get().server.close()

  asynctest "discv5 binds on free UDP port, fails on taken":
    proc dummyCb(
        transp: DatagramTransport, raddr: TransportAddress
    ): Future[void] {.async: (raises: []).} =
      discard

    let nodeKey = generateSecp256k1Key()
    let node = newTestWakuNode(nodeKey)
    await node.start()
    defer:
      await node.stop()

    let takenUdp =
      newDatagramTransport(dummyCb, local = initTAddress("0.0.0.0", Port(0)))
    defer:
      await takenUdp.closeWait()
    let takenPort = takenUdp.localAddress().port

    let freePort = block:
      let probe =
        newDatagramTransport(dummyCb, local = initTAddress("0.0.0.0", Port(0)))
      let p = probe.localAddress().port
      await probe.closeWait()
      p

    proc buildDiscv5Conf(port: Port): Discv5Conf =
      var b = Discv5ConfBuilder.init()
      b.withEnabled(true)
      b.withUdpPort(port)
      b.build().value.get()

    let failRes = await setupAndStartDiscv5(
      node.enr,
      node.peerManager,
      buildDiscv5Conf(takenPort),
      @[],
      node.rng,
      nodeKey,
      parseIpAddress("0.0.0.0"),
    )
    check failRes.isErr()

    let okRes = await setupAndStartDiscv5(
      node.enr,
      node.peerManager,
      buildDiscv5Conf(freePort),
      @[],
      node.rng,
      nodeKey,
      parseIpAddress("0.0.0.0"),
    )
    check okRes.isOk()
    if okRes.isOk():
      await okRes.get().stop()
