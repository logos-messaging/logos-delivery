{.used.}

import
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/switch,
  libp2p/protocols/ping,
  libp2p/stream/bufferstream,
  libp2p/stream/connection,
  libp2p/crypto/crypto
import waku/waku_core, waku/waku_node, ./testlib/wakucore, ./testlib/wakunode

suite "Waku Keepalive":
  asyncTest "handle ping keepalives":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))

    var completionFut = newFuture[bool]()

    proc pingHandler(peerId: PeerID) {.async, gcsafe.} =
      info "Ping received"

      check:
        peerId == node1.switch.peerInfo.peerId

      completionFut.complete(true)

    await node1.start()
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await node1.mountLibp2pPing()

    await node2.start()
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    let pingProto = Ping.new(handler = pingHandler)
    await pingProto.start()
    node2.switch.mount(pingProto)

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    let healthMonitor = NodeHealthMonitor.new(node1)
    healthMonitor.startKeepalive(2.seconds).isOkOr:
      assert false, "Failed to start keepalive"

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await node2.stop()
    await node1.stop()
