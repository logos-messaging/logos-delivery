{.push raises: [].}

import
  std/[options, net],
  chronos,
  chronicles,
  metrics,
  results,
  stew/byteutils,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport,
  libp2p/utility

import
  ../waku_node,
  ../../waku_relay,
  ../../waku_core,
  ../../waku_core/topics/sharding,
  ../../waku_filter_v2,
  ../../waku_archive_legacy,
  ../../waku_archive,
  ../../waku_store_sync,
  ../peer_manager,
  ../../waku_rln_relay

export waku_relay.WakuRelayHandler

declarePublicHistogram waku_histogram_message_size,
  "message size histogram in kB",
  buckets = [
    0.0, 1.0, 3.0, 5.0, 15.0, 50.0, 75.0, 100.0, 125.0, 150.0, 500.0, 700.0, 1000.0, Inf
  ]

logScope:
  topics = "waku node relay api"

## Waku relay

proc registerRelayHandler(
    node: WakuNode, topic: PubsubTopic, appHandler: WakuRelayHandler
) =
  ## Registers the only handler for the given topic.
  ## Notice that this handler internally calls other handlers, such as filter,
  ## archive, etc, plus the handler provided by the application.

  if node.wakuRelay.isSubscribed(topic):
    return

  proc traceHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    let msgSizeKB = msg.payload.len / 1000

    waku_node_messages.inc(labelValues = ["relay"])
    waku_histogram_message_size.observe(msgSizeKB)

  proc filterHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuFilter.isNil():
      return

    await node.wakuFilter.handleMessage(topic, msg)

  proc archiveHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if not node.wakuLegacyArchive.isNil():
      ## we try to store with legacy archive
      await node.wakuLegacyArchive.handleMessage(topic, msg)
      return

    if node.wakuArchive.isNil():
      return

    await node.wakuArchive.handleMessage(topic, msg)

  proc syncHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuStoreReconciliation.isNil():
      return

    node.wakuStoreReconciliation.messageIngress(topic, msg)

  let uniqueTopicHandler = proc(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    await traceHandler(topic, msg)
    await filterHandler(topic, msg)
    await archiveHandler(topic, msg)
    await syncHandler(topic, msg)
    await appHandler(topic, msg)

  node.wakuRelay.subscribe(topic, uniqueTopicHandler)

proc getTopicOfSubscriptionEvent(
    node: WakuNode, subscription: SubscriptionEvent
): Result[(PubsubTopic, Option[ContentTopic]), string] =
  case subscription.kind
  of ContentSub, ContentUnsub:
    if node.wakuAutoSharding.isSome():
      let shard = node.wakuAutoSharding.get().getShard((subscription.topic)).valueOr:
          return err("Autosharding error: " & error)
      return ok(($shard, some(subscription.topic)))
    else:
      return
        err("Static sharding is used, relay subscriptions must specify a pubsub topic")
  of PubsubSub, PubsubUnsub:
    return ok((subscription.topic, none[ContentTopic]()))
  else:
    return err("Unsupported subscription type in relay getTopicOfSubscriptionEvent")

proc subscribe*(
    node: WakuNode, subscription: SubscriptionEvent, handler: WakuRelayHandler
): Result[void, string] =
  ## Subscribes to a PubSub or Content topic. Triggers handler when receiving messages on
  ## this topic. WakuRelayHandler is a method that takes a topic and a Waku message.

  if node.wakuRelay.isNil():
    error "Invalid API call to `subscribe`. WakuRelay not mounted."
    return err("Invalid API call to `subscribe`. WakuRelay not mounted.")

  let (pubsubTopic, contentTopicOp) = getTopicOfSubscriptionEvent(node, subscription).valueOr:
    error "Failed to decode subscription event", error = error
    return err("Failed to decode subscription event: " & error)

  if node.wakuRelay.isSubscribed(pubsubTopic):
    warn "No-effect API call to subscribe. Already subscribed to topic", pubsubTopic
    return ok()

  info "subscribe", pubsubTopic, contentTopicOp
  node.registerRelayHandler(pubsubTopic, handler)
  node.topicSubscriptionQueue.emit((kind: PubsubSub, topic: pubsubTopic))

  return ok()

proc unsubscribe*(
    node: WakuNode, subscription: SubscriptionEvent
): Result[void, string] =
  ## Unsubscribes from a specific PubSub or Content topic.

  if node.wakuRelay.isNil():
    error "Invalid API call to `unsubscribe`. WakuRelay not mounted."
    return err("Invalid API call to `unsubscribe`. WakuRelay not mounted.")

  let (pubsubTopic, contentTopicOp) = getTopicOfSubscriptionEvent(node, subscription).valueOr:
    error "Failed to decode unsubscribe event", error = error
    return err("Failed to decode unsubscribe event: " & error)

  if not node.wakuRelay.isSubscribed(pubsubTopic):
    warn "No-effect API call to `unsubscribe`. Was not subscribed", pubsubTopic
    return ok()

  info "unsubscribe", pubsubTopic, contentTopicOp
  node.wakuRelay.unsubscribe(pubsubTopic)
  node.topicSubscriptionQueue.emit((kind: PubsubUnsub, topic: pubsubTopic))

  return ok()

proc isSubscribed*(
    node: WakuNode, subscription: SubscriptionEvent
): Result[bool, string] =
  if node.wakuRelay.isNil():
    error "Invalid API call to `isSubscribed`. WakuRelay not mounted."
    return err("Invalid API call to `isSubscribed`. WakuRelay not mounted.")

  let (pubsubTopic, contentTopicOp) = getTopicOfSubscriptionEvent(node, subscription).valueOr:
    error "Failed to decode subscription event", error = error
    return err("Failed to decode subscription event: " & error)

  return ok(node.wakuRelay.isSubscribed(pubsubTopic))

proc publish*(
    node: WakuNode, pubsubTopicOp: Option[PubsubTopic], message: WakuMessage
): Future[Result[int, string]] {.async, gcsafe.} =
  ## Publish a `WakuMessage`. Pubsub topic contains; none, a named or static shard.
  ## `WakuMessage` should contain a `contentTopic` field for light node functionality.
  ## It is also used to determine the shard.

  if node.wakuRelay.isNil():
    let msg =
      "Invalid API call to `publish`. WakuRelay not mounted. Try `lightpush` instead."
    error "publish error", err = msg
    # TODO: Improve error handling
    return err(msg)

  let pubsubTopic = pubsubTopicOp.valueOr:
    if node.wakuAutoSharding.isNone():
      return err("Pubsub topic must be specified when static sharding is enabled.")
    node.wakuAutoSharding.get().getShard(message.contentTopic).valueOr:
      let msg = "Autosharding error: " & error
      return err(msg)

  let numPeers = (await node.wakuRelay.publish(pubsubTopic, message)).valueOr:
    warn "waku.relay did not publish", error = error
    # Todo: If NoPeersToPublish, we might want to return ok(0) instead!!!
    return err("publish failed in relay: " & $error)

  notice "waku.relay published",
    peerId = node.peerId,
    pubsubTopic = pubsubTopic,
    msg_hash = pubsubTopic.computeMessageHash(message).to0xHex(),
    publishTime = getNowInNanosecondTime(),
    numPeers = numPeers

  # TODO: investigate if we can return error in case numPeers is 0
  ok(numPeers)

proc mountRelay*(
    node: WakuNode,
    peerExchangeHandler = none(RoutingRecordsHandler),
    maxMessageSize = int(DefaultMaxWakuMessageSize),
): Future[Result[void, string]] {.async.} =
  if not node.wakuRelay.isNil():
    error "wakuRelay already mounted, skipping"
    return err("wakuRelay already mounted, skipping")

  ## The default relay topics is the union of all configured topics plus default PubsubTopic(s)
  info "mounting relay protocol"

  node.wakuRelay = WakuRelay.new(node.switch, node.brokerCtx, maxMessageSize).valueOr:
    error "failed mounting relay protocol", error = error
    return err("failed mounting relay protocol: " & error)

  ## Add peer exchange handler
  if peerExchangeHandler.isSome():
    node.wakuRelay.parameters.enablePX = true
      # Feature flag for peer exchange in nim-libp2p
    node.wakuRelay.routingRecordsHandler.add(peerExchangeHandler.get())

  if node.started:
    await node.startRelay()

  node.switch.mount(node.wakuRelay, protocolMatcher(WakuRelayCodec))

  info "relay mounted successfully"
  return ok()

  ## Waku RLN Relay

proc mountRlnRelay*(
    node: WakuNode,
    rlnConf: WakuRlnConfig,
    spamHandler = none(SpamHandler),
    registrationHandler = none(RegistrationHandler),
) {.async.} =
  info "mounting rln relay"

  if node.wakuRelay.isNil():
    raise newException(
      CatchableError, "WakuRelay protocol is not mounted, cannot mount WakuRlnRelay"
    )

  let rlnRelay = (await WakuRlnRelay.new(rlnConf, registrationHandler)).valueOr:
    raise newException(CatchableError, "failed to mount WakuRlnRelay: " & error)
  if (rlnConf.userMessageLimit > rlnRelay.groupManager.rlnRelayMaxMessageLimit):
    error "rln-relay-user-message-limit can't exceed the MAX_MESSAGE_LIMIT in the rln contract"
  let validator = generateRlnValidator(rlnRelay, spamHandler)

  # register rln validator as default validator
  info "Registering RLN validator"
  node.wakuRelay.addValidator(validator, "RLN validation failed")

  node.wakuRlnRelay = rlnRelay
