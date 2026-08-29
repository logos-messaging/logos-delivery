{.used.}

import results, testutils/unittests, chronos, chronicles
import libp2p/[multiaddress, peerid]
import libp2p/protocols/protocol

import
  logos_delivery/waku/[net/net_backend, node/peer_manager, waku_core],
  ../testlib/[wakucore, testasync]

const TestCodec = "/waku/test/1.0.0"

type StubNetBackend = ref object of NetBackend
  dials: int
  lastPeerId: PeerId
  lastAddrs: seq[MultiAddress]
  lastProto: string

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

suite "Net backend":
  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch
  var serverPeerInfo {.threadvar.}: RemotePeerInfo

  asyncSetup:
    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()

    proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
      await conn.close()

    serverSwitch.mount(LPProtocol.new(@[TestCodec], handle))

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
