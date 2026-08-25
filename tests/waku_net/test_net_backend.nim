{.used.}

import results, testutils/unittests, chronos, chronicles
import libp2p/[multiaddress, peerid]
import libp2p/protocols/protocol

import
  logos_delivery/waku/[node/peer_manager, waku_core, waku_core/codecs],
  ../testlib/[wakucore, testasync]

const
  TestCodec = "/waku/test/1.0.0"
  EchoCodec = "/waku/test-echo/1.0.0"

type StubNetBackend = ref object of NetBackend
  dials: int
  lastProto: string

method dial*(
    backend: StubNetBackend,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    proto: string,
    timeout: Duration,
): Future[Opt[Connection]] {.async: (raises: []).} =
  backend.dials.inc()
  backend.lastProto = proto

  return Opt.none(Connection)

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
      except CatchableError:
        discard

      await conn.close()

    serverSwitch.mount(LPProtocol.new(@[TestCodec], handle))
    serverSwitch.mount(LPProtocol.new(@[EchoCodec], echoBack))

    await allFutures(serverSwitch.start(), clientSwitch.start())
    await sleepAsync(500.millis)

    serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "the default backend dials over the switch":
    let peerManager = PeerManager.new(clientSwitch)

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
      backend.lastProto == TestCodec

  asyncTest "a request writes one frame and reads the answer":
    let peerManager = PeerManager.new(clientSwitch)

    let response = await peerManager.request(serverPeerInfo, EchoCodec, @[byte 1, 2, 3])

    check:
      response.isOk()
      response.get() == @[byte 1, 2, 3, 1, 2, 3]

  asyncTest "a request that expects no answer returns as soon as it is written":
    let peerManager = PeerManager.new(clientSwitch)

    let response = await peerManager.request(
      serverPeerInfo, EchoCodec, @[byte 1, 2, 3], expectResponse = false
    )

    check:
      response.isOk()
      response.get().len == 0

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
      backend.dials == 0

  asyncTest "a request never reaches the relay codec":
    let backend = StubNetBackend()
    let peerManager = PeerManager.new(clientSwitch, netBackend = backend)

    let response = await peerManager.request(serverPeerInfo, WakuRelayCodec, @[byte 1])

    check:
      response.isErr()
      response.error.kind == NetErrorKind.Dial
      backend.dials == 0
