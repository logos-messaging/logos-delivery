## Waku Relay module. Thin layer on top of a pubsub backend (`IPubSub`).
##
## See https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-relay.md
## for spec.
{.push raises: [].}

import
  std/[strformat, strutils, sets, tables],
  stew/byteutils,
  results,
  sequtils,
  chronos,
  chronicles,
  metrics,
  brokers/broker_context

import
  logos_delivery/waku/waku_core,
  logos_delivery/waku/node/health_monitor/topic_health,
  logos_delivery/waku/requests/health_requests,
  logos_delivery/waku/api/events/health_events,
  logos_delivery/waku/libp2p_iface/pubsub,
  ./pubsub_params,
  logos_delivery/waku/api/events/peer_events

from logos_delivery/waku/waku_core/codecs import WakuRelayCodec
export WakuRelayCodec
export pubsub

type ShardMetrics = object
  count: float64
  sizeSum: float64
  avgSize: float64
  maxSize: float64

logScope:
  topics = "waku relay"

declareCounter logos_delivery_relay_network_bytes,
  "total traffic per topic, distinct gross/net and direction",
  labels = ["topic", "type", "direction"]

declarePublicGauge(
  logos_delivery_relay_total_msg_bytes_per_shard,
  "total length of messages seen per shard",
  labels = ["shard"],
)

declarePublicGauge(
  logos_delivery_relay_max_msg_bytes_per_shard,
  "Maximum length of messages seen per shard",
  labels = ["shard"],
)

declarePublicGauge(
  logos_delivery_relay_avg_msg_bytes_per_shard,
  "Average length of messages seen per shard",
  labels = ["shard"],
)

type
  WakuRelayHandler* = proc(pubsubTopic: PubsubTopic, message: WakuMessage): Future[void] {.
    gcsafe, raises: [Defect]
  .}
  WakuValidatorHandler* = proc(
    pubsubTopic: PubsubTopic, message: WakuMessage
  ): Future[ValidationResult] {.gcsafe, raises: [Defect].}

  RelayPeer* = object
    peerId*: PeerIdStr
    score*: float64

  RelayTopologyChangeHandler* = proc() {.gcsafe, raises: [].}

  WakuRelayOf*[P: IPubSub] = ref object
    pubsub*: P
    maxMessageSize*: int
    brokerCtx: BrokerContext
    peerEventListener: WakuPeerEventListener
    # seq of tuples: the first entry in the tuple contains the validators are called for every topic
    # the second entry contains the error messages to be returned when the validator fails
    wakuValidators: seq[tuple[handler: WakuValidatorHandler, errorMessage: string]]
    validatedTopics: HashSet[PubsubTopic]
      # topics that already have the ordered validator installed in the pubsub backend
    handledTopics: HashSet[PubsubTopic] # topics with an active subscription handler
    topicsHealth*: Table[string, TopicHealth]
    onTopicHealthChange*: TopicHealthChangeHandler
    topicHealthLoopHandle*: Future[void]
    topicHealthUpdateEvent: AsyncEvent
    topicHealthDirty: HashSet[string]
      # list of topics that need their health updated in the update event
    topicHealthCheckAll: bool
      # true if all topics need to have their health status refreshed in the update event
    msgMetricsPerShard*: Table[string, ShardMetrics]
    topologyHandler: RelayTopologyChangeHandler

# predefinition for more detailed results from publishing new message
type PublishOutcome* {.pure.} = enum
  NoTopicSpecified
  DuplicateMessage
  NoPeersToPublish
  CannotGenerateMessageId

proc logMessageInfo*[P: IPubSub](
    w: WakuRelayOf[P],
    remotePeerId: string,
    topic: string,
    msg_id_short: string,
    msg: WakuMessage,
    onRecv: bool,
) =
  let msg_hash = computeMessageHash(topic, msg).to0xHex()
  let payloadSize = float64(msg.payload.len)

  if onRecv:
    trace "Received relay message",
      my_peer_id = w.pubsub.selfPeerId().shortPeerId(),
      msg_hash = msg_hash,
      msg_id = msg_id_short,
      from_peer_id = remotePeerId,
      topic = topic,
      contentTopic = msg.contentTopic,
      receivedTime = getNowInNanosecondTime(),
      payloadSizeBytes = payloadSize
  else:
    trace "Sent relay message",
      my_peer_id = w.pubsub.selfPeerId().shortPeerId(),
      msg_hash = msg_hash,
      msg_id = msg_id_short,
      to_peer_id = remotePeerId,
      topic = topic,
      contentTopic = msg.contentTopic,
      sentTime = getNowInNanosecondTime(),
      payloadSizeBytes = payloadSize

  var shardMetrics = w.msgMetricsPerShard.getOrDefault(topic, ShardMetrics())
  shardMetrics.count += 1
  shardMetrics.sizeSum += payloadSize
  if payloadSize > shardMetrics.maxSize:
    shardMetrics.maxSize = payloadSize
  shardMetrics.avgSize = shardMetrics.sizeSum / shardMetrics.count
  w.msgMetricsPerShard[topic] = shardMetrics

  logos_delivery_relay_max_msg_bytes_per_shard.set(
    shardMetrics.maxSize, labelValues = [topic]
  )

  logos_delivery_relay_avg_msg_bytes_per_shard.set(
    shardMetrics.avgSize, labelValues = [topic]
  )

  logos_delivery_relay_total_msg_bytes_per_shard.set(
    shardMetrics.sizeSum, labelValues = [topic]
  )

proc updateNetworkMetrics(topic: string, msgSize: int, onRecv: bool) =
  if onRecv:
    logos_delivery_relay_network_bytes.inc(
      msgSize.int64, labelValues = [topic, "gross", "in"]
    )
  else:
    # sent traffic can only be "net"
    # TODO: If we can measure unsuccessful sends would mean a possible distinction between gross/net
    logos_delivery_relay_network_bytes.inc(
      msgSize.int64, labelValues = [topic, "net", "out"]
    )

proc handlePubSubEvent[P: IPubSub](w: WakuRelayOf[P], event: PubSubEvent) =
  case event.kind
  of PubSubEventKind.TopologyChanged:
    var topicsChanged = false
    for topic in event.meshTopics:
      w.topicHealthDirty.incl(topic)
      topicsChanged = true

    if topicsChanged:
      w.topicHealthUpdateEvent.fire()

    if not w.topologyHandler.isNil():
      w.topologyHandler()
  of PubSubEventKind.MessageReceived, PubSubEventKind.MessageSent:
    let onRecv = event.kind == PubSubEventKind.MessageReceived
    let wakuMessage = WakuMessage.decode(event.data).valueOr:
      if onRecv:
        debug "Error decoding to Waku Message",
          my_peer_id = w.pubsub.selfPeerId().shortPeerId(),
          msg_id = event.msgId,
          from_peer_id = event.peerId.shortPeerId(),
          pubsub_topic = event.topic,
          error = $error
      else:
        debug "onSend: failed decoding RPC info",
          my_peer_id = w.pubsub.selfPeerId().shortPeerId(),
          to_peer_id = event.peerId.shortPeerId()
      return

    # message receive log happens on MessageValidated, as MessageReceived comes before checks
    if not onRecv:
      w.logMessageInfo(
        event.peerId.shortPeerId(),
        event.topic,
        event.msgId,
        wakuMessage,
        onRecv = false,
      )
    updateNetworkMetrics(event.topic, event.data.len + event.topic.len, onRecv)
  of PubSubEventKind.MessageValidated:
    let wakuMessage = WakuMessage.decode(event.data).valueOr:
      debug "onValidated: failed decoding to Waku Message",
        my_peer_id = w.pubsub.selfPeerId().shortPeerId(),
        msg_id = event.msgId,
        from_peer_id = event.peerId.shortPeerId(),
        pubsub_topic = event.topic,
        error = $error
      return

    w.logMessageInfo(
      event.peerId.shortPeerId(), event.topic, event.msgId, wakuMessage, onRecv = true
    )

proc new*[P: IPubSub](
    T: type WakuRelayOf[P], pubsub: P, maxMessageSize = int(DefaultMaxWakuMessageSize)
): Result[WakuRelayOf[P], string] =
  ## maxMessageSize: max num bytes that are allowed for the WakuMessage
  let w = WakuRelayOf[P](
    pubsub: pubsub,
    maxMessageSize: maxMessageSize,
    brokerCtx: globalBrokerContext(),
    topicsHealth: initTable[string, TopicHealth](),
    topicHealthUpdateEvent: newAsyncEvent(),
    topicHealthDirty: initHashSet[string](),
    topicHealthCheckAll: false,
  )

  pubsub.setEventHandler(
    proc(event: PubSubEvent) {.gcsafe, raises: [].} =
      w.handlePubSubEvent(event)
  )

  w.peerEventListener = WakuPeerEvent.listen(
    w.brokerCtx,
    proc(evt: WakuPeerEvent): Future[void] {.async: (raises: []), gcsafe.} =
      if evt.kind == WakuPeerEventKind.EventDisconnected:
        w.topicHealthCheckAll = true
        w.topicHealthUpdateEvent.fire()
    ,
  ).valueOr:
    return err("Failed to subscribe to peer events: " & error)

  return ok(w)

proc addValidator*[P: IPubSub](
    w: WakuRelayOf[P], handler: WakuValidatorHandler, errorMessage: string = ""
) {.gcsafe.} =
  w.wakuValidators.add((handler, errorMessage))

proc clearTopologyChangeHandler*[P: IPubSub](w: WakuRelayOf[P]) {.gcsafe.} =
  w.topologyHandler = nil

proc onTopologyChange*[P: IPubSub](
    w: WakuRelayOf[P], handler: RelayTopologyChangeHandler
) {.gcsafe.} =
  ## Calls handler when a peer changes its subscriptions or mesh membership (GRAFT/PRUNE).
  ## Only one handler is kept; a new one replaces the previous.
  w.topologyHandler = handler

proc meshTargetDegree*[P: IPubSub](w: WakuRelayOf[P]): int =
  return w.pubsub.params().d

proc meshLowDegree*[P: IPubSub](w: WakuRelayOf[P]): int =
  return w.pubsub.params().dLow

proc pruneBackoff*[P: IPubSub](w: WakuRelayOf[P]): Duration =
  return w.pubsub.params().pruneBackoff

proc reconnectBackoff*[P: IPubSub](w: WakuRelayOf[P]): Duration =
  ## How long to wait before reconnecting to the relay peers pruned on a restart.
  return w.pruneBackoff() + PruneBackoffSlack

proc enablePeerExchange*[P: IPubSub](
    w: WakuRelayOf[P], handler: PubSubPeerExchangeHandler
) =
  mixin enablePeerExchange
  w.pubsub.enablePeerExchange(handler)

proc setTriggerSelf*[P: IPubSub](w: WakuRelayOf[P], value: bool) =
  mixin setTriggerSelf
  w.pubsub.setTriggerSelf(value)

proc getDHigh*(T: type WakuRelayOf): int =
  return WakuPubSubParams.dHigh

proc getPeersInMesh*[P: IPubSub](
    w: WakuRelayOf[P], pubsubTopic: PubsubTopic = ""
): Result[seq[PeerIdStr], string] =
  ## Returns the list of peerIds in a mesh defined by the passed pubsub topic.
  ## If pubsubTopic is empty, it returns all peers in mesh for any pubsub topic.
  let peers = ?w.pubsub.meshPeers(pubsubTopic)
  return ok(peers.mapIt(it.peerId))

proc getNumPeersInMesh*[P: IPubSub](
    w: WakuRelayOf[P], pubsubTopic: PubsubTopic
): Result[int, string] =
  ## Returns the number of peers in a mesh defined by the passed pubsub topic.

  let peers = w.pubsub.meshPeers(pubsubTopic).valueOr:
    return err(
      "getNumPeersInMesh - failed retrieving peers in mesh: " & pubsubTopic & ": " &
        error
    )

  return ok(peers.len)

proc calculateTopicHealth[P: IPubSub](w: WakuRelayOf[P], topic: string): TopicHealth =
  let numPeersInMesh = w.getNumPeersInMesh(topic).valueOr:
    debug "Could not calculate topic health", topic = topic, error = error
    return TopicHealth.UNHEALTHY

  if numPeersInMesh < 1:
    return TopicHealth.UNHEALTHY
  elif numPeersInMesh < w.meshLowDegree():
    return TopicHealth.MINIMALLY_HEALTHY
  return TopicHealth.SUFFICIENTLY_HEALTHY

proc isSubscribed*[P: IPubSub](w: WakuRelayOf[P], topic: PubsubTopic): bool =
  topic in w.pubsub.topics()

proc subscribedTopics*[P: IPubSub](w: WakuRelayOf[P]): seq[PubsubTopic] =
  return w.pubsub.topics()

proc topicsHealthLoop[P: IPubSub](w: WakuRelayOf[P]) {.async.} =
  while true:
    await w.topicHealthUpdateEvent.wait()
    w.topicHealthUpdateEvent.clear()

    var topicsToCheck: seq[string]

    if w.topicHealthCheckAll:
      topicsToCheck = w.pubsub.topics()
    else:
      for topic in sets.items(w.topicHealthDirty):
        topicsToCheck.add(topic)

    w.topicHealthCheckAll = false
    w.topicHealthDirty.clear()

    var futs = newSeq[Future[void]]()

    for topic in topicsToCheck:
      # guard against topic being unsubscribed since fire()
      if not w.isSubscribed(topic):
        continue

      let
        oldHealth = w.topicsHealth.getOrDefault(topic, TopicHealth.UNHEALTHY)
        currentHealth = w.calculateTopicHealth(topic)

      if oldHealth == currentHealth:
        continue

      w.topicsHealth[topic] = currentHealth

      EventShardTopicHealthChange.emit(w.brokerCtx, topic, currentHealth)

      if not w.onTopicHealthChange.isNil():
        futs.add(w.onTopicHealthChange(topic, currentHealth))

    if futs.len() > 0:
      try:
        discard await allFinished(futs)
      except CancelledError:
        break
      except CatchableError as e:
        debug "Error in topic health callback", error = e.msg

    # safety cooldown to protect from edge cases
    await sleepAsync(100.milliseconds)

proc start*[P: IPubSub](
    w: WakuRelayOf[P]
): Future[void] {.async: (raises: [CancelledError]).} =
  mixin start
  info "start"
  await w.pubsub.start()
  if w.topicHealthLoopHandle.isNil():
    w.topicHealthLoopHandle = w.topicsHealthLoop()

proc stop*[P: IPubSub](w: WakuRelayOf[P]): Future[void] {.async: (raises: []).} =
  mixin stop
  info "stop"
  await w.pubsub.stop()

  await WakuPeerEvent.dropListener(w.brokerCtx, w.peerEventListener)

  if not w.topicHealthLoopHandle.isNil():
    await w.topicHealthLoopHandle.cancelAndWait()
    w.topicHealthLoopHandle = nil

proc generateOrderedValidator[P: IPubSub](
    w: WakuRelayOf[P]
): PubSubValidator {.gcsafe.} =
  # rejects messages that are not WakuMessage
  let wrappedValidator = proc(
      pubsubTopic: string, data: seq[byte]
  ): Future[ValidationResult] {.async.} =
    # can be optimized by checking if the message is a WakuMessage without allocating memory
    # see nim-libp2p protobuf library
    let msg = WakuMessage.decode(data).valueOr:
      debug "Rejecting relay message, decode error",
        pubsubTopic = pubsubTopic, error = $error
      return ValidationResult.Reject

    # now sequentially validate the message
    for (validator, errorMessage) in w.wakuValidators:
      let validatorRes = await validator(pubsubTopic, msg)

      if validatorRes != ValidationResult.Accept:
        let msgHash = computeMessageHash(pubsubTopic, msg).to0xHex()
        debug "Rejecting relay message, waku validator rejected",
          msg_hash = msgHash,
          pubsubTopic = pubsubTopic,
          contentTopic = msg.contentTopic,
          validatorRes = validatorRes,
          error = errorMessage

        return validatorRes

    return ValidationResult.Accept

  return wrappedValidator

proc validateMessage*[P: IPubSub](
    w: WakuRelayOf[P], pubsubTopic: string, msg: WakuMessage
): Future[Result[void, string]] {.async.} =
  let messageSizeBytes = msg.encode().buffer.len
  let msgHash = computeMessageHash(pubsubTopic, msg).to0xHex()

  if messageSizeBytes > w.maxMessageSize:
    let message = fmt"Message size exceeded maximum of {w.maxMessageSize} bytes"
    debug "Too large Waku message",
      msg_hash = msgHash,
      error = message,
      messageSizeBytes = messageSizeBytes,
      maxMessageSize = w.maxMessageSize

    return err(message)

  for (validator, message) in w.wakuValidators:
    let validatorRes = await validator(pubsubTopic, msg)
    if validatorRes != ValidationResult.Accept:
      if message.len > 0:
        debug "Invalid Waku message", msg_hash = msgHash, error = message
        return err(message)
      else:
        ## This should never happen
        error "uncertain invalid Waku message", msg_hash = msgHash, error = message
        return err("validator failed")

  return ok()

proc subscribe*[P: IPubSub](
    w: WakuRelayOf[P], pubsubTopic: PubsubTopic, handler: WakuRelayHandler
) =
  mixin subscribe, addValidator
  debug "Subscribing to pubsub topic", pubsubTopic = pubsubTopic

  # We need to wrap the handler since the backend doesnt understand WakuMessage
  let topicHandler = proc(
      pubsubTopic: string, data: seq[byte]
  ): Future[void] {.gcsafe, raises: [].} =
    let decMsg = WakuMessage.decode(data).valueOr:
      # fine if triggerSelf enabled, since validators are bypassed
      debug "Failed to decode WakuMessage, validator passed a wrong message",
        pubsubTopic = pubsubTopic, error = error
      let fut = newFuture[void]()
      fut.complete()
      return fut
    # this subscription handler is called once for every validated message
    # that will be relayed, hence this is the place we can count net incoming traffic
    logos_delivery_relay_network_bytes.inc(
      data.len.int64 + pubsubTopic.len.int64, labelValues = [pubsubTopic, "net", "in"]
    )

    return handler(pubsubTopic, decMsg)

  # Add the ordered validator to the topic
  # This assumes that if `w.validatedTopics.contains(pubSubTopic)`, it has the ordered validator.
  # Otherwise this might lead to unintended behaviour.
  if pubSubTopic notin w.validatedTopics:
    w.pubsub.addValidator(pubSubTopic, w.generateOrderedValidator())
    w.validatedTopics.incl(pubSubTopic)

  # set this topic parameters for scoring
  w.pubsub.setTopicScoreParams(pubsubTopic, WakuTopicScoreParams)

  # subscribe to the topic with our wrapped handler
  w.pubsub.subscribe(pubsubTopic, topicHandler)

  w.handledTopics.incl(pubsubTopic)
  w.topicHealthDirty.incl(pubsubTopic)
  w.topicHealthUpdateEvent.fire()

proc unsubscribeAll*[P: IPubSub](w: WakuRelayOf[P], pubsubTopic: PubsubTopic) =
  mixin unsubscribeAll
  ## Unsubscribe all handlers on this pubsub topic

  debug "Unsubscribe all", pubsubTopic = pubsubTopic

  w.pubsub.unsubscribeAll(pubsubTopic)
  w.validatedTopics.excl(pubsubTopic)
  w.handledTopics.excl(pubsubTopic)
  w.topicsHealth.del(pubsubTopic)
  w.topicHealthDirty.excl(pubsubTopic)

proc unsubscribe*[P: IPubSub](w: WakuRelayOf[P], pubsubTopic: PubsubTopic) =
  mixin unsubscribe, removeValidator
  if pubsubTopic notin w.validatedTopics:
    debug "Unsubscribe: no validator for this topic", pubsubTopic
    return

  if pubsubTopic notin w.handledTopics:
    debug "Not subscribed to the given topic", pubsubTopic
    return

  debug "Unsubscribe", pubsubTopic
  w.pubsub.unsubscribe(pubsubTopic)
  w.pubsub.removeValidator(pubsubTopic)

  w.validatedTopics.excl(pubsubTopic)
  w.handledTopics.excl(pubsubTopic)
  w.topicsHealth.del(pubsubTopic)
  w.topicHealthDirty.excl(pubsubTopic)

proc publish*[P: IPubSub](
    w: WakuRelayOf[P], pubsubTopic: PubsubTopic, wakuMessage: WakuMessage
): Future[Result[int, PublishOutcome]] {.async.} =
  mixin publish
  if pubsubTopic.isEmptyOrWhitespace():
    return err(NoTopicSpecified)

  var message = wakuMessage
  if message.timestamp == 0:
    message.timestamp = getNowInNanosecondTime()

  let data = message.encode().buffer

  let msgHash = computeMessageHash(pubsubTopic, message).to0xHex()
  trace "Start publish Waku message",
    msg_hash = msgHash, pubsubTopic = pubsubTopic, contentTopic = message.contentTopic

  let relayedPeerCount = await w.pubsub.publish(pubsubTopic, data)

  if relayedPeerCount <= 0:
    return err(NoPeersToPublish)

  return ok(relayedPeerCount)

proc getConnectedPeers*[P: IPubSub](
    w: WakuRelayOf[P], pubsubTopic: PubsubTopic
): Result[seq[PeerIdStr], string] =
  ## Returns the list of peerIds of connected peers and subscribed to the passed pubsub topic.
  let peers = ?w.pubsub.connectedPeers(pubsubTopic)
  return ok(peers.mapIt(it.peerId))

proc getNumConnectedPeers*[P: IPubSub](
    w: WakuRelayOf[P], pubsubTopic: PubsubTopic
): Result[int, string] =
  ## Returns the number of connected peers and subscribed to the passed pubsub topic.
  let peers = w.pubsub.connectedPeers(pubsubTopic).valueOr:
    return err(
      "getNumConnectedPeers - failed retrieving peers in mesh: " & pubsubTopic & ": " &
        error
    )

  return ok(peers.len)

proc getSubscribedTopics*[P: IPubSub](w: WakuRelayOf[P]): seq[PubsubTopic] =
  ## Returns a seq containing the current list of subscribed topics
  return w.pubsub.topics()

proc toRelayPeers(peers: seq[PubSubPeerInfo]): seq[RelayPeer] =
  return peers.mapIt(RelayPeer(peerId: it.peerId, score: it.score))

proc getConnectedRelayPeers*[P: IPubSub](
    w: WakuRelayOf[P], pubsubTopic: PubsubTopic
): seq[RelayPeer] =
  let peers = w.pubsub.connectedPeers(pubsubTopic).valueOr:
    return @[]
  return peers.toRelayPeers()

proc getMeshRelayPeers*[P: IPubSub](
    w: WakuRelayOf[P], pubsubTopic: PubsubTopic
): seq[RelayPeer] =
  let peers = w.pubsub.meshPeers(pubsubTopic).valueOr:
    return @[]
  return peers.toRelayPeers()
