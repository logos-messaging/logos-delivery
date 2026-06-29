{.used.}

import std/options
import testutils/unittests, chronos, chronicles
import libp2p/switch

import logos_delivery/waku/[waku_node, waku_core, node/peer_manager]
import ../testlib/[wakucore, wakunode, testasync]

suite "WakuNode - restart (#3979)":
  asyncTest "start -> stop -> start re-opens the listener promptly":
    ## A restart must not block on the relay-reconnect backoff.
    let
      node1 =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      node2 =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))

    (await node1.mountRelay()).isOkOr:
      raiseAssert "mountRelay node1: " & error
    (await node2.mountRelay()).isOkOr:
      raiseAssert "mountRelay node2: " & error

    await allFutures(node1.start(), node2.start())

    # node1 learns node2 as a relay peer, so a restart triggers reconnectRelayPeers.
    await node1.connectToNodes(@[node2.peerInfo.toRemotePeerInfo()])

    await node1.stop()

    # The restart must complete promptly and yield a usable, listening node.
    let startFut = node1.start()
    let restarted = await startFut.withTimeout(20.seconds)
    if not restarted:
      await startFut.cancelAndWait()

    check:
      restarted
      node1.started
      node1.switch.peerInfo.listenAddrs.len > 0

    await allFutures(node1.stop(), node2.stop())
