import results
{.used.}

import std/strutils
import chronos, confutils/toml/std/net, libp2p/multiaddress, testutils/unittests

import ./testlib/wakunode, logos_delivery/waku/waku_enr/capabilities

include
  logos_delivery/waku/net/net_config,
  logos_delivery/waku/factory/conf_builder/web_socket_conf_builder,
  logos_delivery/waku/factory/conf_builder/conf_builder

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
      extIp = Opt.none(IpAddress),
      extPort = Opt.none(Port),
      extMultiAddrs = @[],
      wsBindPort =
        if conf.webSocketConf.isSome():
          Opt.some(conf.webSocketConf.get().port)
        else:
          Opt.none(Port),
      wsEnabled = conf.webSocketConf.isSome(),
      wssEnabled =
        if conf.webSocketConf.isSome():
          conf.webSocketConf.get().secureConf.isSome()
        else:
          false,
      dns4DomainName = Opt.none(string),
      discv5UdpPort = Opt.none(Port),
      wakuFlags = Opt.some(wakuFlags),
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
        ip4TcpEndPoint(conf.endpointConf.p2pListenAddress, conf.endpointConf.p2pTcpPort)

  asyncTest "AnnouncedAddresses contains external address if extIp/Port are provided":
    let
      conf = defaultTestWakuConf()
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      extIp = Opt.some(extIp),
      extPort = Opt.some(extPort),
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
      dns4DomainName = Opt.some(dns4DomainName),
      extPort = Opt.some(extPort),
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

  asyncTest "Operator QUIC extMultiAddr suppresses the auto QUIC address":
    let
      conf = defaultTestWakuConf()
      bindPort = conf.endpointConf.p2pTcpPort
      operatorQuic = ipQuicEndPoint(parseIpAddress("1.2.3.4"), Port(9999))

    # no operator quic addr: node auto-announces its bind-port quic addr
    let autoRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = bindPort,
      quicEnabled = true,
      quicBindPort = Opt.some(bindPort),
    )
    assert autoRes.isOk(), $autoRes.error
    check autoRes.get().announcedAddresses.filterIt(it.isQuicAddress()).len == 1

    # operator quic addr given: auto bind-port addr suppressed, only theirs remains
    let opRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = bindPort,
      quicEnabled = true,
      quicBindPort = Opt.some(bindPort),
      extMultiAddrs = @[operatorQuic],
    )
    assert opRes.isOk(), $opRes.error
    let opNetConfig = opRes.get()
    check:
      opNetConfig.announcedAddresses.filterIt(it.isQuicAddress()) == @[operatorQuic]
      opNetConfig.enrMultiaddrs.filterIt(it.isQuicAddress()) == @[operatorQuic]

  asyncTest "Announced QUIC address uses the NAT-mapped external port, not the bind port":
    let
      conf = defaultTestWakuConf()
      extIp = parseIpAddress("1.2.3.4")
      quicBindPort = Port(60000)
      natQuicPort = Port(9999) # external UDP port a NAT (UPnP/PMP) mapped for us

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      extIp = Opt.some(extIp),
      extPort = Opt.some(Port(1234)),
      quicEnabled = true,
      quicBindPort = Opt.some(quicBindPort),
      extQuicPort = Opt.some(natQuicPort),
    )
    assert netConfigRes.isOk(), $netConfigRes.error

    let quicAddrs = netConfigRes.get().announcedAddresses.filterIt(it.isQuicAddress())
    check:
      quicAddrs.len == 1
      ("/udp/" & $(natQuicPort.uint16) & "/quic-v1") in $quicAddrs[0]
      ("/udp/" & $(quicBindPort.uint16) & "/quic-v1") notin $quicAddrs[0]

  asyncTest "AnnouncedAddresses uses dns4DomainName over extIp when both are provided":
    let
      conf = defaultTestWakuConf()
      dns4DomainName = "example.com"
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      dns4DomainName = Opt.some(dns4DomainName),
      extIp = Opt.some(extIp),
      extPort = Opt.some(extPort),
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # DNS address
      netConfig.announcedAddresses[0] == dns4TcpEndPoint(dns4DomainName, extPort)

  asyncTest "AnnouncedAddresses and enrMultiaddrs deduplicate dns4DomainName and extMultiAddrs overlap":
    let
      conf = defaultTestWakuConf()
      dns4DomainName = "example.com"
      extPort = Port(1234)
      dns4Address = dns4TcpEndPoint(dns4DomainName, extPort)

    let netConfigRes = NetConfig.init(
      bindIp = conf.endpointConf.p2pListenAddress,
      bindPort = conf.endpointConf.p2pTcpPort,
      dns4DomainName = Opt.some(dns4DomainName),
      extPort = Opt.some(extPort),
      extMultiAddrs = @[dns4Address],
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1
      netConfig.announcedAddresses[0] == dns4Address
      netConfig.enrMultiAddrs.len == 1
      netConfig.enrMultiAddrs[0] == dns4Address

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
      extIp = Opt.some(extIp),
      extPort = Opt.some(extPort),
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
      dns4DomainName = Opt.some(dns4DomainName),
      extPort = Opt.some(extPort),
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
      dns4DomainName = Opt.some(dns4DomainName),
      extIp = Opt.some(extIp),
      extPort = Opt.some(extPort),
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
      extIp = Opt.some(extIp),
      extPort = Opt.some(extPort),
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
      dns4DomainName = Opt.some(dns4DomainName),
      extPort = Opt.some(extPort),
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
      quicEnabled = true,
      quicBindPort = Opt.some(Port(60000)),
      extMultiAddrs = extMultiAddrs,
      extMultiAddrsOnly = true,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # ExtAddress
      netConfig.announcedAddresses[0] == extMultiAddrs[0]
      netConfig.announcedAddresses.filterIt(it.isQuicAddress()).len == 0

  test "NetConfig.init rejects ext-only with empty or zero-port sets":
    check NetConfig
      .init(
        bindIp = parseIpAddress("127.0.0.1"),
        bindPort = Port(60200),
        extMultiAddrsOnly = true,
      )
      .isErr()
    check NetConfig
      .init(
        bindIp = parseIpAddress("127.0.0.1"),
        bindPort = Port(60200),
        extMultiAddrs = @[MultiAddress.init("/ip4/203.0.113.9/tcp/0").get()],
        extMultiAddrsOnly = true,
      )
      .isErr()
    check NetConfig
      .init(
        bindIp = parseIpAddress("127.0.0.1"),
        bindPort = Port(60200),
        extMultiAddrs = @[MultiAddress.init("/ip4/203.0.113.9/udp/0/quic-v1").get()],
        extMultiAddrsOnly = true,
      )
      .isErr()

  test "hasZeroPort reads the port bytes on every transport shape":
    check:
      MultiAddress.init("/ip4/1.2.3.4/tcp/0").get().hasZeroPort()
      MultiAddress.init("/dns4/x.example.org/tcp/0/wss").get().hasZeroPort()
      MultiAddress.init("/ip4/1.2.3.4/udp/0/quic-v1").get().hasZeroPort()
      not MultiAddress.init("/ip4/1.2.3.4/tcp/60000").get().hasZeroPort()
      not MultiAddress.init("/dns4/x.example.org/tcp/443/wss").get().hasZeroPort()

proc resolveMa(s: string): MultiAddress =
  MultiAddress.init(s).get()

suite "Waku NetConfig - resolveAnnouncedAddresses":
  test "a wildcard host and port 0 take the bound address of the same transport":
    let intent = @[
      resolveMa("/ip4/0.0.0.0/tcp/0"),
      resolveMa("/ip4/0.0.0.0/tcp/0/ws"),
      resolveMa("/ip4/0.0.0.0/udp/0/quic-v1"),
    ]
    let bound = @[
      resolveMa("/ip4/192.0.2.10/tcp/60001"),
      resolveMa("/ip4/192.0.2.10/tcp/60002/ws"),
      resolveMa("/ip4/192.0.2.10/udp/60003/quic-v1"),
    ]
    check resolveAnnouncedAddresses(intent, bound) == bound

  test "a concrete host keeps its host and takes only the bound port":
    check:
      resolveAnnouncedAddresses(
        @[resolveMa("/ip4/127.0.0.1/tcp/0")], @[resolveMa("/ip4/127.0.0.1/tcp/60001")]
      ) == @[resolveMa("/ip4/127.0.0.1/tcp/60001")]
      ## A dns host with port 0 takes the bound tcp port.
      resolveAnnouncedAddresses(
        @[resolveMa("/dns4/x.example.org/tcp/0")],
        @[resolveMa("/ip4/192.0.2.10/tcp/60001")],
      ) == @[resolveMa("/dns4/x.example.org/tcp/60001")]

  test "concrete entries pass through and duplicates collapse":
    let ext = resolveMa("/ip4/203.0.113.9/tcp/60123")
    let tricky = resolveMa("/ip4/10.0.0.0/tcp/60123")
    check resolveAnnouncedAddresses(@[ext, ext, tricky], @[]) == @[ext, tricky]

  test "an entry whose transport has not bound is dropped":
    check:
      ## Before the bind, the listen addresses still carry port 0.
      resolveAnnouncedAddresses(
        @[resolveMa("/ip4/0.0.0.0/tcp/0")], @[resolveMa("/ip4/0.0.0.0/tcp/0")]
      ).len == 0
      ## No ws transport bound: the ws entry goes, the tcp entry resolves.
      resolveAnnouncedAddresses(
        @[resolveMa("/ip4/0.0.0.0/tcp/0"), resolveMa("/ip4/0.0.0.0/tcp/0/ws")],
        @[resolveMa("/ip4/192.0.2.10/tcp/60001")],
      ) == @[resolveMa("/ip4/192.0.2.10/tcp/60001")]

  test "a wildcard host resolves onto every bound address of its transport":
    ## A dual-stack bind expands to one address per family.
    let bound = @[
      resolveMa("/ip6/2001:db8::10/tcp/60001"), resolveMa("/ip4/192.0.2.10/tcp/60001")
    ]
    check resolveAnnouncedAddresses(@[resolveMa("/ip6/::/tcp/0")], bound) == bound

  test "isWildcardHost and transportPort read the address shapes":
    check:
      resolveMa("/ip4/0.0.0.0/tcp/1").isWildcardHost()
      resolveMa("/ip6/::/tcp/1").isWildcardHost()
      not resolveMa("/ip4/10.0.0.0/tcp/1").isWildcardHost()
      not resolveMa("/dns4/x.example.org/tcp/1").isWildcardHost()
      resolveMa("/ip4/1.2.3.4/udp/60003/quic-v1").transportPort() ==
        Opt.some(Port(60003))
      resolveMa("/dns4/x.example.org/tcp/443/wss").transportPort() == Opt.some(
        Port(443)
      )
      resolveMa("/ip4/1.2.3.4").transportPort().isNone()
