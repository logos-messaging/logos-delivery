{.used.}

import
  std/json,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/[crypto/crypto, crypto/secp, multiaddress, switch],
  tests/testlib/[wakucore, wakunode],
  waku/factory/conf_builder/conf_builder

include waku/factory/waku, waku/common/enr/typed_record

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

    (waitFor startWaku(addr waku)).isOkOr:
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

    (waitFor startWaku(addr waku)).isOkOr:
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

  test "MyBoundPorts should report a bound port for each enabled service":
    var builder = defaultTestWakuConfBuilder()
    builder.discv5Conf.withEnabled(true)
    builder.restServerConf.withEnabled(true)
    builder.restServerConf.withPort(Port(0))
    builder.restServerConf.withRelayCacheCapacity(50'u32)
    builder.metricsServerConf.withEnabled(true)
    builder.webSocketConf.withEnabled(true)
    builder.webSocketConf.withWebSocketPort(Port(0))

    let conf = builder.build().valueOr:
      raiseAssert error

    var waku = (waitFor Waku.new(conf)).valueOr:
      raiseAssert error
    defer:
      (waitFor waku.stop()).isOkOr:
        raiseAssert error

    (waitFor startWaku(addr waku)).isOkOr:
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
