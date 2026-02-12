{.used.}

import std/strutils
import chronos, testutils/unittests, stew/byteutils, libp2p/[switch, peerinfo]
import ../testlib/[common, wakucore, wakunode, testasync]
import ../waku_archive/archive_utils
import
  waku, waku/[waku_node, waku_core, waku_relay/protocol, common/broker/broker_context]
import waku/api/api_conf, waku/factory/waku_conf

type SendEventOutcome {.pure.} = enum
  Sent
  Propagated
  Error

type SendEventListenerManager = ref object
  brokerCtx: BrokerContext
  sentListener: MessageSentEventListener
  errorListener: MessageErrorEventListener
  propagatedListener: MessagePropagatedEventListener
  sentFuture: Future[void]
  errorFuture: Future[void]
  propagatedFuture: Future[void]
  sentCount: int
  errorCount: int
  propagatedCount: int
  sentRequestIds: seq[RequestId]
  errorRequestIds: seq[RequestId]
  propagatedRequestIds: seq[RequestId]

proc newSendEventListenerManager(brokerCtx: BrokerContext): SendEventListenerManager =
  let manager = SendEventListenerManager(brokerCtx: brokerCtx)
  manager.sentFuture = newFuture[void]("sentEvent")
  manager.errorFuture = newFuture[void]("errorEvent")
  manager.propagatedFuture = newFuture[void]("propagatedEvent")

  manager.sentListener = MessageSentEvent.listen(
    brokerCtx,
    proc(event: MessageSentEvent) {.async: (raises: []).} =
      inc manager.sentCount
      manager.sentRequestIds.add(event.requestId)
      echo "SENT EVENT TRIGGERED (#",
        manager.sentCount, "): requestId=", event.requestId
      if not manager.sentFuture.finished():
        manager.sentFuture.complete()
    ,
  ).valueOr:
    raiseAssert error

  manager.errorListener = MessageErrorEvent.listen(
    brokerCtx,
    proc(event: MessageErrorEvent) {.async: (raises: []).} =
      inc manager.errorCount
      manager.errorRequestIds.add(event.requestId)
      echo "ERROR EVENT TRIGGERED (#", manager.errorCount, "): ", event.error
      if not manager.errorFuture.finished():
        manager.errorFuture.fail(
          newException(CatchableError, "Error event triggered: " & event.error)
        )
    ,
  ).valueOr:
    raiseAssert error

  manager.propagatedListener = MessagePropagatedEvent.listen(
    brokerCtx,
    proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
      inc manager.propagatedCount
      manager.propagatedRequestIds.add(event.requestId)
      echo "PROPAGATED EVENT TRIGGERED (#",
        manager.propagatedCount, "): requestId=", event.requestId
      if not manager.propagatedFuture.finished():
        manager.propagatedFuture.complete()
    ,
  ).valueOr:
    raiseAssert error

  return manager

proc teardown(manager: SendEventListenerManager) =
  MessageSentEvent.dropListener(manager.brokerCtx, manager.sentListener)
  MessageErrorEvent.dropListener(manager.brokerCtx, manager.errorListener)
  MessagePropagatedEvent.dropListener(manager.brokerCtx, manager.propagatedListener)

proc waitForEvents(
    manager: SendEventListenerManager, timeout: Duration
): Future[bool] {.async.} =
  return await allFutures(
    manager.sentFuture, manager.propagatedFuture, manager.errorFuture
  )
  .withTimeout(timeout)

proc outcomes(manager: SendEventListenerManager): set[SendEventOutcome] =
  if manager.sentFuture.completed():
    result.incl(SendEventOutcome.Sent)
  if manager.propagatedFuture.completed():
    result.incl(SendEventOutcome.Propagated)
  if manager.errorFuture.failed():
    result.incl(SendEventOutcome.Error)

proc validate(manager: SendEventListenerManager, expected: set[SendEventOutcome]) =
  echo "EVENT COUNTS: sent=",
    manager.sentCount, ", propagated=", manager.propagatedCount, ", error=",
    manager.errorCount
  check manager.outcomes() == expected

proc validate(
    manager: SendEventListenerManager,
    expected: set[SendEventOutcome],
    expectedRequestId: RequestId,
) =
  manager.validate(expected)
  for requestId in manager.sentRequestIds:
    check requestId == expectedRequestId
  for requestId in manager.propagatedRequestIds:
    check requestId == expectedRequestId
  for requestId in manager.errorRequestIds:
    check requestId == expectedRequestId

proc createApiNodeConf(mode: WakuMode = WakuMode.Core): NodeConfig =
  # allocate random ports to avoid port-already-in-use errors
  let netConf = NetworkingConfig(listenIpv4: "0.0.0.0", p2pTcpPort: 0, discv5UdpPort: 0)

  result = NodeConfig.init(
    mode = mode,
    protocolsConfig = ProtocolsConfig.init(
      entryNodes = @[],
      clusterId = 1,
      autoShardingConfig = AutoShardingConfig(numShardsInCluster: 1),
    ),
    networkingConfig = netConf,
    p2pReliability = true,
  )

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
    lockNewGlobalBrokerContext:
      relayNode1 =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      relayNode1.mountMetadata(1, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await relayNode1.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      await relayNode1.mountLibp2pPing()
      await relayNode1.start()

    lockNewGlobalBrokerContext:
      relayNode2 =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      relayNode2.mountMetadata(1, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await relayNode2.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      await relayNode2.mountLibp2pPing()
      await relayNode2.start()

    lockNewGlobalBrokerContext:
      lightpushNode =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      lightpushNode.mountMetadata(1, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await lightpushNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      (await lightpushNode.mountLightPush()).isOkOr:
        raiseAssert "Failed to mount lightpush"
      await lightpushNode.mountLibp2pPing()
      await lightpushNode.start()

    lockNewGlobalBrokerContext:
      storeNode =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      storeNode.mountMetadata(1, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await storeNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      # Mount archive so store can persist messages
      let archiveDriver = newSqliteArchiveDriver()
      storeNode.mountArchive(archiveDriver).isOkOr:
        raiseAssert "Failed to mount archive: " & error
      await storeNode.mountStore()
      await storeNode.mountLibp2pPing()
      await storeNode.start()

    relayNode1PeerInfo = relayNode1.peerInfo.toRemotePeerInfo()
    relayNode1PeerId = relayNode1.peerInfo.peerId

    relayNode2PeerInfo = relayNode2.peerInfo.toRemotePeerInfo()
    relayNode2PeerId = relayNode2.peerInfo.peerId

    lightpushNodePeerInfo = lightpushNode.peerInfo.toRemotePeerInfo()
    lightpushNodePeerId = lightpushNode.peerInfo.peerId

    storeNodePeerInfo = storeNode.peerInfo.toRemotePeerInfo()
    storeNodePeerId = storeNode.peerInfo.peerId

    # Subscribe all relay nodes to the default shard topic
    const testPubsubTopic = PubsubTopic("/waku/2/rs/1/0")
    proc dummyHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      discard

    relayNode1.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe relayNode1: " & error
    relayNode2.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe relayNode2: " & error

    lightpushNode.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe lightpushNode: " & error
    storeNode.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe storeNode: " & error

    # Subscribe all relay nodes to the default shard topic
    await relayNode1.connectToNodes(@[relayNode2PeerInfo, storeNodePeerInfo])
    await lightpushNode.connectToNodes(@[relayNode2PeerInfo])

  asyncTeardown:
    await allFutures(
      relayNode1.stop(), relayNode2.stop(), lightpushNode.stop(), storeNode.stop()
    )

  asyncTest "Check API availability (unhealthy node)":
    var node: Waku
    lockNewGlobalBrokerContext:
      node = (await createNode(createApiNodeConf())).valueOr:
        raiseAssert error
      (await startWaku(addr node)).isOkOr:
        raiseAssert "Failed to start Waku node: " & error
      # node is not connected !

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let sendResult = await node.send(envelope)

    # TODO: The API is not enforcing a health check before the send,
    #       so currently this test cannot successfully fail to send.
    check sendResult.isOk()

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send fully validated":
    var node: Waku
    lockNewGlobalBrokerContext:
      node = (await createNode(createApiNodeConf())).valueOr:
        raiseAssert error
      (await startWaku(addr node)).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.node.connectToNodes(
        @[relayNode1PeerInfo, lightpushNodePeerInfo, storeNodePeerInfo]
      )

    let eventManager = newSendEventListenerManager(node.brokerCtx)
    defer:
      eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.send(envelope)).valueOr:
      raiseAssert error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate(
      {SendEventOutcome.Sent, SendEventOutcome.Propagated}, requestId
    )

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send only propagates":
    var node: Waku
    lockNewGlobalBrokerContext:
      node = (await createNode(createApiNodeConf())).valueOr:
        raiseAssert error
      (await startWaku(addr node)).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.node.connectToNodes(@[relayNode1PeerInfo])

    let eventManager = newSendEventListenerManager(node.brokerCtx)
    defer:
      eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.send(envelope)).valueOr:
      raiseAssert error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated}, requestId)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send only propagates fallback to lightpush":
    var node: Waku
    lockNewGlobalBrokerContext:
      node = (await createNode(createApiNodeConf())).valueOr:
        raiseAssert error
      (await startWaku(addr node)).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.node.connectToNodes(@[lightpushNodePeerInfo])

    let eventManager = newSendEventListenerManager(node.brokerCtx)
    defer:
      eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.send(envelope)).valueOr:
      raiseAssert error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated}, requestId)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send fully validates fallback to lightpush":
    var node: Waku
    lockNewGlobalBrokerContext:
      node = (await createNode(createApiNodeConf())).valueOr:
        raiseAssert error
      (await startWaku(addr node)).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.node.connectToNodes(@[lightpushNodePeerInfo, storeNodePeerInfo])

    let eventManager = newSendEventListenerManager(node.brokerCtx)
    defer:
      eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.send(envelope)).valueOr:
      raiseAssert error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate(
      {SendEventOutcome.Propagated, SendEventOutcome.Sent}, requestId
    )
    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send fails with event":
    var fakeLightpushNode: WakuNode
    lockNewGlobalBrokerContext:
      fakeLightpushNode =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      fakeLightpushNode.mountMetadata(1, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await fakeLightpushNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      (await fakeLightpushNode.mountLightPush()).isOkOr:
        raiseAssert "Failed to mount lightpush"
      await fakeLightpushNode.mountLibp2pPing()
      await fakeLightpushNode.start()
    let fakeLightpushNodePeerInfo = fakeLightpushNode.peerInfo.toRemotePeerInfo()
    proc dummyHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      discard

    fakeLightpushNode.subscribe(
      (kind: PubsubSub, topic: PubsubTopic("/waku/2/rs/1/0")), dummyHandler
    ).isOkOr:
      raiseAssert "Failed to subscribe fakeLightpushNode: " & error

    var node: Waku
    lockNewGlobalBrokerContext:
      node = (await createNode(createApiNodeConf(WakuMode.Edge))).valueOr:
        raiseAssert error
      (await startWaku(addr node)).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.node.connectToNodes(@[fakeLightpushNodePeerInfo])

    let eventManager = newSendEventListenerManager(node.brokerCtx)
    defer:
      eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.send(envelope)).valueOr:
      raiseAssert error

    echo "Sent message with requestId=", requestId
    # Wait for events with timeout
    const eventTimeout = 62.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Error}, requestId)
    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error
