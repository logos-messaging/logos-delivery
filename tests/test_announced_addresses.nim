{.used.}

## Regression tests for the announced-addresses pipeline: how the config's
## intent, the switch-resolved listen addresses and the NAT-mapped external
## addresses combine into what the node announces.

import
  results,
  std/[sequtils, strutils, net],
  testutils/unittests,
  chronos,
  libp2p/crypto/crypto,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/services/natservice
import
  logos_delivery/waku/[
    waku_core,
    waku_node,
    waku_enr,
    net/net_config,
    common/nat_config,
    factory/internal_config,
    factory/waku_conf,
    factory/builder,
  ],
  ./testlib/common,
  ./testlib/wakucore,
  ./testlib/wakunode

proc buildNode(bindPort: Port, quicBindPort: Port): WakuNode =
  ## A node built straight from NetConfig, so port combinations that
  ## newTestWakuNode normalizes away (e.g. quic dynamic while tcp is
  ## explicit) can be expressed.
  let nodeKey = generateSecp256k1Key()
  let netConf = NetConfig.init(
    clusterId = DefaultClusterId,
    bindIp = parseIpAddress("127.0.0.1"),
    bindPort = bindPort,
    quicBindPort = Opt.some(quicBindPort),
    quicEnabled = true,
  ).valueOr:
    raiseAssert "invalid NetConfig: " & $error

  var enrBuilder = EnrBuilder.init(nodeKey)
  enrBuilder.withIpAddressAndPorts(
    ipAddr = netConf.enrIp, tcpPort = netConf.enrPort, udpPort = netConf.discv5UdpPort
  )
  let record = enrBuilder.build().valueOr:
    raiseAssert "invalid ENR: " & $error

  var builder = WakuNodeBuilder.init()
  builder.withRng(rng())
  builder.withNodeKey(nodeKey)
  builder.withRecord(record)
  builder.withNetworkConfiguration(netConf)
  builder.withSwitchConfiguration(maxConnections = Opt.some(50))
  builder.build().get()

suite "Announced addresses":
  asyncTest "NAT-mapped addresses keep updating announced addresses after start":
    ## The NATService renews mappings on every peerInfo.update (the refresh
    ## loop beats every 30 minutes); its output must keep flowing into the
    ## announced addresses instead of being frozen at start time.
    let node = buildNode(bindPort = Port(0), quicBindPort = Port(0))
    await node.start()

    # A NATService that has discovered an external IP.
    let natSvc = NATService.new(upnpConfig(), rng())
    natSvc.externalIp = Opt.some(parseIpAddress("203.0.113.9"))
    node.switch.services.add(Service(natSvc))

    # A mapper standing in for the NATService's own: injects the mapped
    # external address into the chain, as the real one does after a
    # successful port mapping.
    let mapped = MultiAddress.init("/ip4/203.0.113.9/tcp/4444").get()
    node.switch.peerInfo.addressMappers.insert(
      proc(
          addrs: seq[MultiAddress]
      ): Future[seq[MultiAddress]] {.gcsafe, async: (raises: [CancelledError]).} =
        return addrs & @[mapped],
      0,
    )

    # The address-change callback (the ENR refresh hook in the factory)
    # must fire when the announced addresses change.
    var changeSignalled = false
    node.onAnnouncedAddressesChange = proc() {.gcsafe, raises: [].} =
      changeSignalled = true

    await node.switch.peerInfo.update()
    check:
      mapped in node.announcedAddresses
      changeSignalled
    await node.stop()

  asyncTest "a dynamically allocated quic port postpones the primary-IP rewrite":
    ## The "is any port dynamically allocated" decision must see every
    ## transport: a config with an explicit tcp port but a dynamic quic port
    ## is a dynamic config, and the primary-IP announce rewrite is postponed
    ## for it, exactly as it is when the tcp port is dynamic.
    let node = buildNode(bindPort = Port(61893), quicBindPort = Port(0))
    await node.start()
    check node.announcedAddresses.allIt("127.0.0.1" in $it)
    await node.stop()

  asyncTest "a NAT external IP without a quic mapping announces no external quic address":
    ## When the external IP comes from NAT discovery, each transport's
    ## external address is only real if that transport's port mapping is in
    ## place; a guessed port must not be announced.
    let conf = defaultTestWakuConf()
    conf.quicConf = Opt.some(QuicConf(port: Port(60820)))
    conf.endpointConf.natStrategy = NatStrategy(kind: NatUpnp)
    conf.endpointConf.p2pTcpPort = Port(60821)

    let netConf = (
      await networkConfiguration(
        conf.clusterId,
        conf.endpointConf,
        conf.discv5Conf,
        conf.webSocketConf,
        conf.quicConf,
        conf.wakuFlags,
        conf.dnsAddrsNameServers,
        Opt.some(parseIpAddress("203.0.113.9")),
        Opt.some(Port(60111)),
        Opt.none(Port),
      )
    ).valueOr:
      raiseAssert "networkConfiguration failed: " & error

    check:
      netConf.announcedAddresses.anyIt("203.0.113.9/tcp/60111" in $it)
      not netConf.announcedAddresses.anyIt("203.0.113.9" in $it and "quic" in $it)

  asyncTest "a NAT external IP without a ws mapping announces no external ws address":
    ## Same provenance rule as quic: with a NAT-discovered external IP, the
    ## websocket external address is only real if the ws port mapping is in
    ## place; the configured ws port must not be guessed into it.
    let conf = defaultTestWakuConf()
    conf.webSocketConf = Opt.some(
      WebSocketConf(port: Port(60822), secureConf: Opt.none(WebSocketSecureConf))
    )
    conf.endpointConf.natStrategy = NatStrategy(kind: NatUpnp)
    conf.endpointConf.p2pTcpPort = Port(60821)

    let netConf = (
      await networkConfiguration(
        conf.clusterId,
        conf.endpointConf,
        conf.discv5Conf,
        conf.webSocketConf,
        conf.quicConf,
        conf.wakuFlags,
        conf.dnsAddrsNameServers,
        Opt.some(parseIpAddress("203.0.113.9")),
        Opt.some(Port(60111)),
        Opt.none(Port),
      )
    ).valueOr:
      raiseAssert "networkConfiguration failed: " & error

    check:
      netConf.announcedAddresses.anyIt("203.0.113.9/tcp/60111" in $it)
      not netConf.announcedAddresses.anyIt("203.0.113.9" in $it and "/ws" in $it)
