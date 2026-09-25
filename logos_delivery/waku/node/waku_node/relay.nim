{.push raises: [].}

import
  std/net,
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
    rln/rln_plugin,
    node/waku_node,
    node/subscription_manager,
    node/peer_manager,
    rln/types,
  ]
import logos_delivery/api/events/kernel_events # MessageSeenEvent

export waku_relay.WakuRelayHandler

logScope:
  topics = "waku node relay api"

## Waku relay

proc getTopicOfSubscriptionEvent(
    node: WakuNode, subscription: SubscriptionEvent
): Result[(PubsubTopic, Opt[ContentTopic]), string] =
  case subscription.kind
  of ContentSub, ContentUnsub:
    if node.wakuAutoSharding.isSome():
      let shard = node.wakuAutoSharding.get().getShard((subscription.topic)).valueOr:
          return err("Autosharding error: " & error)
      return ok(($shard, Opt.some(subscription.topic)))
    else:
      return
        err("Static sharding is used, relay subscriptions must specify a pubsub topic")
  of PubsubSub, PubsubUnsub:
    return ok((subscription.topic, Opt.none(ContentTopic)))
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
    debug "Invalid API call to `subscribe`. WakuRelay not mounted."
    return err("Invalid API call to `subscribe`. WakuRelay not mounted.")

  let (pubsubTopic, _) = getTopicOfSubscriptionEvent(node, subscription).valueOr:
    debug "Failed to decode subscription event", error = error
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
    debug "Invalid API call to `unsubscribe`. WakuRelay not mounted."
    return err("Invalid API call to `unsubscribe`. WakuRelay not mounted.")

  let (pubsubTopic, _) = getTopicOfSubscriptionEvent(node, subscription).valueOr:
    debug "Failed to decode unsubscribe event", error = error
    return err("Failed to decode unsubscribe event: " & error)

  # strict version
  #if contentTopicOp.isSome():
  #  return node.subscriptionManager.unsubscribe(pubsubTopic, contentTopicOp.get())
  return node.subscriptionManager.unsubscribeAll(pubsubTopic)

proc isSubscribed*(
    node: WakuNode, subscription: SubscriptionEvent
): Result[bool, string] =
  if node.wakuRelay.isNil():
    debug "Invalid API call to `isSubscribed`. WakuRelay not mounted."
    return err("Invalid API call to `isSubscribed`. WakuRelay not mounted.")

  let (pubsubTopic, contentTopicOp) = getTopicOfSubscriptionEvent(node, subscription).valueOr:
    debug "Failed to decode subscription event", error = error
    return err("Failed to decode subscription event: " & error)

  return ok(node.wakuRelay.isSubscribed(pubsubTopic))

proc publish*(
    node: WakuNode, pubsubTopicOp: Opt[PubsubTopic], message: WakuMessage
): Future[Result[int, string]] {.async, gcsafe.} =
  ## Publish a `WakuMessage`. Pubsub topic contains; none, a named or static shard.
  ## `WakuMessage` should contain a `contentTopic` field for light node functionality.
  ## It is also used to determine the shard.

  if node.wakuRelay.isNil():
    let msg =
      "Invalid API call to `publish`. WakuRelay not mounted. Try `lightpush` instead."
    debug "Publish error", err = msg
    # TODO: Improve error handling
    return err(msg)

  let pubsubTopic = pubsubTopicOp.valueOr:
    if node.wakuAutoSharding.isNone():
      return err("Pubsub topic must be specified when static sharding is enabled.")
    node.wakuAutoSharding.get().getShard(message.contentTopic).valueOr:
      let msg = "Autosharding error: " & error
      return err(msg)

  let numPeers = (await node.wakuRelay.publish(pubsubTopic, message)).valueOr:
    debug "waku.relay did not publish", error = error
    # Todo: If NoPeersToPublish, we might want to return ok(0) instead!!!
    return err("publish failed in relay: " & $error)

  debug "waku.relay published",
    peerId = node.peerId,
    pubsubTopic = pubsubTopic,
    msg_hash = pubsubTopic.computeMessageHash(message).to0xHex(),
    publishTime = getNowInNanosecondTime(),
    numPeers = numPeers

  # TODO: investigate if we can return error in case numPeers is 0
  ok(numPeers)

proc mountRelay*(
    node: WakuNode,
    peerExchangeHandler = Opt.none(RoutingRecordsHandler),
    maxMessageSize = int(DefaultMaxWakuMessageSize),
): Future[Result[void, string]] {.async.} =
  if not node.wakuRelay.isNil():
    debug "wakuRelay already mounted, skipping"
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

  debug "relay mounted successfully"
  return ok()

  ## Waku RLN Relay

proc registerRlnValidator*(
    node: WakuNode,
    plugin: RlnPlugin,
    commonConf: RlnCommonConf,
    spamHandler = Opt.none(SpamHandler),
) =
  ## Registers the backend-agnostic RLN message validator. Verdicts come from
  ## the mounted backend's `validateProof`; the validator never names a backend.
  info "Setting rln validator"

  if node.wakuRelay.isNil():
    info "WakuRelay not mounted; RLN validator not set"
    return

  if commonConf.disableValidation:
    # Temporary RLN phase-in: published messages still carry proofs, but
    # received messages pass through unchecked.
    info "RLN proof validation is disabled; not registering the RLN validator"
    return

  let validateProof = plugin.validateProof
  if validateProof.isNil():
    info "RLN backend has no proof validation; RLN validator not set"
    return

  proc validator(
      topic: string, message: WakuMessage
  ): Future[pubsub.ValidationResult] {.async.} =
    trace "RLN topic validator is called"

    let res = (await validateProof(message)).valueOr:
      # no verdict from the backend — don't score the peer down for our own failure
      trace "RLN validator ignore", error = $error
      return pubsub.ValidationResult.Ignore

    let proof = byteutils.toHex(message.proof)
    case res.verdict
    of ProofVerdict.Valid:
      trace "Message validity is verified, relaying", proof = proof
      logos_delivery_rln_valid_messages_total.inc(labelValues = [topic])
      return pubsub.ValidationResult.Accept
    of ProofVerdict.Invalid:
      trace "Message validity could not be verified, discarding", proof = proof
      return pubsub.ValidationResult.Reject
    of ProofVerdict.Duplicate:
      trace "Duplicate rln proof, discarding", proof = proof
      return pubsub.ValidationResult.Reject
    of ProofVerdict.RateLimitViolation:
      trace "Rate limit violation found, discarding", proof = proof
      if spamHandler.isSome():
        let handler = spamHandler.get()
        handler(message)
      return pubsub.ValidationResult.Reject

  debug "Registering RLN validator"
  node.wakuRelay.addValidator(validator, RlnValidatorErrorMsg)

proc setRlnValidator*(
    node: WakuNode,
    rlnConf: WakuRlnConfig,
    spamHandler = Opt.none(SpamHandler),
    registrationHandler = Opt.none(RegistrationHandler),
) {.async.} =
  ## Compatibility entry for callers that construct the on-chain backend
  ## inline (tests, example apps): mounts it, records its handle on the node
  ## and registers the RLN validator.
  let rln = (await RlnEvm.new(rlnConf, registrationHandler, node.brokerCtx)).valueOr:
    raise newException(CatchableError, "failed to set rln validator: " & error)
  if (rlnConf.userMessageLimit > rln.groupManager.rlnRelayMaxMessageLimit):
    error "Rln-user-message-limit can't exceed the MAX_MESSAGE_LIMIT in the rln contract"

  node.rln = rln
  let plugin = rln.toRlnPlugin()
  node.rlnPlugin = Opt.some(plugin)

  node.registerRlnValidator(
    plugin,
    RlnCommonConf(
      onFatalErrorAction: rlnConf.onFatalErrorAction,
      disableValidation: rlnConf.disableValidation,
    ),
    spamHandler,
  )
