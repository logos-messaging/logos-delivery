import logos_delivery/waku/compat/option_valueor
{.used.}

import
  std/[json, net, sequtils, strutils],
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/[crypto/crypto, crypto/secp, multiaddress, switch],
  tests/testlib/[wakucore, wakunode],
  logos_delivery/waku/factory/conf_builder/conf_builder

include logos_delivery/waku/waku, logos_delivery/waku/common/enr/typed_record

suite "Wakunode2 - Waku":
  test "compilation version should be reported":
    ## Given
    let conf = defaultTestWakuConf()

    let waku = (waitFor Waku.new(conf)).valueOr:
      raiseAssert error

    ## When
    let version = waku.stateInfo.getNodeInfoItem(NodeInfoId.Version)

    ## Then
    check:
      version == git_version

suite "Wakunode2 - Waku initialization":
  test "peer persistence setup should be successfully mounted":
    ## Given
    var conf = defaultTestWakuConf()
    conf.peerPersistence = true

    let waku = (waitFor Waku.new(conf)).valueOr:
      raiseAssert error

    check:
      not waku.node.peerManager.storage.isNil()

  test "node setup is successful with default configuration":
    ## Given
    var conf = defaultTestWakuConf()

    ## When
    var waku = (waitFor Waku.new(conf)).valueOr:
      raiseAssert error

    (waitFor waku.start()).isOkOr:
      raiseAssert error

    ## Then
    let node = waku.node
    check:
      not node.isNil()
      node.wakuArchive.isNil()
      node.wakuStore.isNil()
      not node.wakuStoreClient.isNil()
      not node.wakuRendezvous.isNil()

    ## Cleanup
    (waitFor waku.stop()).isOkOr:
      raiseAssert error

  test "app properly handles dynamic port configuration":
    ## Given
    var conf = defaultTestWakuConf()
    conf.endpointConf.p2pTcpPort = Port(0)

    ## When
    var waku = (waitFor Waku.new(conf)).valueOr:
      raiseAssert error

    (waitFor waku.start()).isOkOr:
      raiseAssert error

    ## Then
    let
      node = waku.node
      typedNodeEnr = node.enr.toTyped()

    assert typedNodeEnr.isOk(), $typedNodeEnr.error
    let tcpPort = typedNodeEnr.value.tcp()
    assert tcpPort.isSome()
    check tcpPort.get() != 0

    check:
      # Waku started properly
      not node.isNil()
      node.wakuArchive.isNil()
      node.wakuStore.isNil()
      not node.wakuStoreClient.isNil()
      not node.wakuRendezvous.isNil()

      # DS structures are updated with dynamic ports
      typedNodeEnr.get().tcp.get() != 0

    ## Cleanup
    (waitFor waku.stop()).isOkOr:
      raiseAssert error

  test "explicit port=0 triggers auto-bind across all services":
    var builder = defaultTestWakuConfBuilder()
    builder.withP2pTcpPort(Port(0))
    builder.discv5Conf.withEnabled(true)
    builder.discv5Conf.withUdpPort(Port(0))
    builder.restServerConf.withEnabled(true)
    builder.restServerConf.withRelayCacheCapacity(50'u32)
    builder.restServerConf.withPort(Port(0))
    builder.metricsServerConf.withEnabled(true)
    builder.metricsServerConf.withHttpPort(Port(0))
    builder.webSocketConf.withEnabled(true)
    builder.webSocketConf.withWebSocketPort(Port(0))

    let conf = builder.build().valueOr:
      raiseAssert error

    check:
      conf.endpointConf.p2pTcpPort == Port(0)
      conf.discv5Conf.get().udpPort == Port(0)
      conf.restServerConf.get().port == Port(0)
      conf.metricsServerConf.get().httpPort == Port(0)
      conf.webSocketConf.get().port == Port(0)

    var waku = (waitFor Waku.new(conf)).valueOr:
      raiseAssert error
    defer:
      (waitFor waku.stop()).isOkOr:
        raiseAssert error

    (waitFor waku.start()).isOkOr:
      raiseAssert error

    let portsJson = waku.stateInfo.getNodeInfoItem(NodeInfoId.MyBoundPorts)
    let parsed = parseJson(portsJson)

    check:
      parsed.kind == JObject
      parsed["tcp"].getInt() != 0
      parsed["webSocket"].getInt() != 0
      parsed["rest"].getInt() != 0
      parsed["discv5Udp"].getInt() != 0
      parsed["metrics"].getInt() != 0

  test "QUIC port=0 auto-binds and advertises the real port":
    var builder = defaultTestWakuConfBuilder()
    builder.withP2pListenAddress(parseIpAddress("127.0.0.1"))
    builder.withP2pTcpPort(Port(0))
    builder.quicConf.withEnabled(true)
    builder.quicConf.withQuicPort(Port(0))

    let conf = builder.build().valueOr:
      raiseAssert error
    check conf.quicConf.get().port == Port(0)

    var waku = (waitFor Waku.new(conf)).valueOr:
      raiseAssert error
    defer:
      (waitFor waku.stop()).isOkOr:
        raiseAssert error

    (waitFor waku.start()).isOkOr:
      raiseAssert error

    let parsed = parseJson(waku.stateInfo.getNodeInfoItem(NodeInfoId.MyBoundPorts))
    check parsed["quic"].getInt() != 0

    let quicAddrs = waku.node.announcedAddresses.filterIt("/quic-v1" in $it)
    check:
      quicAddrs.len >= 1
      quicAddrs.allIt("/udp/0/quic-v1" notin $it)

  test "portsShift is applied exactly once":
    # The announced port must equal the bound port, not bound + portsShift.
    const shift = 5'u16

    # Reserve a free port, then set base = port - shift so base + shift binds onto it.
    let boundTarget = block:
      let sock = newSocket()
      defer:
        sock.close()
      sock.bindAddr(Port(0), "127.0.0.1")
      sock.getLocalAddr()[1]
    doAssert boundTarget.uint16 > shift, "ephemeral port unexpectedly low"

    var builder = defaultTestWakuConfBuilder()
    builder.withP2pListenAddress(parseIpAddress("127.0.0.1"))
    builder.withP2pTcpPort(Port(boundTarget.uint16 - shift))
    builder.withPortsShift(shift)

    let conf = builder.build().valueOr:
      raiseAssert error

    var waku = (waitFor Waku.new(conf)).valueOr:
      raiseAssert error
    defer:
      (waitFor waku.stop()).isOkOr:
        raiseAssert error

    (waitFor waku.start()).isOkOr:
      raiseAssert error

    let typedEnr = waku.node.enr.toTyped().valueOr:
      raiseAssert $error
    let announcedTcp = typedEnr.tcp()

    check:
      announcedTcp.isSome()
      waku.node.ports.tcp == boundTarget.uint16
      announcedTcp.get() == waku.node.ports.tcp
