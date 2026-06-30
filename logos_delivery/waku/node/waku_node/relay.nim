import logos_delivery/waku/compat/option_valueor
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
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport,
  libp2p/utility,
  brokers/broker_context

import
  logos_delivery/waku/[
    waku_relay,
    waku_core,
    waku_core/topics/sharding,
    waku_filter_v2,
    waku_archive,
    waku_store_sync,
    rln,
    node/waku_node,
    node/subscription_manager,
    node/peer_manager,
  ]
import logos_delivery/api/kernel_api # MessageSeenEvent

export waku_relay.WakuRelayHandler

logScope:
  topics = "waku node relay api"

## Waku relay

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
  ## If `handler` is nil, the API call will subscribe to the topic in the relay mesh
  ## but no app handler will be registered at this time (it can be registered later with
  ## another call to this proc for the same gossipsub topic).

  if isNil(node.wakuRelay):
    error "Invalid API call to `subscribe`. WakuRelay not mounted."
    return err("Invalid API call to `subscribe`. WakuRelay not mounted.")

  let (pubsubTopic, _) = getTopicOfSubscriptionEvent(node, subscription).valueOr:
    error "Failed to decode subscription event", error = error
    return err("Failed to decode subscription event: " & error)

  # strict version
  #if contentTopicOp.isSome():
  #  return
  #    node.subscriptionManager.subscribe(pubsubTopic, contentTopicOp.get(), handler)
  return node.subscriptionManager.subscribeShard(pubsubTopic, handler)

proc unsubscribe*(
    node: WakuNode, subscription: SubscriptionEvent
): Result[void, string] =
  ## Unsubscribes from a specific PubSub or Content topic.
  ## This will both unsubscribe from the relay mesh and remove the app handler, if any.
  ## NOTE: This works because using MAPI and Kernel API at the same time is unsupported.

  if isNil(node.wakuRelay):
    error "Invalid API call to `unsubscribe`. WakuRelay not mounted."
    return err("Invalid API call to `unsubscribe`. WakuRelay not mounted.")

  let (pubsubTopic, _) = getTopicOfSubscriptionEvent(node, subscription).valueOr:
    error "Failed to decode unsubscribe event", error = error
    return err("Failed to decode unsubscribe event: " & error)

  # strict version
  #if contentTopicOp.isSome():
  #  return node.subscriptionManager.unsubscribe(pubsubTopic, contentTopicOp.get())
  return node.subscriptionManager.unsubscribeAll(pubsubTopic)

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

  node.wakuRelay = WakuRelay.new(node.switch, maxMessageSize).valueOr:
    error "failed mounting relay protocol", error = error
    return err("failed mounting relay protocol: " & error)

  ## Add peer exchange handler
  if peerExchangeHandler.isSome():
    node.wakuRelay.parameters.enablePX = true
      # Feature flag for peer exchange in nim-libp2p
    node.wakuRelay.routingRecordsHandler.add(peerExchangeHandler.get())

  if node.started:
    await node.wakuRelay.start()
    await node.reconnectRelayPeers()

  node.switch.mount(node.wakuRelay, protocolMatcher(WakuRelayCodec))

  info "relay mounted successfully"
  return ok()

  ## Waku RLN Relay

proc setRlnValidator*(
    node: WakuNode,
    rlnConf: WakuRlnConfig,
    spamHandler = none(SpamHandler),
    registrationHandler = none(RegistrationHandler),
) {.async.} =
  info "setting rln validator"

  let rln = (await Rln.new(rlnConf, registrationHandler)).valueOr:
    raise newException(CatchableError, "failed to set rln validator: " & error)
  if (rlnConf.userMessageLimit > rln.groupManager.rlnRelayMaxMessageLimit):
    error "rln-user-message-limit can't exceed the MAX_MESSAGE_LIMIT in the rln contract"

  node.rln = rln

  if node.wakuRelay.isNil():
    info "WakuRelay not mounted; RLN validator not set"
    return

  ## Bridges RLN's protocol-agnostic message validation into a relay
  ## (gossipsub) validator. The core decision is made by
  ## `validateMessageAndUpdateLog`; this maps the result to
  ## `pubsub.ValidationResult` so the validator can be installed on
  ## WakuRelay's validator chain.
  proc validator(
      topic: string, message: WakuMessage
  ): Future[pubsub.ValidationResult] {.async.} =
    trace "rln-relay topic validator is called"
    rln.clearNullifierLog()

    let msgProof = RateLimitProof.init(message.proof).valueOr:
      trace "rln validator reject", error = error
      return pubsub.ValidationResult.Reject

    # validate the message and update log
    let validationRes = await rln.validateMessageAndUpdateLog(message)

    let
      proof = byteutils.toHex(msgProof.proof)
      root = inHex(msgProof.merkleRoot)
      shareX = inHex(msgProof.shareX)
      shareY = inHex(msgProof.shareY)
      nullifier = inHex(msgProof.nullifier)

    case validationRes
    of Valid:
      trace "message validity is verified, relaying",
        proof = proof,
        root = root,
        shareX = shareX,
        shareY = shareY,
        nullifier = nullifier
      waku_rln_valid_messages_total.inc(labelValues = [topic])
      return pubsub.ValidationResult.Accept
    of Invalid:
      trace "message validity could not be verified, discarding",
        proof = proof,
        root = root,
        shareX = shareX,
        shareY = shareY,
        nullifier = nullifier
      return pubsub.ValidationResult.Reject
    of Spam:
      trace "A spam message is found! yay! discarding:",
        proof = proof,
        root = root,
        shareX = shareX,
        shareY = shareY,
        nullifier = nullifier
      if spamHandler.isSome():
        let handler = spamHandler.get()
        handler(message)
      return pubsub.ValidationResult.Reject

  # register rln validator as default validator
  info "Registering RLN validator"
  node.wakuRelay.addValidator(validator, "RLN validation failed")
