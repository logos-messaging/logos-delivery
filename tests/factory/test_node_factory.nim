{.used.}

import
  std/[net, options, sequtils, strutils],
  testutils/unittests,
  chronos,
  chronos/transports/[stream, datagram, common],
  metrics/chronos_httpserver,
  libp2p/[crypto/crypto, multiaddress, protocols/connectivity/relay/relay],
  eth/p2p/discoveryv5/enr

import
  tests/testlib/[wakunode, wakucore],
  waku/[waku_node, waku_enr, net/auto_port, discovery/waku_discv5, node/waku_metrics],
  waku/factory/[
    node_factory, internal_config, conf_builder/conf_builder,
    conf_builder/web_socket_conf_builder,
  ]

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
      wakuFlags = some(conf.wakuFlags),
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
    let takenPort = Port(55100)
    let freePort = Port(55101)
    let taken = createStreamServer(initTAddress("127.0.0.1", takenPort))
    defer:
      taken.stop()
      await taken.closeWait()

    proc buildMetricsConf(port: Port): MetricsServerConf =
      var b = MetricsServerConfBuilder.init()
      b.withEnabled(true)
      b.withHttpPort(port)
      b.build().value.get()

    let failRes = await startMetricsServerAndLogging(buildMetricsConf(takenPort), 0'u16)
    check failRes.isErr()

    let okRes = await startMetricsServerAndLogging(buildMetricsConf(freePort), 0'u16)
    check okRes.isOk()
    if okRes.isOk():
      await okRes.get().server.close()

  asynctest "discv5 binds on free UDP port, fails on taken":
    let takenPort = Port(55200)
    let freePort = Port(55201)

    proc dummyCb(
        transp: DatagramTransport, raddr: TransportAddress
    ): Future[void] {.async: (raises: []).} =
      discard

    let takenUdp =
      newDatagramTransport(dummyCb, local = initTAddress("0.0.0.0", takenPort))
    defer:
      await takenUdp.closeWait()

    let nodeKey = generateSecp256k1Key()
    let node = newTestWakuNode(nodeKey, parseIpAddress("0.0.0.0"), Port(0))
    await node.start()
    defer:
      await node.stop()

    proc buildDiscv5Conf(port: Port): Discv5Conf =
      var b = Discv5ConfBuilder.init()
      b.withEnabled(true)
      b.withUdpPort(port)
      b.build().value.get()

    let failRes = await setupAndStartDiscv5(
      node.enr,
      node.peerManager,
      node.topicSubscriptionQueue,
      buildDiscv5Conf(takenPort),
      @[],
      node.rng,
      nodeKey,
      parseIpAddress("0.0.0.0"),
      0'u16,
    )
    check failRes.isErr()

    let okRes = await setupAndStartDiscv5(
      node.enr,
      node.peerManager,
      node.topicSubscriptionQueue,
      buildDiscv5Conf(freePort),
      @[],
      node.rng,
      nodeKey,
      parseIpAddress("0.0.0.0"),
      0'u16,
    )
    check okRes.isOk()
    if okRes.isOk():
      await okRes.get().stop()
