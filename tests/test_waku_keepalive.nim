{.used.}

import
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/switch,
  libp2p/protocols/ping,
  libp2p/protocols/protocol,
  libp2p/stream/bufferstream,
  libp2p/stream/connection,
  libp2p/crypto/crypto
import
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_node,
  logos_delivery/waku/node/health_monitor,
  logos_delivery/waku/node/waku_node/ping,
  ./testlib/futures,
  ./testlib/wakucore,
  ./testlib/wakunode

proc pingServer(clientClosed: Future[void], wrongAnswer: bool): LPProtocol =
  ## Answers one ping, with wrong data when `wrongAnswer` is set.
  ## Completes `clientClosed` when the client closes its side of the stream.
  proc handle(stream: Stream, proto: string) {.async: (raises: [CancelledError]).} =
    var buf: array[32, byte]
    try:
      await stream.readExactly(addr buf[0], buf.len)
      if wrongAnswer:
        buf[0] = not buf[0]
      await stream.write(@buf)
      if (await stream.readOnce(addr buf[0], buf.len)) == 0 and
          not clientClosed.finished():
        clientClosed.complete()
    except LPStreamError:
      discard
    await stream.close()

  return LPProtocol.new(@[PingCodec], handle)

proc pingOnce(wrongAnswer: bool): Future[tuple[pings: int, closed: bool]] {.async.} =
  ## Pings a node that answers one ping.
  ## Gives the number of good pings, and whether the client closed its stream.
  let
    node1 = newTestWakuNode(generateSecp256k1Key())
    node2 = newTestWakuNode(generateSecp256k1Key())
    clientClosed = newFuture[void]("the ping client closed its stream")
  await node1.start()
  await node1.mountLibp2pPing()
  await node2.start()
  let server = pingServer(clientClosed, wrongAnswer)
  await server.start()
  node2.switch.mount(server)
  await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

  let pings = await node1.parallelPings(@[node2.switch.peerInfo.peerId])
  let closed = await clientClosed.withTimeout(FUTURE_TIMEOUT)
  await node2.stop()
  await node1.stop()
  return (pings, closed)

suite "Waku Keepalive":
  asyncTest "handle ping keepalives":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1)
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2)

    var completionFut = newFuture[bool]()

    proc pingHandler(peerId: PeerID) {.async: (raises: []), gcsafe.} =
      info "Ping received"

      # check raises on failure and this handler allows no raises, so
      # complete the future with the comparison and check it below.
      completionFut.complete(peerId == node1.switch.peerInfo.peerId)

    await node1.start()
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await node1.mountLibp2pPing()

    await node2.start()
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    let pingProto = Ping.new(handler = pingHandler, rng = crypto.newRng())
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

  asyncTest "a ping closes its stream":
    # A keepalive ping runs on every round of the keepalive loop.
    # A stream that the ping leaves open stays open until the peer disconnects.
    let res = await pingOnce(wrongAnswer = false)
    check:
      res.pings == 1
      res.closed

  asyncTest "a failed ping closes its stream":
    # The ping raises inside the scope of the `defer`, which must close the stream.
    let res = await pingOnce(wrongAnswer = true)
    check:
      res.pings == 0
      res.closed
