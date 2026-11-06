{.used.}

import results, stew/byteutils, testutils/unittests, chronos
import
  logos_delivery/waku/[waku_core, node/peer_manager, waku_node, waku_relay],
  ../testlib/wakucore,
  ../testlib/wakunode

suite "Issue 2998 - duplicate after seenTTL":
  asyncTest "same message re-published by another node":
    let
      node1 = newTestWakuNode(generateSecp256k1Key())
      node2 = newTestWakuNode(generateSecp256k1Key())
      node3 = newTestWakuNode(generateSecp256k1Key())
      shard = DefaultRelayShard
      message = WakuMessage(
        payload: "dup".toBytes(),
        contentTopic: ContentTopic("/waku/2/default-content/proto"),
        timestamp: now(),
      )

    for n in [node1, node2, node3]:
      await n.start()
      (await n.mountRelay()).isOkOr:
        assert false, "mount relay failed: " & $error

    await allFutures(
      node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()]),
      node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()]),
    )

    var received = 0
    proc counter(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      inc received

    proc noop(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      discard

    node1.subscribe((kind: PubsubSub, topic: $shard), noop).isOkOr:
      assert false, $error
    node2.subscribe((kind: PubsubSub, topic: $shard), noop).isOkOr:
      assert false, $error
    node3.subscribe((kind: PubsubSub, topic: $shard), counter).isOkOr:
      assert false, $error
    await sleepAsync(2.seconds)

    check (await node1.publish(Opt.some($shard), message)).isOk()
    await sleepAsync(2.seconds)
    check received == 1

    # within seenTTL: node2 re-sends -> must be dropped
    discard await node2.publish(Opt.some($shard), message)
    await sleepAsync(2.seconds)
    echo "received within seenTTL: ", received
    check received == 1

    # after seenTTL (2 min): slow node2 flushes the same message again
    await sleepAsync(chronos.seconds(130))
    echo "node2 peers before late publish: ",
      node2.peerManager.switch.connectedPeers(Direction.Out).len,
      "/",
      node2.peerManager.switch.connectedPeers(Direction.In).len
    await allFutures(
      node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()]),
      node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()]),
    )
    await sleepAsync(3.seconds)
    let late = await node2.publish(Opt.some($shard), message)
    echo "late publish result: ", late
    await sleepAsync(3.seconds)
    echo "received after seenTTL: ", received

    await allFutures(node1.stop(), node2.stop(), node3.stop())
