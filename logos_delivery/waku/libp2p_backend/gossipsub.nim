## nim-libp2p GossipSub implementation of the `IPubSub` interface.
##
## This is the only place where pubsub code touches nim-libp2p types.
{.push raises: [].}

import
  std/[sets, tables, sequtils],
  results,
  chronos,
  chronicles,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/stream/connection,
  libp2p/peerid,
  libp2p/switch
import ../libp2p_iface/pubsub except ValidationResult
from ../libp2p_iface/pubsub as iface import nil
import ./message_id

logScope:
  topics = "waku gossipsub backend"

type GossipSubBackend* = ref object
  gossip*: GossipSub
  switch*: Switch
  validators: Table[string, ValidatorHandler]
  handlers: Table[string, TopicHandler]
  eventHandler: PubSubEventHandler

func toGossipSubParams(p: PubSubParams): GossipSubParams =
  return GossipSubParams.init(
    pruneBackoff = p.pruneBackoff,
    unsubscribeBackoff = p.unsubscribeBackoff,
    floodPublish = p.floodPublish,
    gossipFactor = p.gossipFactor,
    d = p.d,
    dLow = p.dLow,
    dHigh = p.dHigh,
    dScore = p.dScore,
    dOut = p.dOut,
    dLazy = p.dLazy,
    heartbeatInterval = p.heartbeatInterval,
    historyLength = p.historyLength,
    historyGossip = p.historyGossip,
    fanoutTTL = p.fanoutTTL,
    seenTTL = p.seenTTL,
    gossipThreshold = p.gossipThreshold,
    publishThreshold = p.publishThreshold,
    graylistThreshold = p.graylistThreshold,
    opportunisticGraftThreshold = p.opportunisticGraftThreshold,
    decayInterval = p.decayInterval,
    decayToZero = p.decayToZero,
    retainScore = p.retainScore,
    appSpecificWeight = p.appSpecificWeight,
    ipColocationFactorWeight = p.ipColocationFactorWeight,
    ipColocationFactorThreshold = p.ipColocationFactorThreshold,
    behaviourPenaltyWeight = p.behaviourPenaltyWeight,
    behaviourPenaltyDecay = p.behaviourPenaltyDecay,
    disconnectBadPeers = p.disconnectBadPeers,
  )

func toTopicParams(p: TopicScoreParams): TopicParams =
  return TopicParams(
    topicWeight: p.topicWeight,
    timeInMeshWeight: p.timeInMeshWeight,
    timeInMeshQuantum: p.timeInMeshQuantum,
    timeInMeshCap: p.timeInMeshCap,
    firstMessageDeliveriesWeight: p.firstMessageDeliveriesWeight,
    firstMessageDeliveriesDecay: p.firstMessageDeliveriesDecay,
    firstMessageDeliveriesCap: p.firstMessageDeliveriesCap,
    meshMessageDeliveriesWeight: p.meshMessageDeliveriesWeight,
    meshMessageDeliveriesDecay: p.meshMessageDeliveriesDecay,
    meshMessageDeliveriesThreshold: p.meshMessageDeliveriesThreshold,
    meshMessageDeliveriesCap: p.meshMessageDeliveriesCap,
    meshMessageDeliveriesActivation: p.meshMessageDeliveriesActivation,
    meshMessageDeliveriesWindow: p.meshMessageDeliveriesWindow,
    meshFailurePenaltyWeight: p.meshFailurePenaltyWeight,
    meshFailurePenaltyDecay: p.meshFailurePenaltyDecay,
    invalidMessageDeliveriesWeight: p.invalidMessageDeliveriesWeight,
    invalidMessageDeliveriesDecay: p.invalidMessageDeliveriesDecay,
  )

func toLibp2p(r: iface.ValidationResult): ValidationResult =
  case r
  of iface.ValidationResult.Accept: ValidationResult.Accept
  of iface.ValidationResult.Reject: ValidationResult.Reject
  of iface.ValidationResult.Ignore: ValidationResult.Ignore

func toPeerInfos(peers: HashSet[PubSubPeer]): seq[PubSubPeerInfo] =
  return toSeq(peers).mapIt(PubSubPeerInfo(peerId: $it.peerId, score: it.score))

proc emit(b: GossipSubBackend, event: PubSubEvent) =
  if not b.eventHandler.isNil():
    b.eventHandler(event)

proc installObserver(b: GossipSubBackend) =
  let gossip = b.gossip

  proc messageId(peer: PubSubPeer, msg: Message): Opt[string] =
    let msgId = gossip.msgIdProvider(msg).valueOr:
      debug "Error generating message id",
        from_peer_id = peer.peerId, pubsub_topic = msg.topic, error = $error
      return Opt.none(string)
    return Opt.some(shortLog(msgId))

  proc onRecv(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].} =
    var meshTopics: seq[string]
    if msgs.control.isSome():
      let ctrl = msgs.control.get()
      for graft in ctrl.graft:
        if graft.topicID.len > 0:
          meshTopics.add(graft.topicID)
      for prune in ctrl.prune:
        if prune.topicID.len > 0:
          meshTopics.add(prune.topicID)

    let subscriptionsChanged = msgs.subscriptions.len > 0
    if subscriptionsChanged or meshTopics.len > 0:
      b.emit(
        PubSubEvent(
          kind: PubSubEventKind.TopologyChanged,
          peerId: $peer.peerId,
          subscriptionsChanged: subscriptionsChanged,
          meshTopics: meshTopics,
        )
      )

    for msg in msgs.messages:
      let msgId = peer.messageId(msg).valueOr:
        continue
      b.emit(
        PubSubEvent(
          kind: PubSubEventKind.MessageReceived,
          peerId: $peer.peerId,
          topic: msg.topic,
          msgId: msgId,
          data: msg.payloadBytes,
        )
      )

  proc onValidated(
      peer: PubSubPeer, msg: Message, msgId: MessageId
  ) {.gcsafe, raises: [].} =
    b.emit(
      PubSubEvent(
        kind: PubSubEventKind.MessageValidated,
        peerId: $peer.peerId,
        topic: msg.topic,
        msgId: shortLog(msgId),
        data: msg.payloadBytes,
      )
    )

  proc onSend(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].} =
    for msg in msgs.messages:
      let msgId = peer.messageId(msg).valueOr:
        continue
      b.emit(
        PubSubEvent(
          kind: PubSubEventKind.MessageSent,
          peerId: $peer.peerId,
          topic: msg.topic,
          msgId: msgId,
          data: msg.payloadBytes,
        )
      )

  gossip.addObserver(
    PubSubObserver(onRecv: onRecv, onSend: onSend, onValidated: onValidated)
  )

proc new*(
    T: type GossipSubBackend,
    switch: Switch,
    codec: string,
    params: PubSubParams,
    maxMessageSize: int,
): Result[GossipSubBackend, string] =
  let gossip =
    try:
      GossipSub.init(
        switch = switch,
        anonymize = true,
        verifySignature = false,
        sign = false,
        triggerSelf = true,
        msgIdProvider = defaultMessageIdProvider,
        maxMessageSize = maxMessageSize,
        rng = switch.rng,
        parameters = params.toGossipSubParams(),
      )
    except InitializationError:
      return err("initialization error: " & getCurrentExceptionMsg())

  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    ## main protocol handler that gets triggered on every
    ## connection for a protocol string
    debug "Incoming relay connection", connection = conn, protocol = proto

    try:
      await gossip.handleConn(conn, proto)
    except CancelledError:
      # This is top-level procedure which will work as separate task, so it
      # do not need to propogate CancelledError.
      debug "Unexpected cancellation in relay handler",
        conn = conn, error = getCurrentExceptionMsg()
    except CatchableError:
      error "Relay handler leaks an error",
        conn = conn, error = getCurrentExceptionMsg()

  try:
    gossip.initPubSub()
  except InitializationError:
    return err("initialization error: " & getCurrentExceptionMsg())
  gossip.handler = handler
  gossip.codec = codec

  let b = GossipSubBackend(gossip: gossip, switch: switch)
  b.installObserver()
  return ok(b)

proc mountOn*(
    b: GossipSubBackend, switch: Switch, matcher: Matcher
) {.raises: [LPError].} =
  switch.mount(b.gossip, matcher)

proc start*(b: GossipSubBackend): Future[void] {.async: (raises: [CancelledError]).} =
  # The switch also starts mounted protocols: avoid GossipSub's start-twice warning.
  if not b.gossip.started:
    await b.gossip.start()

proc stop*(b: GossipSubBackend): Future[void] {.async: (raises: []).} =
  if b.gossip.started:
    await b.gossip.stop()

proc subscribe*(b: GossipSubBackend, topic: string, handler: PubSubHandler) =
  b.handlers[topic] = handler
  b.gossip.subscribe(topic, handler)

proc unsubscribe*(b: GossipSubBackend, topic: string) =
  var handler: TopicHandler
  try:
    handler = b.handlers[topic]
  except KeyError:
    return
  b.gossip.unsubscribe(topic, handler)
  b.handlers.del(topic)

proc unsubscribeAll*(b: GossipSubBackend, topic: string) =
  b.gossip.unsubscribeAll(topic)
  b.handlers.del(topic)

proc publish*(
    b: GossipSubBackend, topic: string, data: seq[byte]
): Future[int] {.async: (raises: [CancelledError]).} =
  return await b.gossip.publish(topic, data)

proc addValidator*(b: GossipSubBackend, topic: string, validator: PubSubValidator) =
  let wrapped = proc(
      topic: string, message: Message
  ): Future[ValidationResult] {.async.} =
    return (await validator(topic, message.payloadBytes)).toLibp2p()

  b.validators[topic] = wrapped
  b.gossip.addValidator(topic, wrapped)

proc removeValidator*(b: GossipSubBackend, topic: string) =
  var wrapped: ValidatorHandler
  try:
    wrapped = b.validators[topic]
  except KeyError:
    return
  b.gossip.removeValidator(topic, wrapped)
  b.validators.del(topic)

proc setTopicScoreParams*(
    b: GossipSubBackend, topic: string, params: TopicScoreParams
) =
  b.gossip.topicParams[topic] = params.toTopicParams()

proc topics*(b: GossipSubBackend): seq[string] =
  return toSeq(b.gossip.topics.keys())

proc meshPeers*(
    b: GossipSubBackend, topic: string
): Result[seq[PubSubPeerInfo], string] =
  ## Peers in the mesh of the topic; every mesh when the topic is empty.
  if topic == "":
    var allPeers = initHashSet[PubSubPeer]()
    for t, topicMesh in b.gossip.mesh.pairs:
      allPeers = allPeers.union(topicMesh)
    return ok(allPeers.toPeerInfos())

  if not b.gossip.mesh.hasKey(topic):
    debug "No mesh peer for the given pubsub topic", pubsubTopic = topic
    return ok(newSeq[PubSubPeerInfo]())

  let peers = catch:
    b.gossip.mesh[topic]
  if peers.isErr():
    return err("exception accessing " & topic & ": " & peers.error.msg)
  return ok(peers.get().toPeerInfos())

proc connectedPeers*(
    b: GossipSubBackend, topic: string
): Result[seq[PubSubPeerInfo], string] =
  ## Connected peers subscribed to the topic; every connected peer when empty.
  if topic == "":
    var allPeers = initHashSet[PubSubPeer]()
    for t, peers in b.gossip.gossipsub:
      allPeers = allPeers + peers
    return ok(allPeers.toPeerInfos())

  if not b.gossip.gossipsub.hasKey(topic):
    return err("there is no gossipsub peer for the given pubsub topic: " & topic)

  let peers = catch:
    b.gossip.gossipsub[topic]
  if peers.isErr():
    return err("exception accessing " & topic & ": " & peers.error.msg)
  return ok(peers.get().toPeerInfos())

func toOwned(p: GossipSubParams): PubSubParams =
  return PubSubParams(
    pruneBackoff: p.pruneBackoff,
    unsubscribeBackoff: p.unsubscribeBackoff,
    floodPublish: p.floodPublish,
    gossipFactor: p.gossipFactor,
    d: p.d,
    dLow: p.dLow,
    dHigh: p.dHigh,
    dScore: p.dScore,
    dOut: p.dOut,
    dLazy: p.dLazy,
    heartbeatInterval: p.heartbeatInterval,
    historyLength: p.historyLength,
    historyGossip: p.historyGossip,
    fanoutTTL: p.fanoutTTL,
    seenTTL: p.seenTTL,
    gossipThreshold: p.gossipThreshold,
    publishThreshold: p.publishThreshold,
    graylistThreshold: p.graylistThreshold,
    opportunisticGraftThreshold: p.opportunisticGraftThreshold,
    decayInterval: p.decayInterval,
    decayToZero: p.decayToZero,
    retainScore: p.retainScore,
    appSpecificWeight: p.appSpecificWeight,
    ipColocationFactorWeight: p.ipColocationFactorWeight,
    ipColocationFactorThreshold: p.ipColocationFactorThreshold,
    behaviourPenaltyWeight: p.behaviourPenaltyWeight,
    behaviourPenaltyDecay: p.behaviourPenaltyDecay,
    disconnectBadPeers: p.disconnectBadPeers,
  )

proc params*(b: GossipSubBackend): PubSubParams =
  ## The parameters GossipSub is running with now.
  return b.gossip.parameters.toOwned()

proc selfPeerId*(b: GossipSubBackend): PeerIdStr =
  return $b.switch.peerInfo.peerId

proc setEventHandler*(b: GossipSubBackend, handler: PubSubEventHandler) =
  b.eventHandler = handler

proc setTriggerSelf*(b: GossipSubBackend, value: bool) =
  b.gossip.triggerSelf = value

proc enablePeerExchange*(b: GossipSubBackend, handler: PubSubPeerExchangeHandler) =
  b.gossip.parameters.enablePX = true
  b.gossip.routingRecordsHandler.add(
    proc(
        peer: PeerId, topic: string, peers: seq[RoutingRecordsPair]
    ) {.gcsafe, raises: [].} =
      let pxPeers = peers.filterIt(it.record.isSome()).mapIt(
          PxPeer(peerId: $it.id, addrs: it.record.get().addresses.mapIt($it.address))
        )
      handler($peer, topic, pxPeers)
  )

static:
  doAssert GossipSubBackend is IPubSub
