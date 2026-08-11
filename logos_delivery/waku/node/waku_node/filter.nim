{.push raises: [].}

import
  std/[sugar, tables, sequtils, os, net],
  chronos,
  chronicles,
  metrics,
  results,
  stew/byteutils,
  eth/keys,
  nimcrypto,
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
  ../node_telemetry,
  ../../waku_core,
  ../../waku_core/topics/sharding,
  ../../waku_filter_v2,
  ../../waku_filter_v2/client as filter_client,
  ../../waku_filter_v2/subscriptions as filter_subscriptions,
  ../../common/rate_limit/setting,
  ../peer_manager

logScope:
  topics = "waku node filter api"

## Waku filter

proc mountFilter*(
    node: WakuNode,
    subscriptionTimeout: Duration =
      filter_subscriptions.DefaultSubscriptionTimeToLiveSec,
    maxFilterPeers: uint32 = filter_subscriptions.MaxFilterPeers,
    maxFilterCriteriaPerPeer: uint32 = filter_subscriptions.MaxFilterCriteriaPerPeer,
    messageCacheTTL: Duration = filter_subscriptions.MessageCacheTTL,
    rateLimitSetting: RateLimitSetting = FilterDefaultPerPeerRateLimit,
) {.async: (raises: []).} =
  ## Mounting filter v2 protocol

  info "mounting filter protocol"
  node.wakuFilter = WakuFilter.new(
    node.peerManager,
    subscriptionTimeout,
    maxFilterPeers,
    maxFilterCriteriaPerPeer,
    messageCacheTTL,
    Opt.some(rateLimitSetting),
  )

  try:
    await node.wakuFilter.start()
  except CatchableError:
    error "failed to start wakuFilter", error = getCurrentExceptionMsg()

  try:
    node.switch.mount(node.wakuFilter, protocolMatcher(WakuFilterSubscribeCodec))
  except LPError:
    error "failed to mount wakuFilter", error = getCurrentExceptionMsg()

proc filterHandleMessage*(
    node: WakuNode, pubsubTopic: PubsubTopic, message: WakuMessage
) {.async.} =
  if node.wakuFilter.isNil():
    debug "Cannot handle filter message", error = "waku filter is required"
    return

  await node.wakuFilter.handleMessage(pubsubTopic, message)

proc mountFilterClient*(node: WakuNode) {.async: (raises: []).} =
  ## Mounting both filter
  ## Giving option for application level to choose btw own push message handling or
  ## rely on node provided cache. - This only applies for v2 filter client
  info "mounting filter client"

  if not node.wakuFilterClient.isNil():
    trace "Filter client already mounted."
    return

  node.wakuFilterClient = WakuFilterClient.new(node.peerManager, node.rng)

  try:
    await node.wakuFilterClient.start()
  except CatchableError:
    error "failed to start wakuFilterClient", error = getCurrentExceptionMsg()

  try:
    node.switch.mount(node.wakuFilterClient, protocolMatcher(WakuFilterSubscribeCodec))
  except LPError:
    error "failed to mount wakuFilterClient", error = getCurrentExceptionMsg()

proc filterSubscribe*(
    node: WakuNode,
    pubsubTopic: Opt[PubsubTopic],
    contentTopics: ContentTopic | seq[ContentTopic],
    peer: RemotePeerInfo | string,
): Future[FilterSubscribeResult] {.async: (raises: []).} =
  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  if node.wakuFilterClient.isNil():
    debug "Cannot register filter subscription to topic",
      error = "waku filter client is not set up"
    return err(FilterSubscribeError.serviceUnavailable())

  let remotePeer = parsePeerInfo(peer).valueOr:
    debug "Couldn't parse the peer info properly", error = error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  if pubsubTopic.isSome():
    debug "Registering filter subscription to content",
      pubsubTopic = pubsubTopic.get(),
      contentTopics = contentTopics,
      peer = remotePeer.peerId

    when (contentTopics is ContentTopic):
      let contentTopics = @[contentTopics]
    let subRes = await node.wakuFilterClient.subscribe(
      remotePeer, pubsubTopic.get(), contentTopics
    )
    if subRes.isOk():
      debug "v2 subscribed to topic",
        pubsubTopic = pubsubTopic, contentTopics = contentTopics

      # Purpose is to update Waku Metadata
      node.topicSubscriptionQueue.emit((kind: PubsubSub, topic: pubsubTopic.get()))
    else:
      debug "Failed filter v2 subscription", error = subRes.error
      logos_delivery_node_errors.inc(labelValues = ["subscribe_filter_failure"])

    return subRes
  elif node.wakuAutoSharding.isNone():
    debug "Failed filter subscription, pubsub topic must be specified with static sharding"
    logos_delivery_node_errors.inc(labelValues = ["subscribe_filter_failure"])
  else:
    # No pubsub topic, autosharding is used to deduce it
    # but content topics must be well-formed for this
    let topicMap = node.wakuAutoSharding
      .get()
      .getShardsFromContentTopics(contentTopics).valueOr:
        debug "Can't get shard", error = error
        return err(FilterSubscribeError.badResponse("can't get shard"))

    var futures = collect(newSeq):
      for shard, topics in topicMap.pairs:
        debug "Registering filter subscription to content",
          shard = shard, contentTopics = topics, peer = remotePeer.peerId
        let content = topics.mapIt($it)
        node.wakuFilterClient.subscribe(remotePeer, $shard, content)

    var subRes: FilterSubscribeResult = FilterSubscribeResult.ok()
    try:
      let finished = await allFinished(futures)

      for fut in finished:
        let res = fut.read()

        if res.isErr():
          debug "Failed filter subscription", error = res.error
          logos_delivery_node_errors.inc(labelValues = ["subscribe_filter_failure"])
          subRes = FilterSubscribeResult.err(res.error)

      for pubsub, topics in topicMap.pairs:
        info "subscribed to topic", pubsubTopic = pubsub, contentTopics = topics

        # Purpose is to update Waku Metadata
        node.topicSubscriptionQueue.emit((kind: PubsubSub, topic: $pubsub))
    except CatchableError:
      let errMsg = "exception in filterSubscribe: " & getCurrentExceptionMsg()
      debug "Exception in filterSubscribe", error = getCurrentExceptionMsg()
      logos_delivery_node_errors.inc(labelValues = ["subscribe_filter_failure"])
      subRes =
        FilterSubscribeResult.err(FilterSubscribeError.serviceUnavailable(errMsg))

    # return the last error or ok
    return subRes

proc filterUnsubscribe*(
    node: WakuNode,
    pubsubTopic: Opt[PubsubTopic],
    contentTopics: ContentTopic | seq[ContentTopic],
    peer: RemotePeerInfo | string,
): Future[FilterSubscribeResult] {.async: (raises: []).} =
  ## Unsubscribe from a content filter V2".

  let remotePeer = parsePeerInfo(peer).valueOr:
    debug "Couldn't parse remotePeerInfo", error = error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  if pubsubTopic.isSome():
    debug "Deregistering filter subscription to content",
      pubsubTopic = pubsubTopic.get(),
      contentTopics = contentTopics,
      peer = remotePeer.peerId

    let unsubRes = await node.wakuFilterClient.unsubscribe(
      remotePeer, pubsubTopic.get(), contentTopics
    )
    if unsubRes.isOk():
      debug "Unsubscribed from topic",
        pubsubTopic = pubsubTopic.get(), contentTopics = contentTopics

      # Purpose is to update Waku Metadata
      node.topicSubscriptionQueue.emit((kind: PubsubUnsub, topic: pubsubTopic.get()))
    else:
      debug "Failed filter unsubscription", error = unsubRes.error
      logos_delivery_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])

    return unsubRes
  elif node.wakuAutoSharding.isNone():
    debug "Failed filter un-subscription, pubsub topic must be specified with static sharding"
    logos_delivery_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])
  else: # pubsubTopic.isNone
    let topicMap = node.wakuAutoSharding
      .get()
      .getShardsFromContentTopics(contentTopics).valueOr:
        debug "Can't get shard", error = error
        return err(FilterSubscribeError.badResponse("can't get shard"))

    var futures = collect(newSeq):
      for shard, topics in topicMap.pairs:
        debug "Deregistering filter subscription to content",
          shard = shard, contentTopics = topics, peer = remotePeer.peerId
        let content = topics.mapIt($it)
        node.wakuFilterClient.unsubscribe(remotePeer, $shard, content)

    var unsubRes: FilterSubscribeResult = FilterSubscribeResult.ok()
    try:
      let finished = await allFinished(futures)

      for fut in finished:
        let res = fut.read()

        if res.isErr():
          debug "Failed filter unsubscription", error = res.error
          logos_delivery_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])
          unsubRes = FilterSubscribeResult.err(res.error)

      for pubsub, topics in topicMap.pairs:
        debug "Unsubscribed from topic", pubsubTopic = pubsub, contentTopics = topics

        # Purpose is to update Waku Metadata
        node.topicSubscriptionQueue.emit((kind: PubsubUnsub, topic: $pubsub))
    except CatchableError:
      let errMsg = "exception in filterUnsubscribe: " & getCurrentExceptionMsg()
      debug "Exception in filterUnsubscribe", error = getCurrentExceptionMsg()
      logos_delivery_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])
      unsubRes =
        FilterSubscribeResult.err(FilterSubscribeError.serviceUnavailable(errMsg))

    # return the last error or ok
    return unsubRes

proc filterUnsubscribeAll*(
    node: WakuNode, peer: RemotePeerInfo | string
): Future[FilterSubscribeResult] {.async: (raises: []).} =
  ## Unsubscribe from a content filter V2".

  let remotePeer = parsePeerInfo(peer).valueOr:
    debug "Couldn't parse remotePeerInfo", error = error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  debug "Deregistering all filter subscription to content", peer = remotePeer.peerId

  let unsubRes = await node.wakuFilterClient.unsubscribeAll(remotePeer)
  if unsubRes.isOk():
    debug "Unsubscribed from all content-topic", peerId = remotePeer.peerId
  else:
    debug "Failed filter unsubscription from all content-topic", error = unsubRes.error
    logos_delivery_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])

  return unsubRes

# NOTICE: subscribe / unsubscribe methods are removed - they were already depricated
# yet incompatible to handle both type of filters - use specific filter registration instead
