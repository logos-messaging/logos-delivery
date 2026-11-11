{.used.}

import results, std/[importutils, os, sequtils, sets, tempfiles]
import chronos, testutils/unittests, stew/byteutils, libp2p/[switch, peerinfo], metrics
import brokers/broker_context
import
  ../testlib/[
    futures, wakucore, wakunode, wakunodeconf, testasync, short_intervals, rest_service,
    messaging_send,
  ]
import ../waku_archive/archive_utils
import ../waku_lightpush/lightpush_utils
import
  logos_delivery,
  logos_delivery/waku/[
    waku_node,
    waku_core,
    waku_lightpush/common,
    waku_lightpush/rpc,
    waku_lightpush/protocol_metrics,
    waku_archive,
    waku_archive/archive_metrics,
    node/peer_manager,
  ],
  rest/server,
  rest/client,
  rest/kernel_api/relay/client as relay_rest_client
import logos_delivery/waku/api/[subscriptions, publish]
import logos_delivery/waku/rln/[rln_api, rln_plugin]
import tools/confutils/cli_args
import logos_delivery/api/conf/messaging_conf
import logos_delivery/api/events/messaging_client_events
import
  logos_delivery/messaging/delivery_service/send_service/[send_service, send_processor]

privateAccess(SendService) # the test reads `sendsEnded`
import logos_delivery/api/messaging_client_api
import logos_delivery/messaging/messaging_client_lifecycle

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
  sentHashes: seq[string]
  errorHashes: seq[string]
  errorKinds: seq[MessageErrorKind]
  errorDescs: seq[string]
  propagatedHashes: seq[string]

proc newSendEventListenerManager(brokerCtx: BrokerContext): SendEventListenerManager =
  let manager = SendEventListenerManager(brokerCtx: brokerCtx)
  manager.sentFuture = newFuture[void]("sentEvent")
  manager.errorFuture = newFuture[void]("errorEvent")
  manager.propagatedFuture = newFuture[void]("propagatedEvent")

  manager.sentListener = MessageSentEvent.listen(
    brokerCtx,
    proc(event: MessageSentEvent) {.async: (raises: []).} =
      inc manager.sentCount
      manager.sentHashes.add(event.messageHash)
      echo "SENT EVENT TRIGGERED (#",
        manager.sentCount, "): messageHash=", event.messageHash
      if not manager.sentFuture.finished():
        manager.sentFuture.complete()
    ,
  ).valueOr:
    raiseAssert error

  manager.errorListener = MessageErrorEvent.listen(
    brokerCtx,
    proc(event: MessageErrorEvent) {.async: (raises: []).} =
      inc manager.errorCount
      manager.errorHashes.add(event.messageHash)
      manager.errorKinds.add(event.kind)
      manager.errorDescs.add(event.error)
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
      manager.propagatedHashes.add(event.messageHash)
      echo "PROPAGATED EVENT TRIGGERED (#",
        manager.propagatedCount, "): messageHash=", event.messageHash
      if not manager.propagatedFuture.finished():
        manager.propagatedFuture.complete()
    ,
  ).valueOr:
    raiseAssert error

  return manager

proc teardown(manager: SendEventListenerManager) {.async.} =
  await MessageSentEvent.dropListener(manager.brokerCtx, manager.sentListener)
  await MessageErrorEvent.dropListener(manager.brokerCtx, manager.errorListener)
  await MessagePropagatedEvent.dropListener(
    manager.brokerCtx, manager.propagatedListener
  )

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
    expectedHash: WakuMessageHash,
) =
  manager.validate(expected)
  for hash in manager.sentHashes & manager.propagatedHashes & manager.errorHashes:
    check hash == expectedHash.to0xHex()

proc addNoPeersLightpushNode(node: LogosDelivery): Future[WakuNode] {.async.} =
  ## Gives `node` a lightpush service node that has no relay peer.
  ## That service node answers each request with zero peers.
  ## So `send` accepts a message of `node`, and each attempt of the message fails.
  let serviceNode = newTestWakuNode(generateSecp256k1Key())
  serviceNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
    raiseAssert "Failed to mount metadata: " & error
  proc noPeersHandler(
      pubsubTopic: PubsubTopic, message: WakuMessage
  ): Future[WakuLightPushResult] {.async.} =
    return lightpushSuccessResult(0)

  discard await newTestWakuLightpushNode(serviceNode.switch, noPeersHandler)
  await serviceNode.start()
  node.waku.node.peerManager.addServicePeer(
    serviceNode.peerInfo.toRemotePeerInfo(), WakuLightPushCodec
  )
  return serviceNode

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
      relayNode1 = newTestWakuNode(generateSecp256k1Key())
      relayNode1.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await relayNode1.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      await relayNode1.mountLibp2pPing()
      await relayNode1.start()

    lockNewGlobalBrokerContext:
      relayNode2 = newTestWakuNode(generateSecp256k1Key())
      relayNode2.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await relayNode2.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      await relayNode2.mountLibp2pPing()
      await relayNode2.start()

    lockNewGlobalBrokerContext:
      lightpushNode = newTestWakuNode(generateSecp256k1Key())
      lightpushNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await lightpushNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      (await lightpushNode.mountLightPush()).isOkOr:
        raiseAssert "Failed to mount lightpush"
      await lightpushNode.mountLibp2pPing()
      await lightpushNode.start()

    lockNewGlobalBrokerContext:
      storeNode = newTestWakuNode(generateSecp256k1Key())
      storeNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
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
    const testPubsubTopic = PubsubTopic("/waku/2/rs/3/0")
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
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error
      # node is not connected !

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let sendResult = await node.messagingClient.send(envelope)

    check sendResult.isErr()
    if sendResult.isErr():
      check sendResult.error.kind == SendErrorKind.NotConnected

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "A send that fails with no relay peer is stored once and counted once as written":
    let root = createTempDir("send-api-archive-", "")
    defer:
      removeDir(root)

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      var conf = defaultTestNodeConf()
      conf.kernel.store = Opt.some(true)
      conf.kernel.storeMessageDbUrl = "sqlite://" & (root / "store.sqlite3")
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error
    defer:
      (await node.stop()).expect("Failed to stop node")
    let noPeersNode = await node.addNoPeersLightpushNode()
    defer:
      await noPeersNode.stop()

    let
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      insertsBefore = insertCount(relayIngress)
      failuresBefore = errorCount(insertFailure)
      duplicatesBefore = duplicateCount(relayIngress)

    let sendResult = await node.messagingClient.send(
      MessageEnvelope.init(contentTopic, "test payload")
    )
    check sendResult.isOk()

    # The send fails, because the node has no relay peer.
    let sendService = node.messagingClient.sendService
    checkUntilTimeout:
      sendService.sendsEnded == 1

    let stored = (
      await node.waku.node.wakuArchive.findMessages(
        ArchiveQuery(contentTopics: @[contentTopic])
      )
    ).valueOr:
      ArchiveResponse()
    check:
      stored.hashes.len == 1
      insertCount(relayIngress) == insertsBefore + 1
      duplicateCount(relayIngress) == duplicatesBefore
      errorCount(insertFailure) == failuresBefore

  asyncTest "Send fully validated":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.waku.node.connectToNodes(
        @[relayNode1PeerInfo, lightpushNodePeerInfo, storeNodePeerInfo]
      )

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let msgHash = (await node.messagingClient.sendWhenConnected(envelope)).valueOr:
      raiseAssert $error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    check await eventManager.sentFuture.withTimeout(eventTimeout)

    eventManager.validate({SendEventOutcome.Sent, SendEventOutcome.Propagated}, msgHash)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Burst of sends is fully validated":
    ## Confirm all requests across multiple Store pages and validation batches.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.waku.node.connectToNodes(
        @[relayNode1PeerInfo, lightpushNodePeerInfo, storeNodePeerInfo]
      )

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    const burst = 120
    let allSent = newAsyncEvent()
    var sentCount = 0
    let onSent = proc(event: MessageSentEvent) {.async: (raises: []).} =
      inc sentCount
      if sentCount == burst:
        allSent.fire()
    let counter = MessageSentEvent.listen(node.waku.brokerCtx, onSent).expect("listen")
    defer:
      await MessageSentEvent.dropListener(node.waku.brokerCtx, counter)

    var msgHashes: HashSet[string]
    for i in 0 ..< burst:
      let envelope = MessageEnvelope.init(
        ContentTopic("/waku/2/default-content/proto"), "burst payload " & $i
      )
      let msgHash = (await node.messagingClient.sendWhenConnected(envelope)).valueOr:
        raiseAssert "send failed: " & $error
      msgHashes.incl(msgHash.to0xHex())
    check msgHashes.len == burst

    # 120 messages require at least two validation batches.
    check:
      await allSent.wait().withTimeout(30.seconds)
      eventManager.sentHashes.toHashSet() == msgHashes
      eventManager.sentCount == burst
      eventManager.errorCount == 0

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send only propagates":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.waku.node.connectToNodes(@[relayNode1PeerInfo])

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let msgHash = (await node.messagingClient.sendWhenConnected(envelope)).valueOr:
      raiseAssert $error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated}, msgHash)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send only propagates fallback to lightpush":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.waku.node.connectToNodes(@[lightpushNodePeerInfo])

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let msgHash = (await node.messagingClient.sendWhenConnected(envelope)).valueOr:
      raiseAssert $error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated}, msgHash)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Edge sender delivers via lightpush (no relay)":
    ## Reproduces issue #3847: an Edge node (no relay mounted) that is only
    ## connected to a lightpush-capable peer must deliver through lightpush.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
        )
      ).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      # Edge node has no relay; its only path to the network is the
      # lightpush peer it is connected to.
      await node.waku.node.connectToNodes(@[lightpushNodePeerInfo])

    check node.waku.node.wakuRelay.isNil()

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let msgHash = (await node.messagingClient.sendWhenConnected(envelope)).valueOr:
      raiseAssert $error

    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated}, msgHash)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "S16 - isolated sender sends when a lightpush peer appears":
    ## An Edge sender with no peer gets `NotConnected` from `send`, with no event.
    ## When a lightpush peer appears, the next `send` delivers.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
        )
      ).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error
      # No connectToNodes: the sender has no reachable peer at T0.

    check node.waku.node.wakuRelay.isNil()

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let isolated = await node.messagingClient.send(envelope)
    check isolated.isErr()
    if isolated.isErr():
      check isolated.error.kind == SendErrorKind.NotConnected
    check node.messagingClient.sendService.sendsEnded == 0

    # The lightpush peer appears; a send must now deliver.
    await node.waku.node.connectToNodes(@[lightpushNodePeerInfo])
    let msgHash = (await node.messagingClient.sendWhenConnected(envelope)).valueOr:
      raiseAssert $error

    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated}, msgHash)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send fully validates fallback to lightpush":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.waku.node.connectToNodes(@[lightpushNodePeerInfo, storeNodePeerInfo])

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let msgHash = (await node.messagingClient.sendWhenConnected(envelope)).valueOr:
      raiseAssert $error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    check await eventManager.sentFuture.withTimeout(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated, SendEventOutcome.Sent}, msgHash)
    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send fails with event":
    var fakeLightpushNode: WakuNode
    lockNewGlobalBrokerContext:
      fakeLightpushNode = newTestWakuNode(generateSecp256k1Key())
      fakeLightpushNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
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
      (kind: PubsubSub, topic: PubsubTopic("/waku/2/rs/3/0")), dummyHandler
    ).isOkOr:
      raiseAssert "Failed to subscribe fakeLightpushNode: " & error

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
        )
      ).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.waku.node.connectToNodes(@[fakeLightpushNodePeerInfo])

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let msgHash = (await node.messagingClient.sendWhenConnected(envelope)).valueOr:
      raiseAssert $error

    echo "Sent message with messageHash=", msgHash.to0xHex()
    # Wait for events with timeout
    const eventTimeout = 30.seconds
    check await eventManager.errorFuture.withTimeout(eventTimeout)

    eventManager.validate({SendEventOutcome.Error}, msgHash)
    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Edge send whose meta exceeds the limit fails at once with the service's reason":
    ## The lightpush service rejects the request as BAD_REQUEST, so the send fails.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
        )
      ).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.waku.node.connectToNodes(@[lightpushNodePeerInfo])
    defer:
      (await node.stop()).expect("Failed to stop node")

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let rejectedBefore =
      try:
        logos_delivery_lightpush_v3_errors.value([$LightPushErrorCode.BAD_REQUEST])
      except KeyError:
        0.0

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"),
      "test payload",
      meta = newSeq[byte](MaxMetaAttrLength + 1),
    )

    let msgHash = (await node.messagingClient.sendWhenConnected(envelope)).valueOr:
      raiseAssert $error

    check await eventManager.errorFuture.withTimeout(30.seconds)

    let rejected =
      try:
        logos_delivery_lightpush_v3_errors.value([$LightPushErrorCode.BAD_REQUEST]) -
          rejectedBefore
      except KeyError:
        0.0

    eventManager.validate({SendEventOutcome.Error}, msgHash)
    check:
      eventManager.errorDescs ==
        @["decode_rpc_failure: (kind: InvalidLengthField, field: \"meta\")"]
      rejected == 1.0

  asyncTest "A send that fails with no relay peer is never handed to the relay handlers nor received":
    # Given a core node with REST that has no relay peer
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf(rest = true))).valueOr:
        raiseAssert error
      node.shortenIntervals()
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start Waku node: " & error
    let noPeersNode = await node.addNoPeersLightpushNode()
    defer:
      await noPeersNode.stop()

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    var receivedHashes: seq[string]
    let receivedListener = MessageReceivedEvent.listen(
      node.waku.brokerCtx,
      proc(event: MessageReceivedEvent) {.async: (raises: []).} =
        receivedHashes.add(event.messageHash),
    ).valueOr:
      raiseAssert $error
    defer:
      await MessageReceivedEvent.dropListener(node.waku.brokerCtx, receivedListener)

    let
      client = newRestHttpClient(rest.server.localAddress())
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "test payload"
    let subscribeResponse = await client.relayPostAutoSubscriptionsV1(@[contentTopic])
    let handledBefore = nodeMessagesCount(["relay"])

    # When it sends a message
    let msgHash = (
      await node.messagingClient.sendWhenConnected(
        MessageEnvelope.init(contentTopic, payload)
      )
    ).valueOr:
      raiseAssert $error

    # Then the send ends with an error event
    check await eventManager.errorFuture.withTimeout(30.seconds)
    eventManager.validate({SendEventOutcome.Error}, msgHash)

    # And the node's own message reached neither its relay cache nor its receive path
    let cached = await client.relayGetAutoMessagesV1(contentTopic)
    check:
      subscribeResponse.status == 200
      cached.status == 200
      cached.data.len == 0
      nodeMessagesCount(["relay"]) == handledBefore
      receivedHashes.len == 0

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Own message is not received with no relay peer":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error
    defer:
      (await node.stop()).expect("Failed to stop node")
    let noPeersNode = await node.addNoPeersLightpushNode()
    defer:
      await noPeersNode.stop()

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    var received: seq[MessageReceivedEvent]
    let receivedListener = MessageReceivedEvent.listen(
      node.waku.brokerCtx,
      proc(event: MessageReceivedEvent) {.async: (raises: []).} =
        received.add(event),
    ).valueOr:
      raiseAssert $error
    defer:
      await MessageReceivedEvent.dropListener(node.waku.brokerCtx, receivedListener)

    let payload = "test payload"
    let msgHash = (
      await node.messagingClient.sendWhenConnected(
        MessageEnvelope.init(ContentTopic("/waku/2/default-content/proto"), payload)
      )
    ).valueOr:
      raiseAssert $error

    check await eventManager.errorFuture.withTimeout(10.seconds)
    eventManager.validate({SendEventOutcome.Error}, msgHash)
    check:
      eventManager.errorDescs == @[NoSendPeerReason]
      eventManager.errorKinds == @[MessageErrorKind.NotPropagated]
      received.len == 0

  asyncTest "Store validation times out with an error event":
    ## The message propagates, but the only reachable store node is outside the
    ## relay mesh and never holds it. Once the validation window elapses the send
    ## reports Propagated, then Error, and never Sent.
    var isolatedStoreNode: WakuNode
    lockNewGlobalBrokerContext:
      isolatedStoreNode = newTestWakuNode(generateSecp256k1Key())
      isolatedStoreNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await isolatedStoreNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      let archiveDriver = newSqliteArchiveDriver()
      isolatedStoreNode.mountArchive(archiveDriver).isOkOr:
        raiseAssert "Failed to mount archive: " & error
      await isolatedStoreNode.mountStore()
      await isolatedStoreNode.mountLibp2pPing()
      await isolatedStoreNode.start()
    # Deliberately NOT subscribed to the topic and NOT wired into the relay mesh, so
    # it can answer store queries but never holds the published message.
    let isolatedStoreNodePeerInfo = isolatedStoreNode.peerInfo.toRemotePeerInfo()

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      # Propagate via relayNode1; store queries can only reach the isolated store node.
      await node.waku.node.connectToNodes(
        @[relayNode1PeerInfo, isolatedStoreNodePeerInfo]
      )

    # Longer than `archiveTime`, so the store node is queried first.
    node.messagingClient.sendService.maxValidationAge = 2.seconds

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let msgHash = (await node.messagingClient.sendWhenConnected(envelope)).valueOr:
      raiseAssert $error

    check await eventManager.errorFuture.withTimeout(30.seconds)

    eventManager.validate(
      {SendEventOutcome.Propagated, SendEventOutcome.Error}, msgHash
    )

    await isolatedStoreNode.stop()
    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "A late store node never gets an earlier message":
    # TODO: logos-delivery#4511
    ## A propagated message is not sent again, so a store node that joins the
    ## mesh after it cannot confirm it.
    var lateStoreNode: WakuNode
    lockNewGlobalBrokerContext:
      lateStoreNode = newTestWakuNode(generateSecp256k1Key())
      lateStoreNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await lateStoreNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      let archiveDriver = newSqliteArchiveDriver()
      lateStoreNode.mountArchive(archiveDriver).isOkOr:
        raiseAssert "Failed to mount archive: " & error
      await lateStoreNode.mountStore()
      await lateStoreNode.mountLibp2pPing()
      await lateStoreNode.start()
    defer:
      await lateStoreNode.stop()
    let lateStoreNodePeerInfo = lateStoreNode.peerInfo.toRemotePeerInfo()
    proc dummyHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      discard

    lateStoreNode.subscribe(
      (kind: PubsubSub, topic: PubsubTopic("/waku/2/rs/3/0")), dummyHandler
    ).isOkOr:
      raiseAssert "Failed to subscribe lateStoreNode: " & error

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.waku.node.connectToNodes(@[relayNode1PeerInfo])
    defer:
      (await node.stop()).expect("Failed to stop node")

    node.messagingClient.sendService.maxValidationAge = 5.seconds

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let contentTopic = ContentTopic("/waku/2/default-content/proto")

    let msgHash = (
      await node.messagingClient.sendWhenConnected(
        MessageEnvelope.init(contentTopic, "test payload")
      )
    ).valueOr:
      raiseAssert $error

    check await eventManager.propagatedFuture.withTimeout(10.seconds)

    await node.waku.node.connectToNodes(@[lateStoreNodePeerInfo])
    checkUntilTimeout:
      lateStoreNode.hasMeshPeer(
        PubsubTopic("/waku/2/rs/3/0"), node.waku.node.peerInfo.peerId
      )
    check eventManager.errorCount == 0

    check await eventManager.errorFuture.withTimeout(30.seconds)

    eventManager.validate(
      {SendEventOutcome.Propagated, SendEventOutcome.Error}, msgHash
    )
    check:
      eventManager.errorDescs ==
        @[
          "Propagated but not confirmed by a store node within the store validation window"
        ]
      eventManager.errorKinds == @[MessageErrorKind.NotStored]

    let stored = (
      await lateStoreNode.wakuArchive.findMessages(
        ArchiveQuery(contentTopics: @[contentTopic])
      )
    ).valueOr:
      ArchiveResponse()
    check stored.hashes.len == 0

    let laterEventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await laterEventManager.teardown()

    let laterMsgHash = (
      await node.messagingClient.sendWhenConnected(
        MessageEnvelope.init(contentTopic, "later test payload")
      )
    ).valueOr:
      raiseAssert $error

    check await laterEventManager.sentFuture.withTimeout(10.seconds)

    laterEventManager.validate(
      {SendEventOutcome.Propagated, SendEventOutcome.Sent}, laterMsgHash
    )

  asyncTest "Edge sender sends through a static node that was down at its start":
    let lightpushNodeAddr =
      $lightpushNodePeerInfo.addrs[0] & "/p2p/" & $lightpushNodePeerId
    await lightpushNode.stop()

    var conf = defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
    conf.kernel.staticnodes = @[lightpushNodeAddr]
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      node.waku.node.peerManager.initialBackoffInSec = 1
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error
    defer:
      (await node.stop()).expect("Failed to stop node")

    check not node.waku.node.switch.isConnected(lightpushNodePeerId)

    await lightpushNode.start()
    await lightpushNode.connectToNodes(@[relayNode2PeerInfo])

    checkUntilTimeout:
      node.waku.node.switch.isConnected(lightpushNodePeerId)

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let msgHash = (
      await node.messagingClient.sendWhenConnected(
        MessageEnvelope.init(
          ContentTopic("/waku/2/default-content/proto"), "test payload"
        )
      )
    ).valueOr:
      raiseAssert $error

    check await eventManager.propagatedFuture.withTimeout(10.seconds)

    eventManager.validate({SendEventOutcome.Propagated}, msgHash)

## Checks that the caller gets the message hash before any event of the send.
## The RLN backend of the node fails each proof at once.
## So each accepted send emits `MessageErrorEvent` with no network call.

const OrderTopic = ContentTopic("/test/1/send-order/proto")

type OrderLog = ref object
  hashes: seq[string] ## The hashes that the callers got, in order.
  events: seq[string]
  early: seq[string] ## The events for a hash that no caller had yet.

proc record(log: OrderLog, messageHash: string) =
  log.events.add(messageHash)
  if messageHash notin log.hashes:
    log.early.add(messageHash)

proc keepHash(log: OrderLog, res: SendResult) =
  ## Records the hash when the caller gets it.
  ## A refused send records an empty hash.
  log.hashes.add(
    if res.isOk():
      res.get().to0xHex()
    else:
      ""
  )

proc failingProofNode(): Future[LogosDelivery] {.async.} =
  ## A started node whose sends are accepted and then fail at once.
  ## Its lightpush service peer makes `send` accept a message.
  ## Its RLN backend fails each proof.
  var node: LogosDelivery
  lockNewGlobalBrokerContext:
    node = (await LogosDelivery.new(defaultTestNodeConf())).expect("LogosDelivery.new")
    (await node.start()).expect("start")
  proc failProof(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.async.} =
    return err(RlnError.permanent("scripted proof failure"))

  node.waku.node.rlnPlugin = Opt.some(RlnPlugin(name: "fake", generateProof: failProof))
  node.addUnreachableLightpushPeer()
  return node

suite "Messaging API - the message hash comes before the events":
  asyncTest "send and the MessagingSend provider return a finished future":
    ## Both futures are finished when the call returns.
    ## The send service has the task then.
    let node = await failingProofNode()
    defer:
      (await node.stop()).expect("stop")
    let client = node.messagingClient

    let direct = client.send(MessageEnvelope.init(OrderTopic, "direct"))
    let viaBroker = MessagingSend.request(
      node.waku.brokerCtx, MessageEnvelope.init(OrderTopic, "broker")
    )
    check:
      direct.finished()
      viaBroker.finished()
    if direct.finished() and viaBroker.finished():
      check:
        direct.read().isOk()
        viaBroker.read().isOk()
      if viaBroker.read().isOk():
        check viaBroker.read().get().isOk()

    # A refused send is also a finished future.
    const RefusedTopic = ContentTopic("/test/1/send-order-refused/proto")
    let tooLarge = MessageEnvelope.init(
      RefusedTopic, newSeq[byte](int(node.waku.maxMessageSizeBytes) + 1)
    )
    let refused = client.send(tooLarge)
    check refused.finished()
    if refused.finished():
      check refused.read().isErr()
      if refused.read().isErr():
        check refused.read().error.kind == SendErrorKind.TooLarge

  asyncTest "no event comes before its message hash":
    let node = await failingProofNode()
    defer:
      (await node.stop()).expect("stop")
    let client = node.messagingClient
    let brokerCtx = node.waku.brokerCtx

    let log = OrderLog()
    let errorListener = MessageErrorEvent
      .listen(
        brokerCtx,
        proc(event: MessageErrorEvent) {.async: (raises: []).} =
          log.record(event.messageHash),
      )
      .expect("listen error")
    defer:
      await MessageErrorEvent.dropListener(brokerCtx, errorListener)

    proc viaBroker(envelope: MessageEnvelope): Future[SendResult] {.async.} =
      return (await MessagingSend.request(brokerCtx, envelope)).expect("broker")

    # Each batch sends two messages through the client and two through the
    # broker. Each task fails at its proof.
    for batch in 0 ..< 3:
      proc envelope(kind: string, ephemeral = false): MessageEnvelope =
        MessageEnvelope.init(OrderTopic, kind & "-" & $batch, ephemeral = ephemeral)

      log.keepHash(await client.send(envelope("durable")))
      log.keepHash(await client.send(envelope("ephemeral", ephemeral = true)))
      log.keepHash(await viaBroker(envelope("broker-durable")))
      log.keepHash(await viaBroker(envelope("broker-ephemeral", ephemeral = true)))
      checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, chronos.milliseconds(5)):
        log.events.len == log.hashes.len

    check:
      log.hashes.len == 12
      "" notin log.hashes # each send got a hash
      log.early.len == 0

suite "Messaging API refused sends":
  asyncTest "a send over the rate-limit budget is refused with the time to the refill":
    const
      AcceptedTopic = ContentTopic("/test/1/rate-limit-accepted/proto")
      RefusedTopic = ContentTopic("/test/1/rate-limit-refused/proto")
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          KernelConf(defaultTestNodeConf().kernel),
          MessagingClientConf(
            rateLimitEnabled: Opt.some(true),
            rateLimitEpochPeriodSec: Opt.some(600'u64),
            rateLimitMessagesPerEpoch: Opt.some(1'u64),
          ),
          ReliableChannelManagerConf(),
        )
      ).expect("LogosDelivery.new")
      (await node.start()).expect("start")
    defer:
      (await node.stop()).expect("stop")
    node.addUnreachableLightpushPeer()
    let client = node.messagingClient

    # The first send takes the budget of the epoch.
    check (await client.send(MessageEnvelope.init(AcceptedTopic, "accepted"))).isOk()

    let refused = await client.send(MessageEnvelope.init(RefusedTopic, "refused"))
    check refused.isErr()
    if refused.isErr():
      check:
        refused.error.kind == SendErrorKind.RateLimited
        refused.error.retryAfter > ZeroDuration
        refused.error.retryAfter <= 600.seconds

  asyncTest "a burst of two times MaxSendsInFlight sends gets QueueFull for the second half":
    ## `send` does not suspend, so no send of the burst ends before the last one.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node =
        (await LogosDelivery.new(defaultTestNodeConf())).expect("LogosDelivery.new")
      (await node.start()).expect("start")
    defer:
      (await node.stop()).expect("stop")
    node.addUnreachableLightpushPeer()
    let client = node.messagingClient
    const Topic = ContentTopic("/test/1/queue-full/proto")

    var accepted = 0
    var refusals: seq[SendErrorKind]
    for i in 0 ..< MaxSendsInFlight * 2:
      let res = await client.send(MessageEnvelope.init(Topic, "burst-" & $i))
      if res.isOk():
        inc accepted
      else:
        refusals.add(res.error.kind)
    check:
      accepted == MaxSendsInFlight
      refusals.len == MaxSendsInFlight
      refusals.allIt(it == SendErrorKind.QueueFull)

  asyncTest "with RLN, a refused send gives the time to the end of the RLN epoch":
    ## The RLN backend states its epoch length.
    ## So the node can tell the app when the budget refills.
    const EpochSizeSec = 100_000'u64
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node =
        (await LogosDelivery.new(defaultTestNodeConf())).expect("LogosDelivery.new")
      (await node.start()).expect("start")
    defer:
      (await node.stop()).expect("stop")
    node.addUnreachableLightpushPeer()

    proc quota(timestamp: uint64): Future[Result[EpochQuota, RlnError]] {.async.} =
      return ok(
        EpochQuota(epochIndex: timestamp div EpochSizeSec, rateLimit: 1, remaining: 1)
      )

    proc generate(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.async.} =
      return ok(@[1'u8, 2, 3])

    node.waku.node.rlnPlugin = Opt.some(
      RlnPlugin(
        name: "fake",
        generateProof: generate,
        getEpochQuota: quota,
        epochSizeSec: Opt.some(EpochSizeSec),
      )
    )
    let client = node.messagingClient
    const Topic = ContentTopic("/test/1/rln-retry-after/proto")

    # The first send takes the budget of the epoch.
    check (await client.send(MessageEnvelope.init(Topic, "accepted"))).isOk()

    let refused = await client.send(MessageEnvelope.init(Topic, "refused"))
    let now = uint64(getNowInNanosecondTime() div 1_000_000_000)
    check refused.isErr()
    if refused.isErr():
      let left = int64(EpochSizeSec - now mod EpochSizeSec)
      check:
        refused.error.kind == SendErrorKind.RateLimited
        refused.error.retryAfter >= chronos.seconds(left - 2)
        refused.error.retryAfter <= chronos.seconds(left + 2)

suite "Messaging API - a node that is not started":
  asyncTest "send, subscribe and unsubscribe fail, and the subscribe leaves no subscription":
    const
      SendTopic = ContentTopic("/test/1/not-started-send/proto")
      SubscribeTopic = ContentTopic("/test/1/not-started-subscribe/proto")
      UnsubscribeTopic = ContentTopic("/test/1/not-started-unsubscribe/proto")
    lockNewGlobalBrokerContext:
      let node =
        (await LogosDelivery.new(defaultTestNodeConf())).expect("LogosDelivery.new")
      let client = node.messagingClient

      # The loop runs once on a node never started, and once on a stopped node.
      for stopped in [false, true]:
        if stopped:
          (await node.start()).expect("start")
          (await node.stop()).expect("stop")
        check:
          (await client.send(MessageEnvelope.init(SendTopic, "payload"))).error.desc ==
            "node is not started"
          (await client.subscribe(SubscribeTopic)).errorOr("accepted") ==
            "node is not started"
          client.unsubscribe(UnsubscribeTopic).errorOr("accepted") ==
            "node is not started"

      (await node.start()).expect("start")
      check not node.waku.isSubscribed(SubscribeTopic).valueOr(true)
      (await node.stop()).expect("stop")

  asyncTest "a send during a stop fails":
    const StopTopic = ContentTopic("/test/1/during-stop/proto")
    lockNewGlobalBrokerContext:
      let node =
        (await LogosDelivery.new(defaultTestNodeConf())).expect("LogosDelivery.new")
      (await node.start()).expect("start")
      let client = node.messagingClient

      # `stop` runs up to its first wait before it returns its future.
      let stopping = client.stop()
      check:
        (await client.send(MessageEnvelope.init(StopTopic, "payload"))).error.desc ==
          "node is not started"
      await stopping
      (await node.stop()).expect("stop")

  asyncTest "MessagingClient.start refuses to run while its stop runs":
    lockNewGlobalBrokerContext:
      let node =
        (await LogosDelivery.new(defaultTestNodeConf())).expect("LogosDelivery.new")
      (await node.start()).expect("start")
      let client = node.messagingClient

      let stopping = client.stop()
      check client.start().errorOr("accepted") == "MessagingClient is stopping"
      await stopping
      (await node.stop()).expect("stop")
