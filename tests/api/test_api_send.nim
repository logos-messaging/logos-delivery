{.used.}

import
  std/[options, sequtils, strutils],
  chronos,
  testutils/unittests,
  stew/byteutils,
  libp2p/[switch, peerinfo]
import ../testlib/[common, wakucore, wakunode, testasync, futures, testutils]
import
  waku,
  waku/
    [
      waku_node,
      waku_core,
      waku_relay/protocol,
      waku_filter_v2/common,
      waku_store/common,
    ]
import waku/api/api_conf, waku/factory/waku_conf, waku/factory/networks_config

suite "Waku API - Send":
  var
    relayNode1 {.threadvar.}: WakuNode
    relayNode1PeerInfo {.threadvar.}: RemotePeerInfo
    relayNode1PeerId {.threadvar.}: PeerId

    relayNode2 {.threadvar.}: WakuNode
    relayNode2PeerInfo {.threadvar.}: RemotePeerInfo
    relayNode2PeerId {.threadvar.}: PeerId

    lightpushNode {.threadvar.}: WakuNode
    lightpushNodePeerInfo {.threadvar.}: RemotePeerInfo
    lightpushNodePeerId {.threadvar.}: PeerId

    storeNode {.threadvar.}: WakuNode
    storeNodePeerInfo {.threadvar.}: RemotePeerInfo
    storeNodePeerId {.threadvar.}: PeerId

  asyncSetup:
    # handlerFuture = newPushHandlerFuture()
    # handler = proc(
    #     peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    # ): Future[WakuLightPushResult[void]] {.async.} =
    #   handlerFuture.complete((pubsubTopic, message))
    #   return ok()

    relayNode1 =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
    relayNode2 =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))

    lightpushNode =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
    storeNode =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))

    await allFutures(
      relayNode1.start(), relayNode2.start(), lightpushNode.start(), storeNode.start()
    )

    (await relayNode1.mountRelay()).isOkOr:
      raiseAssert "Failed to mount relay"

    (await relayNode2.mountRelay()).isOkOr:
      raiseAssert "Failed to mount relay"

    (await lightpushNode.mountRelay()).isOkOr:
      raiseAssert "Failed to mount relay"
    (await lightpushNode.mountLightPush()).isOkOr:
      raiseAssert "Failed to mount lightpush"

    (await storeNode.mountRelay()).isOkOr:
      raiseAssert "Failed to mount relay"
    await storeNode.mountStore()

    relayNode1PeerInfo = relayNode1.peerInfo.toRemotePeerInfo()
    relayNode1PeerId = relayNode1.peerInfo.peerId

    relayNode2PeerInfo = relayNode2.peerInfo.toRemotePeerInfo()
    relayNode2PeerId = relayNode2.peerInfo.peerId

    lightpushNodePeerInfo = lightpushNode.peerInfo.toRemotePeerInfo()
    lightpushNodePeerId = lightpushNode.peerInfo.peerId

    storeNodePeerInfo = storeNode.peerInfo.toRemotePeerInfo()
    storeNodePeerId = storeNode.peerInfo.peerId
  asyncTeardown:
    await allFutures(
      relayNode1.stop(), relayNode2.stop(), lightpushNode.stop(), storeNode.stop()
    )

  asyncTest "Check API availability (unhealthy node)":
    # Create a node config that doesn't start or has no peers
    let nodeConfig = NodeConfig.init(
      mode = WakuMode.Core,
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = @[],
        clusterId = 1,
        autoShardingConfig = AutoShardingConfig(numShardsInCluster: 1),
      ),
    )

    let wakuConfRes = toWakuConf(nodeConfig)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 1
      wakuConf.shardingConf.numShardsInCluster == 1

    var node = (await createNode(nodeConfig)).valueOr:
      raiseAssert error

    let sentListener = MessageSentEvent.listen(
      proc(event: MessageSentEvent) {.async: (raises: []).} =
        raiseAssert "Should not be called"
    ).valueOr:
      raiseAssert error

    let errorListener = MessageErrorEvent.listen(
      proc(event: MessageErrorEvent) {.async: (raises: []).} =
        check true
    ).valueOr:
      raiseAssert error

    let propagatedListener = MessagePropagatedEvent.listen(
      proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
        raiseAssert "Should not be called"
    ).valueOr:
      raiseAssert error
    defer:
      MessageSentEvent.dropListener(sentListener)
      MessageErrorEvent.dropListener(errorListener)
      MessagePropagatedEvent.dropListener(propagatedListener)

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let sendResult = await node.send(envelope)

    if sendResult.isErr():
      echo "Send error: ", sendResult.error

    check:
      sendResult.isErr()
      # Depending on implementation, it might say "not healthy"
      sendResult.error.contains("not healthy")

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error
