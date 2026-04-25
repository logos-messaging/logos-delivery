{.used.}

import chronos, confutils/toml/std/net, libp2p/multiaddress, testutils/unittests

import ./testlib/wakunode, waku/waku_enr/capabilities

include
  waku/net/net_config,
  waku/factory/conf_builder/web_socket_conf_builder,
  waku/factory/conf_builder/conf_builder

proc defaultTestWakuFlags(): CapabilitiesBitfield =
  CapabilitiesBitfield.init(
    lightpush = false, filter = false, store = false, relay = true
  )

suite "Waku NetConfig":
  asyncTest "Create NetConfig with default values":
    let conf = defaultTestWakuConf()

    let wakuFlags = defaultTestWakuFlags()

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      extIp = none(IpAddress),
      extPort = none(Port),
      extMultiAddrs = @[],
      wsBindPort =
        if conf.webSocketConf.isSome():
          some(conf.webSocketConf.get().port)
        else:
          none(Port),
      wsEnabled = conf.webSocketConf.isSome(),
      wssEnabled =
        if conf.webSocketConf.isSome():
          conf.webSocketConf.get().secureConf.isSome()
        else:
          false,
      dns4DomainName = none(string),
      discv5UdpPort = none(Port),
      wakuFlags = some(wakuFlags),
    )

    check:
      netConfigRes.isOk()

  asyncTest "AnnouncedAddresses contains only bind address when no external addresses are provided":
    let conf = defaultTestWakuConf()

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # Only bind address should be present
      netConfig.announcedAddresses[0] ==
        formatListenAddress(
          ip4TcpEndPoint(
            conf.endpointConf.p2pListenAddress, conf.endpointConf.p2pTcpPort
          )
        )

  asyncTest "AnnouncedAddresses contains external address if extIp/Port are provided":
    let
      conf = defaultTestWakuConf()
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      extIp = some(extIp),
      extPort = some(extPort),
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # Only external address should be present
      netConfig.announcedAddresses[0] == ip4TcpEndPoint(extIp, extPort)

  asyncTest "AnnouncedAddresses contains dns4DomainName if provided":
    let
      conf = defaultTestWakuConf()
      dns4DomainName = "example.com"
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      dns4DomainName = some(dns4DomainName),
      extPort = some(extPort),
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # Only DNS address should be present
      netConfig.announcedAddresses[0] == dns4TcpEndPoint(dns4DomainName, extPort)

  asyncTest "AnnouncedAddresses includes extMultiAddrs when provided":
    let
      conf = defaultTestWakuConf()
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)
      extMultiAddrs = @[ip4TcpEndPoint(extIp, extPort)]

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      extMultiAddrs = extMultiAddrs,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + extAddress
      netConfig.announcedAddresses[1] == extMultiAddrs[0]

  asyncTest "AnnouncedAddresses uses dns4DomainName over extIp when both are provided":
    let
      conf = defaultTestWakuConf()
      dns4DomainName = "example.com"
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      dns4DomainName = some(dns4DomainName),
      extIp = some(extIp),
      extPort = some(extPort),
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # DNS address
      netConfig.announcedAddresses[0] == dns4TcpEndPoint(dns4DomainName, extPort)

  asyncTest "AnnouncedAddresses includes WebSocket addresses when enabled":
    var confBuilder = defaultTestWakuConfBuilder()

    confBuilder.webSocketConf.withEnabled(true)
    confBuilder.webSocketConf.withWebSocketPort(Port(8000))

    let conf = confBuilder.build().valueOr:
      raiseAssert error

    var wssEnabled = false

    var netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      wsEnabled = true,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    var netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + wsHostAddress
      netConfig.announcedAddresses[1] == (
        ip4TcpEndPoint(
          conf.endpointConf.p2pListenAddress, conf.webSocketConf.get().port
        ) & wsFlag(wssEnabled)
      )

    ## Now try the same for the case of wssEnabled = true

    wssEnabled = true

    netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      wsEnabled = true,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + wsHostAddress
      netConfig.announcedAddresses[1] == (
        ip4TcpEndPoint(
          conf.endpointConf.p2pListenAddress, conf.websocketConf.get().port
        ) & wsFlag(wssEnabled)
      )

  asyncTest "Announced WebSocket address contains external IP if provided":
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.webSocketConf.withEnabled(true)
    confBuilder.webSocketConf.withWebSocketPort(Port(8000))

    let conf = confBuilder.build().valueOr:
      raiseAssert error

    let
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)
      wssEnabled = false

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      extIp = some(extIp),
      extPort = some(extPort),
      wsEnabled = true,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # External address + wsHostAddress
      netConfig.announcedAddresses[1] ==
        (ip4TcpEndPoint(extIp, conf.websocketConf.get().port) & wsFlag(wssEnabled))

  asyncTest "Announced WebSocket address contains dns4DomainName if provided":
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.webSocketConf.withEnabled(true)
    confBuilder.webSocketConf.withWebSocketPort(Port(8000))

    let conf = confBuilder.build().valueOr:
      raiseAssert error

    let
      dns4DomainName = "example.com"
      extPort = Port(1234)
      wssEnabled = false

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      dns4DomainName = some(dns4DomainName),
      extPort = some(extPort),
      wsEnabled = true,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + wsHostAddress
      netConfig.announcedAddresses[1] == (
        dns4TcpEndPoint(dns4DomainName, conf.webSocketConf.get().port) &
        wsFlag(wssEnabled)
      )

  asyncTest "Announced WebSocket address contains dns4DomainName if provided alongside extIp":
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.webSocketConf.withEnabled(true)
    confBuilder.webSocketConf.withWebSocketPort(Port(8000))

    let conf = confBuilder.build().valueOr:
      raiseAssert error

    let
      dns4DomainName = "example.com"
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)
      wssEnabled = false

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      dns4DomainName = some(dns4DomainName),
      extIp = some(extIp),
      extPort = some(extPort),
      wsEnabled = true,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # DNS address + wsHostAddress
      netConfig.announcedAddresses[0] == dns4TcpEndPoint(dns4DomainName, extPort)
      netConfig.announcedAddresses[1] == (
        dns4TcpEndPoint(dns4DomainName, conf.webSocketConf.get().port) &
        wsFlag(wssEnabled)
      )

  asyncTest "ENR is set with bindIp/Port if no extIp/Port are provided":
    let conf = defaultTestWakuConf()

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.enrIp.get() == conf.endpointConf.p2pListenAddress
      netConfig.enrPort.get() == conf.endpointConf.p2pTcpPort

  asyncTest "ENR is set with extIp/Port if provided":
    let
      conf = defaultTestWakuConf()
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      extIp = some(extIp),
      extPort = some(extPort),
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.extIp.get() == extIp
      netConfig.enrPort.get() == extPort

  asyncTest "ENR is set with dns4DomainName if provided":
    let
      conf = defaultTestWakuConf()
      dns4DomainName = "example.com"
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      dns4DomainName = some(dns4DomainName),
      extPort = some(extPort),
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.enrMultiaddrs.contains(dns4TcpEndPoint(dns4DomainName, extPort))

  asyncTest "wsHostAddress is not announced if a WS/WSS address is provided in extMultiAddrs":
    var
      conf = defaultTestWakuConf()
      extAddIp = parseIpAddress("1.2.3.4")
      extAddPort = Port(1234)
      wsEnabled = true
      wssEnabled = false
      extMultiAddrs = @[(ip4TcpEndPoint(extAddIp, extAddPort) & wsFlag(wssEnabled))]

    var netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      extMultiAddrs = extMultiAddrs,
      wsEnabled = wsEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    var netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + extAddress
      netConfig.announcedAddresses[1] == extMultiAddrs[0]

    # Now same test for WSS external address
    wssEnabled = true
    extMultiAddrs = @[(ip4TcpEndPoint(extAddIp, extAddPort) & wsFlag(wssEnabled))]

    netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      extMultiAddrs = extMultiAddrs,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + extAddress
      netConfig.announcedAddresses[1] == extMultiAddrs[0]

  asyncTest "Only extMultiAddrs are published when enabling extMultiAddrsOnly flag":
    let
      conf = defaultTestWakuConf()
      extAddIp = parseIpAddress("1.2.3.4")
      extAddPort = Port(1234)
      extMultiAddrs = @[ip4TcpEndPoint(extAddIp, extAddPort)]

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      extMultiAddrs = extMultiAddrs,
      extMultiAddrsOnly = true,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # ExtAddress
      netConfig.announcedAddresses[0] == extMultiAddrs[0]
