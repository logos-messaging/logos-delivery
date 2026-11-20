{.used.}

import results, std/[importutils, os, sets, strutils, tempfiles]
import chronos, testutils/unittests, stew/byteutils, libp2p/[switch, peerinfo], metrics
import brokers/broker_context
import
  ../testlib/
    [wakucore, wakunode, wakunodeconf, testasync, short_intervals, rest_service]
import ../waku_archive/archive_utils
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
import logos_delivery/waku/api/subscriptions
import tools/confutils/cli_args
import logos_delivery/api/conf/messaging_conf
import logos_delivery/api/events/messaging_client_events
import logos_delivery/messaging/delivery_service/send_service/send_service

privateAccess(SendService) # the test reads `attempts`
privateAccess(MessagingClient) # the tests set `sendTimeClock`
import logos_delivery/api/messaging_client_api
import logos_delivery/messaging/messaging_client_lifecycle
import logos_delivery/messaging/delivery_service/send_service
import logos_delivery/messaging/delivery_service/send_service/delivery_task

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
  errorDescs: seq[string]
  errorKinds: seq[MessageErrorKind]
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
      manager.errorDescs.add(event.error)
      manager.errorKinds.add(event.kind)
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
  var outcomes: set[SendEventOutcome]
  if manager.sentFuture.completed():
    outcomes.incl(SendEventOutcome.Sent)
  if manager.propagatedFuture.completed():
    outcomes.incl(SendEventOutcome.Propagated)
  if manager.errorFuture.failed():
    outcomes.incl(SendEventOutcome.Error)
  return outcomes

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
  let hash = expectedHash.to0xHex()
  for eventHash in manager.sentHashes:
    check eventHash == hash
  for eventHash in manager.propagatedHashes:
    check eventHash == hash
  for eventHash in manager.errorHashes:
    check eventHash == hash

proc startBystander(): Future[WakuNode] {.async.} =
  ## A started peer with no relay, lightpush, filter or store, so it cannot carry
  ## a message. A node connected only to it is not refused as NotConnected.
  var bystander: WakuNode
  lockNewGlobalBrokerContext:
    bystander = newTestWakuNode(generateSecp256k1Key())
    bystander.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
      raiseAssert "Failed to mount metadata: " & error
    await bystander.mountLibp2pPing()
    await bystander.start()
  return bystander

proc connectBystander(node: LogosDelivery, bystander: WakuNode) {.async.} =
  await node.waku.node.connectToNodes(@[bystander.peerInfo.toRemotePeerInfo()])
  for _ in 0 ..< 100:
    let (inPeers, outPeers) = node.waku.node.peerManager.connectedPeers()
    if inPeers.len + outPeers.len > 0:
      return
    await sleepAsync(100.milliseconds)
  raiseAssert "the bystander never connected"

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

  asyncTest "A node with no peer refuses a send as NotConnected":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error
      # node is not connected !

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let sendResult = await node.messagingClient.send(envelope)
    check:
      sendResult.isErr()
      sendResult.error.kind == SendErrorKind.NotConnected
      $sendResult.error == "node has no connected peer (NotConnected)"

    # A refused message gets no event.
    await sleepAsync(1.seconds)
    check:
      eventManager.errorCount == 0
      eventManager.propagatedCount == 0

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "A send retried while the node has no relay peer is stored once and counted once as written":
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
    let bystander = await startBystander()
    defer:
      await bystander.stop()
    await node.connectBystander(bystander)

    let
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      insertsBefore = insertCount(relayIngress)
      failuresBefore = errorCount(insertFailure)
      duplicatesBefore = duplicateCount(relayIngress)

    let sendResult = await node.messagingClient.send(
      MessageEnvelope.init(contentTopic, "test payload")
    )
    check sendResult.isOk()

    # The send is retried while the node has no relay peer, and no retry
    # reaches the archive again.
    let sendService = node.messagingClient.sendService
    checkUntilTimeout:
      sendService.attempts >= 3

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

    let msgHash = (await node.messagingClient.send(envelope)).valueOr:
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
      # The node takes at most `MaxSendsInFlight` sends with no last event, so
      # the burst sends again while `send` answers `QueueFull`, as an app does.
      var sent = await node.messagingClient.send(envelope)
      let deadline = Moment.now() + 30.seconds
      while sent.isErr() and sent.error.kind == SendErrorKind.QueueFull and
          Moment.now() < deadline:
        await sleepAsync(chronos.milliseconds(5))
        sent = await node.messagingClient.send(envelope)
      let msgHash = sent.valueOr:
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

    let msgHash = (await node.messagingClient.send(envelope)).valueOr:
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

    let msgHash = (await node.messagingClient.send(envelope)).valueOr:
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

    let msgHash = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert $error

    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated}, msgHash)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "an edge whose only peer is a lightpush service peer sends, and its first attempt connects it":
    ## `--lightpushnode` puts the peer in a service slot and does not dial it,
    ## and an edge with no relay dials nothing by itself. `send` accepts the
    ## message at once, and the lightpush attempt dials the peer.
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

    node.waku.node.peerManager.addServicePeer(lightpushNodePeerInfo, WakuLightPushCodec)
    let (inPeers, outPeers) = node.waku.node.peerManager.connectedPeers()
    check inPeers.len + outPeers.len == 0

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let sending = node.messagingClient.send(
      MessageEnvelope.init(
        ContentTopic("/waku/2/default-content/proto"), "test payload"
      )
    )
    # `send` does not wait for the dial.
    check sending.finished()
    let sent = await sending
    check sent.isOk()
    if sent.isOk():
      discard await eventManager.waitForEvents(10.seconds)
      eventManager.validate({SendEventOutcome.Propagated}, sent.get())

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "a send to a lightpush service peer that is down fails with NotPropagated":
    ## The node knows a lightpush peer, so `send` accepts the message. No attempt
    ## can dial that peer, so the message fails at the end of its window.
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
    node.messagingClient.sendService.deliveryWindow = 2.seconds

    # A peer that stopped, so nothing answers on its address.
    let down = await startBystander()
    let downInfo = down.peerInfo.toRemotePeerInfo()
    await down.stop()
    node.waku.node.peerManager.addServicePeer(downInfo, WakuLightPushCodec)

    var errors: seq[MessageErrorEvent]
    let listener = MessageErrorEvent
      .listen(
        node.waku.brokerCtx,
        proc(event: MessageErrorEvent) {.async: (raises: []).} =
          errors.add(event),
      )
      .expect("listen error")
    defer:
      await MessageErrorEvent.dropListener(node.waku.brokerCtx, listener)

    let sent = await node.messagingClient.send(
      MessageEnvelope.init(
        ContentTopic("/waku/2/default-content/proto"), "test payload"
      )
    )
    check sent.isOk()
    if sent.isOk():
      checkUntilTimeout:
        errors.len == 1
      check:
        errors.len == 1 and errors[0].messageHash == sent.get().to0xHex()
        errors.len == 1 and errors[0].kind == MessageErrorKind.NotPropagated

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "an edge that knows a lightpush peer only on another shard refuses a send as NotConnected":
    ## The lightpush attempt selects a peer on the shard of the message, so a peer
    ## on another shard gives that attempt nothing to dial.
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

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )
    let shard = RelayShard
      .parse(
        DeliveryTask
          .new(envelope, node.waku.brokerCtx, getNowInNanosecondTime())
          .expect("DeliveryTask.new").pubsubTopic
      )
      .expect("the shard of the message")

    let other = await startBystander()
    defer:
      await other.stop()
    let otherInfo = other.peerInfo.toRemotePeerInfo()
    otherInfo.protocols = @[WakuLightPushCodec]
    node.waku.node.peerManager.addPeer(otherInfo)
    node.waku.node.peerManager.switch.peerStore.setShardInfo(
      otherInfo.peerId, @[shard.shardId + 1'u16]
    )

    let refused = await node.messagingClient.send(envelope)
    check:
      refused.isErr()
      refused.isErr() and refused.error.kind == SendErrorKind.NotConnected

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "S16 - sender with no lightpush peer recovers when one appears later":
    ## Edge sender starts with no lightpush peer; one appears mid-send and a
    ## later retry must deliver the queued message.
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
      # Only a bystander: the sender has no peer that can carry the message at T0.

    check node.waku.node.wakuRelay.isNil()
    let bystander = await startBystander()
    defer:
      await bystander.stop()
    await node.connectBystander(bystander)

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    # send() with no lightpush peer must still succeed; the message is queued and retried.
    let msgHash = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert $error

    # Nothing should propagate while isolated (retry interval is 1s).
    await sleepAsync(5.seconds)
    check eventManager.propagatedCount == 0

    # The lightpush peer appears; a later retry must now deliver.
    await node.waku.node.connectToNodes(@[lightpushNodePeerInfo])

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

    let msgHash = (await node.messagingClient.send(envelope)).valueOr:
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

    node.messagingClient.sendService.deliveryWindow = 5.seconds

    let eventManager = newSendEventListenerManager(node.waku.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let msgHash = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert $error

    echo "Sent message with messageHash=", msgHash.to0xHex()
    # Wait for events with timeout
    const eventTimeout = 30.seconds
    check await eventManager.errorFuture.withTimeout(eventTimeout)

    eventManager.validate({SendEventOutcome.Error}, msgHash)
    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Edge send whose meta exceeds the limit fails at once with the service's reason":
    ## The lightpush service rejects the request as BAD_REQUEST, which is not
    ## retried, so the send fails after the first attempt.
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

    node.messagingClient.sendService.deliveryWindow = 5.seconds

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

    let msgHash = (await node.messagingClient.send(envelope)).valueOr:
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

  asyncTest "A send retried while the node has no relay peer is never handed to the relay handlers nor received":
    # Given a core node with REST that is connected to no peer
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf(rest = true))).valueOr:
        raiseAssert error
      node.shortenIntervals()
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start Waku node: " & error
    let bystander = await startBystander()
    defer:
      await bystander.stop()
    await node.connectBystander(bystander)

    node.messagingClient.sendService.deliveryWindow = 5.seconds

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
      await node.messagingClient.send(MessageEnvelope.init(contentTopic, payload))
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
    let bystander = await startBystander()
    defer:
      await bystander.stop()
    await node.connectBystander(bystander)

    node.messagingClient.sendService.deliveryWindow = 5.seconds

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
      await node.messagingClient.send(
        MessageEnvelope.init(ContentTopic("/waku/2/default-content/proto"), payload)
      )
    ).valueOr:
      raiseAssert $error

    check await eventManager.errorFuture.withTimeout(10.seconds)
    eventManager.validate({SendEventOutcome.Error}, msgHash)
    check:
      eventManager.errorDescs == @["Unable to send within the delivery window"]
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

    let msgHash = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert $error

    check await eventManager.errorFuture.withTimeout(30.seconds)

    eventManager.validate(
      {SendEventOutcome.Propagated, SendEventOutcome.Error}, msgHash
    )
    check eventManager.errorKinds == @[MessageErrorKind.NotStored]

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
      await node.messagingClient.send(
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
    check eventManager.errorDescs ==
      @[
        "Propagated but not confirmed by a store node within the store validation window"
      ]

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
      await node.messagingClient.send(
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
      await node.messagingClient.send(
        MessageEnvelope.init(
          ContentTopic("/waku/2/default-content/proto"), "test payload"
        )
      )
    ).valueOr:
      raiseAssert $error

    check await eventManager.propagatedFuture.withTimeout(10.seconds)

    eventManager.validate({SendEventOutcome.Propagated}, msgHash)

## Checks the refusals of `send` and that the caller gets the message hash
## before any event of the send. Each node is connected only to a bystander, so
## an accepted message stays in the send queue until its delivery window ends.

const RefusalTopic = ContentTopic("/test/1/send-refusal/proto")

proc refusalNode(
    conf: MessagingClientConf
): Future[(LogosDelivery, WakuNode)] {.async.} =
  ## A started node connected only to a bystander, and that bystander.
  var node: LogosDelivery
  lockNewGlobalBrokerContext:
    node = (
      await LogosDelivery.new(
        KernelConf(defaultTestNodeConf().kernel), conf, ReliableChannelManagerConf()
      )
    ).expect("LogosDelivery.new")
    (await node.start()).expect("start")
  let bystander = await startBystander()
  await node.connectBystander(bystander)
  return (node, bystander)

type OrderLog = ref object
  hashes: HashSet[string] ## The hashes that the callers got.
  events: int
  early: seq[string] ## The events for a hash that no caller had yet.

proc record(log: OrderLog, hash: string) =
  inc log.events
  if hash notin log.hashes:
    log.early.add(hash)

suite "Messaging API - send refusals":
  asyncTest "a send with no rate-limit budget is refused as RateLimited, with retryAfter":
    let (node, bystander) = await refusalNode(
      MessagingClientConf(
        rateLimitEnabled: Opt.some(true), rateLimitMessagesPerEpoch: Opt.some(0'u64)
      )
    )
    defer:
      (await node.stop()).expect("stop")
      await bystander.stop()
    let client = node.messagingClient

    for ephemeral in [false, true]:
      let refused =
        await client.send(MessageEnvelope.init(RefusalTopic, "payload", ephemeral))
      check:
        refused.isErr()
        refused.error.kind == SendErrorKind.RateLimited
        refused.error.retryAfter > ZeroDuration
        # The text has the seconds to wait, for a caller that gets only the text.
        ($refused.error).endsWith(
          ", retry after: " & $max(1'i64, refused.error.retryAfter.seconds) &
            " s (RateLimited)"
        )

    # The broker gives the refusal as text, with its kind at the end.
    let viaBroker = await MessagingSend.request(
      node.waku.brokerCtx, MessageEnvelope.init(RefusalTopic, "broker")
    )
    check viaBroker.isErr()
    if viaBroker.isErr():
      # The broker text has the seconds to wait as a number.
      let seconds =
        try:
          viaBroker.error.split(", retry after: ")[^1].split(" s (")[0].parseInt()
        except ValueError:
          -1
      check:
        viaBroker.error.endsWith(" s (RateLimited)")
        seconds > 0
    check client.sendService.deliveryTasks.len == 0

  asyncTest "a send in the clock step of the send before takes the next nanosecond":
    ## A clock that moves, forward or back, gives the stamp again.
    let (node, bystander) = await refusalNode(MessagingClientConf())
    defer:
      (await node.stop()).expect("stop")
      await bystander.stop()
    let client = node.messagingClient
    let reading = new Timestamp
    client.sendTimeClock = proc(): Timestamp {.gcsafe, raises: [].} =
      reading[]
    var stamps: seq[Timestamp]
    for clockValue in [1_000'i64, 1_000, 1_000, 2_000, 2_000, 500]:
      reading[] = clockValue
      stamps.add(client.nextTimestamp())
    check stamps == @[1_000'i64, 1_001, 1_002, 2_000, 2_001, 500]

  asyncTest "two sends of one payload in one clock step are two messages, and a full queue refuses as QueueFull":
    let (node, bystander) = await refusalNode(MessagingClientConf())
    defer:
      (await node.stop()).expect("stop")
      await bystander.stop()
    let client = node.messagingClient
    client.sendService.maxSendsInFlight = 2

    # A clock that does not move, so the two sends of one payload are in one
    # clock step.
    let now = getNowInNanosecondTime()
    client.sendTimeClock = proc(): Timestamp {.gcsafe, raises: [].} =
      now
    let envelope = MessageEnvelope.init(RefusalTopic, "twice")
    let first = (await client.send(envelope)).expect("the first send")
    let second = (await client.send(envelope)).expect("the second send")
    let firstTask = client.sendService.deliveryTasks.getOrDefault(first)
    let secondTask = client.sendService.deliveryTasks.getOrDefault(second)
    check:
      first != second
      not firstTask.isNil() and firstTask.msg.timestamp == now
      not secondTask.isNil() and secondTask.msg.timestamp == now + 1

    let full = await client.send(MessageEnvelope.init(RefusalTopic, "over"))
    check:
      full.isErr()
      full.error.kind == SendErrorKind.QueueFull
      $full.error == "send queue full, retry later (QueueFull)"

  asyncTest "send and the MessagingSend provider return a finished future":
    ## `send` does not suspend, so both futures are finished when the call returns.
    let (node, bystander) = await refusalNode(MessagingClientConf())
    defer:
      (await node.stop()).expect("stop")
      await bystander.stop()

    let direct = node.messagingClient.send(MessageEnvelope.init(RefusalTopic, "direct"))
    let viaBroker = MessagingSend.request(
      node.waku.brokerCtx, MessageEnvelope.init(RefusalTopic, "broker")
    )
    check:
      direct.finished()
      viaBroker.finished()
    if direct.finished() and viaBroker.finished():
      check:
        direct.read().isOk()
        viaBroker.read().isOk()

  asyncTest "no event comes before its message hash, through the client and the broker":
    let (node, bystander) = await refusalNode(MessagingClientConf())
    defer:
      (await node.stop()).expect("stop")
      await bystander.stop()
    let client = node.messagingClient
    let brokerCtx = node.waku.brokerCtx
    client.sendService.deliveryWindow = 1.seconds

    let log = OrderLog()
    let errorListener = MessageErrorEvent
      .listen(
        brokerCtx,
        proc(event: MessageErrorEvent) {.async: (raises: []).} =
          log.record(event.messageHash),
      )
      .expect("listen error")
    let propagatedListener = MessagePropagatedEvent
      .listen(
        brokerCtx,
        proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
          log.record(event.messageHash),
      )
      .expect("listen propagated")
    defer:
      await MessageErrorEvent.dropListener(brokerCtx, errorListener)
      await MessagePropagatedEvent.dropListener(brokerCtx, propagatedListener)

    for i in 0 ..< 3:
      let direct = (
        await client.send(MessageEnvelope.init(RefusalTopic, "direct-" & $i))
      ).expect("send")
      log.hashes.incl(direct.to0xHex())
      let viaBroker = (
        await MessagingSend.request(
          brokerCtx, MessageEnvelope.init(RefusalTopic, "broker-" & $i)
        )
      ).expect("MessagingSend")
      log.hashes.incl(viaBroker.to0xHex())

    # With no peer, each message fails once its delivery window ends.
    checkUntilTimeout:
      log.events == 6
    check:
      log.hashes.len == 6
      log.early.len == 0

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
        let refused = await client.send(MessageEnvelope.init(SendTopic, "payload"))
        check:
          refused.isErr()
          refused.error.kind == SendErrorKind.NotStarted
          $refused.error == "node is not started (NotStarted)"
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
      let refused = await client.send(MessageEnvelope.init(StopTopic, "payload"))
      check:
        refused.isErr()
        refused.error.kind == SendErrorKind.NotStarted
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
