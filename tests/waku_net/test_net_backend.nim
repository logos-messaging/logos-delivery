{.used.}

import results, testutils/unittests, chronos, chronicles
import libp2p/[multiaddress, peerid]
import libp2p/protocols/protocol

import
  logos_delivery/waku/[net/net_backend, node/peer_manager, waku_core, waku_core/codecs],
  ../testlib/[wakucore, testasync]

const
  TestCodec = "/waku/test/1.0.0"
  EchoCodec = "/waku/test-echo/1.0.0"

const StubAnswer = @[byte 9, 9, 9]

type StubNetBackend = ref object of NetBackend
  dials: int
  connects: int
  requests: int
  lastPeerId: PeerId
  lastAddrs: seq[MultiAddress]
  lastProto: string
  lastPayload: seq[byte]

method dial(
    backend: StubNetBackend,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    proto: string,
    timeout: Duration,
): Future[Opt[Connection]] {.async: (raises: []).} =
  backend.dials.inc()
  backend.lastPeerId = peerId
  backend.lastAddrs = addrs
  backend.lastProto = proto

  return Opt.none(Connection)

method connect(
    backend: StubNetBackend, peerId: PeerId, addrs: seq[MultiAddress], timeout: Duration
): Future[Result[void, string]] {.async: (raises: []).} =
  backend.connects.inc()
  backend.lastPeerId = peerId
  backend.lastAddrs = addrs

  return err("the stub connects to nobody")

method request(
    backend: StubNetBackend, req: NetRequest
): Future[Result[seq[byte], NetError]] {.async: (raises: []).} =
  backend.requests.inc()
  backend.lastPeerId = req.peerId
  backend.lastAddrs = req.addrs
  backend.lastProto = req.proto
  backend.lastPayload = req.payload

  return ok(StubAnswer)

suite "Net backend":
  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch
  var serverPeerInfo {.threadvar.}: RemotePeerInfo

  asyncSetup:
    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()

    proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      await conn.close()

    proc echoBack(
        conn: Connection, proto: string
    ) {.async: (raises: [CancelledError]).} =
      try:
        let request = await conn.readLp(DefaultNetMaxResponseSize)
        await conn.writeLP(request & request)
      except CatchableError as e:
        error "echo handler failed", err = e.msg

      await conn.close()

    serverSwitch.mount(LPProtocol.new(@[TestCodec], handle))
    serverSwitch.mount(LPProtocol.new(@[EchoCodec], echoBack))

    await allFutures(serverSwitch.start(), clientSwitch.start())
    await sleepAsync(500.millis) # the listener is not ready on macos CI without it

    serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "the default backend dials over the switch":
    let peerManager = PeerManager.new(clientSwitch)

    check peerManager.netBackend of SwitchNetBackend

    let conn = await peerManager.dialPeer(serverPeerInfo, TestCodec)

    check conn.isSome()
    await conn.get().close()

  asyncTest "a backend of its own takes every dial":
    let backend = StubNetBackend()
    let peerManager = PeerManager.new(clientSwitch, netBackend = backend)

    let conn = await peerManager.dialPeer(serverPeerInfo, TestCodec)

    check:
      conn.isNone()
      backend.dials == 1
      backend.lastPeerId == serverPeerInfo.peerId
      backend.lastAddrs == serverPeerInfo.addrs
      backend.lastProto == TestCodec

  asyncTest "a request writes one frame and reads the answer":
    let peerManager = PeerManager.new(clientSwitch)

    let response = await peerManager.request(serverPeerInfo, EchoCodec, @[byte 1, 2, 3])

    check:
      response.isOk()
      response.get() == @[byte 1, 2, 3, 1, 2, 3]

  asyncTest "a request to an undialable peer fails with a dial error":
    let peerManager = PeerManager.new(clientSwitch)
    let unreachable = RemotePeerInfo.init(
      serverPeerInfo.peerId, @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()]
    )

    let response = await peerManager.request(unreachable, TestCodec, @[byte 1])

    check:
      response.isErr()
      response.error.kind == NetErrorKind.Dial

  asyncTest "an answer over maxSize fails with a read error":
    let peerManager = PeerManager.new(clientSwitch)

    let response =
      await peerManager.request(serverPeerInfo, EchoCodec, @[byte 1, 2, 3], maxSize = 2)

    check:
      response.isErr()
      response.error.kind == NetErrorKind.Read

  asyncTest "a request to self is refused without a dial":
    let backend = StubNetBackend()
    let peerManager = PeerManager.new(clientSwitch, netBackend = backend)

    let response = await peerManager.request(
      clientSwitch.peerInfo.toRemotePeerInfo(), TestCodec, @[byte 1]
    )

    check:
      response.isErr()
      response.error.kind == NetErrorKind.Dial
      backend.requests == 0

  asyncTest "the default backend connects over the switch":
    let peerManager = PeerManager.new(clientSwitch)

    check (await peerManager.connectPeer(serverPeerInfo))

  asyncTest "a connect to an unreachable peer fails":
    let peerManager = PeerManager.new(clientSwitch)
    let unreachable = RemotePeerInfo.init(
      serverPeerInfo.peerId, @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()]
    )

    check not (await peerManager.connectPeer(unreachable, dialTimeout = 2.seconds))

  asyncTest "a backend of its own takes every connect":
    let backend = StubNetBackend()
    let peerManager = PeerManager.new(clientSwitch, netBackend = backend)

    check not (await peerManager.connectPeer(serverPeerInfo))
    check backend.connects == 1

  asyncTest "a request never reaches the relay codec":
    let backend = StubNetBackend()
    let peerManager = PeerManager.new(clientSwitch, netBackend = backend)

    let response = await peerManager.request(serverPeerInfo, WakuRelayCodec, @[byte 1])

    check:
      response.isErr()
      response.error.kind == NetErrorKind.Dial
      backend.requests == 0

  asyncTest "a backend of its own answers a request without dialing":
    let backend = StubNetBackend()
    let peerManager = PeerManager.new(clientSwitch, netBackend = backend)

    let response = await peerManager.request(serverPeerInfo, TestCodec, @[byte 1, 2, 3])

    check:
      response.isOk()
      response.get() == StubAnswer
      backend.requests == 1
      backend.dials == 0
      backend.lastPeerId == serverPeerInfo.peerId
      backend.lastAddrs == serverPeerInfo.addrs
      backend.lastProto == TestCodec
      backend.lastPayload == @[byte 1, 2, 3]
