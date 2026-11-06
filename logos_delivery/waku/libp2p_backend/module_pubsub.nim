## `IPubSub` implementation backed by an external libp2p Logos module, reached
## through `ModuleTransport` (see `libp2p_iface/module_contract`).
##
## The interface has synchronous verbs where the module call is asynchronous:
## - verbs without a result (subscribe, add a validator, ...) are applied to the
##   module in call order, by one worker, and a failure is logged;
## - peer queries answer from a snapshot that is refreshed on every topology
##   event and once a second.
{.push raises: [].}

import std/[tables, sets, sequtils, options]
import chronos, chronicles, results
import ../libp2p_iface/pubsub
import ./module_transport

logScope:
  topics = "waku module pubsub"

const PeerRefreshInterval = chronos.seconds(1)

type
  PubSubOp = proc(): Future[void].Raising([]) {.gcsafe, raises: [].}

  ModulePubSub* = ref object
    t: ModuleTransport
    codec: string
    maxMessageSize: int
    paramsValue: PubSubParams
    selfId: PeerIdStr
    handlers: Table[string, PubSubHandler]
    validators: Table[string, PubSubValidator]
    subscribed: HashSet[string]
    eventHandler: PubSubEventHandler
    pxHandler: PubSubPeerExchangeHandler
    ops: AsyncQueue[PubSubOp]
    opsLoop: Future[void]
    refreshLoop: Future[void]
    meshSnapshot: Table[string, seq[PubSubPeerInfo]]
    connectedSnapshot: Table[string, seq[PubSubPeerInfo]]
    peersDirty: bool

func ms(d: Duration): int64 =
  return d.milliseconds

func toDto(p: PubSubParams): PubSubParamsDto =
  return PubSubParamsDto(
    pruneBackoffMs: p.pruneBackoff.ms,
    unsubscribeBackoffMs: p.unsubscribeBackoff.ms,
    floodPublish: p.floodPublish,
    gossipFactor: p.gossipFactor,
    d: p.d,
    dLow: p.dLow,
    dHigh: p.dHigh,
    dScore: p.dScore,
    dOut: p.dOut,
    dLazy: p.dLazy,
    heartbeatIntervalMs: p.heartbeatInterval.ms,
    historyLength: p.historyLength,
    historyGossip: p.historyGossip,
    fanoutTtlMs: p.fanoutTTL.ms,
    seenTtlMs: p.seenTTL.ms,
    gossipThreshold: p.gossipThreshold,
    publishThreshold: p.publishThreshold,
    graylistThreshold: p.graylistThreshold,
    opportunisticGraftThreshold: p.opportunisticGraftThreshold,
    decayIntervalMs: p.decayInterval.ms,
    decayToZero: p.decayToZero,
    retainScoreMs: p.retainScore.ms,
    appSpecificWeight: p.appSpecificWeight,
    ipColocationFactorWeight: p.ipColocationFactorWeight,
    ipColocationFactorThreshold: p.ipColocationFactorThreshold,
    behaviourPenaltyWeight: p.behaviourPenaltyWeight,
    behaviourPenaltyDecay: p.behaviourPenaltyDecay,
    disconnectBadPeers: p.disconnectBadPeers,
  )

func toDto(p: TopicScoreParams): TopicScoreParamsDto =
  return TopicScoreParamsDto(
    topicWeight: p.topicWeight,
    timeInMeshWeight: p.timeInMeshWeight,
    timeInMeshQuantumMs: p.timeInMeshQuantum.ms,
    timeInMeshCap: p.timeInMeshCap,
    firstMessageDeliveriesWeight: p.firstMessageDeliveriesWeight,
    firstMessageDeliveriesDecay: p.firstMessageDeliveriesDecay,
    firstMessageDeliveriesCap: p.firstMessageDeliveriesCap,
    meshMessageDeliveriesWeight: p.meshMessageDeliveriesWeight,
    meshMessageDeliveriesDecay: p.meshMessageDeliveriesDecay,
    meshMessageDeliveriesThreshold: p.meshMessageDeliveriesThreshold,
    meshMessageDeliveriesCap: p.meshMessageDeliveriesCap,
    meshMessageDeliveriesActivationMs: p.meshMessageDeliveriesActivation.ms,
    meshMessageDeliveriesWindowMs: p.meshMessageDeliveriesWindow.ms,
    meshFailurePenaltyWeight: p.meshFailurePenaltyWeight,
    meshFailurePenaltyDecay: p.meshFailurePenaltyDecay,
    invalidMessageDeliveriesWeight: p.invalidMessageDeliveriesWeight,
    invalidMessageDeliveriesDecay: p.invalidMessageDeliveriesDecay,
  )

func toVerdict(r: ValidationResult): uint8 =
  case r
  of ValidationResult.Accept: 0'u8
  of ValidationResult.Reject: 1'u8
  of ValidationResult.Ignore: 2'u8

proc enqueue(m: ModulePubSub, op: PubSubOp) =
  try:
    m.ops.addLastNoWait(op)
  except AsyncQueueFullError:
    error "libp2p module operation queue full"

proc request[Req](m: ModulePubSub, meth: string, req: Req): PubSubOp =
  ## An op that sends `req` and logs a failed answer.
  return proc(): Future[void] {.async: (raises: []).} =
    try:
      (await m.t.call(meth, req, Empty)).isOkOr:
        warn "libp2p module request failed", error = error
    except CancelledError:
      discard

proc runOps(m: ModulePubSub) {.async: (raises: []).} =
  while true:
    let op =
      try:
        await m.ops.popFirst()
      except CancelledError:
        return
    await op()

proc refreshPeers(m: ModulePubSub) {.async: (raises: [CancelledError]).} =
  m.peersDirty = false
  for topic in toSeq(m.subscribed) & @[""]:
    let mesh = await m.t.call(ReqPubSubMeshPeers, PeersReq(topic: topic), PeersRes)
    if mesh.isOk():
      m.meshSnapshot[topic] =
        mesh.get().peers.mapIt(PubSubPeerInfo(peerId: it.peerId, score: it.score))
    let connected =
      await m.t.call(ReqPubSubConnectedPeers, PeersReq(topic: topic), PeersRes)
    if connected.isOk():
      m.connectedSnapshot[topic] =
        connected.get().peers.mapIt(PubSubPeerInfo(peerId: it.peerId, score: it.score))

proc runRefresh(m: ModulePubSub) {.async: (raises: []).} =
  while true:
    try:
      await sleepAsync(PeerRefreshInterval)
      await m.refreshPeers()
    except CancelledError:
      return

proc validate(m: ModulePubSub, ev: PubSubValidateEv) {.async: (raises: []).} =
  let validator = m.validators.getOrDefault(ev.topic)
  var verdict = ValidationResult.Ignore
  if validator.isNil():
    verdict = ValidationResult.Accept
  else:
    try:
      let fut = validator(ev.topic, ev.data)
      if await fut.withTimeout(chronos.milliseconds(ValidationDeadlineMs)):
        verdict = fut.read()
      else:
        debug "validation deadline exceeded, ignoring the message", topic = ev.topic
    except CancelledError:
      return
    except CatchableError as exc:
      error "validator failed", error = exc.msg

  try:
    (
      await m.t.call(
        ReqPubSubVerdict,
        VerdictReq(requestId: ev.requestId, verdict: verdict.toVerdict()),
        Empty,
      )
    ).isOkOr:
      warn "failed to send the validation verdict", error = error
  except CancelledError:
    discard

proc onMessage(m: ModulePubSub, payload: seq[byte]) =
  let ev = cborDecode(payload, PubSubMessageEv).valueOr:
    debug "invalid pubsub message event", error = error
    return
  let handler = m.handlers.getOrDefault(ev.topic)
  if not handler.isNil():
    asyncSpawn handler(ev.topic, ev.data)

proc onValidate(m: ModulePubSub, payload: seq[byte]) =
  let ev = cborDecode(payload, PubSubValidateEv).valueOr:
    debug "invalid pubsub validate event", error = error
    return
  asyncSpawn m.validate(ev)

proc onObserved(m: ModulePubSub, payload: seq[byte]) =
  let ev = cborDecode(payload, PubSubObservedEv).valueOr:
    debug "invalid pubsub observed event", error = error
    return
  let kind =
    case ev.kind
    of 0: PubSubEventKind.MessageReceived
    of 1: PubSubEventKind.MessageValidated
    of 2: PubSubEventKind.MessageSent
    else: PubSubEventKind.TopologyChanged
  if kind == PubSubEventKind.TopologyChanged:
    m.peersDirty = true
  if not m.eventHandler.isNil():
    m.eventHandler(
      PubSubEvent(
        kind: kind,
        peerId: ev.peerId,
        topic: ev.topic,
        msgId: ev.msgId,
        data: ev.data,
        subscriptionsChanged: ev.subscriptionsChanged,
        meshTopics: ev.meshTopics,
      )
    )

proc onPeerExchange(m: ModulePubSub, payload: seq[byte]) =
  let ev = cborDecode(payload, PubSubPeerExchangeEv).valueOr:
    debug "invalid pubsub peer exchange event", error = error
    return
  if not m.pxHandler.isNil():
    m.pxHandler(
      ev.fromPeer, ev.topic, ev.peers.mapIt(PxPeer(peerId: it.peerId, addrs: it.addrs))
    )

proc installEventHandlers(m: ModulePubSub) =
  let onMsg = proc(payload: seq[byte]) {.gcsafe, raises: [].} =
    m.onMessage(payload)
  let onVal = proc(payload: seq[byte]) {.gcsafe, raises: [].} =
    m.onValidate(payload)
  let onObs = proc(payload: seq[byte]) {.gcsafe, raises: [].} =
    m.onObserved(payload)
  let onPx = proc(payload: seq[byte]) {.gcsafe, raises: [].} =
    m.onPeerExchange(payload)
  m.t.subscribe(EvPubSubMessage, onMsg)
  m.t.subscribe(EvPubSubValidate, onVal)
  m.t.subscribe(EvPubSubObserved, onObs)
  m.t.subscribe(EvPubSubPeerExchange, onPx)

proc new*(
    T: type ModulePubSub,
    transport: ModuleTransport,
    codec: string,
    params: PubSubParams,
    maxMessageSize: int,
): ModulePubSub =
  let m = ModulePubSub(
    t: transport,
    codec: codec,
    maxMessageSize: maxMessageSize,
    paramsValue: params,
    ops: newAsyncQueue[PubSubOp](),
  )
  m.installEventHandlers()
  return m

proc start*(m: ModulePubSub): Future[void] {.async: (raises: [CancelledError]).} =
  if not m.opsLoop.isNil():
    return

  (
    await m.t.call(
      ReqPubSubConfigure,
      PubSubConfigureReq(
        codec: m.codec,
        maxMessageSize: int64(m.maxMessageSize),
        params: m.paramsValue.toDto(),
      ),
      Empty,
    )
  ).isOkOr:
    error "failed to configure the libp2p module pubsub", error = error
  (await m.t.call(ReqPubSubStart, Empty(), Empty)).isOkOr:
    error "failed to start the libp2p module pubsub", error = error
  let id = (await m.t.call(ReqPubSubSelfPeerId, Empty(), PeerIdRes)).valueOr:
    error "failed to get the libp2p module peer id", error = error
    PeerIdRes()
  m.selfId = id.peerId

  m.opsLoop = m.runOps()
  m.refreshLoop = m.runRefresh()

proc stop*(m: ModulePubSub): Future[void] {.async: (raises: []).} =
  if m.opsLoop.isNil():
    return
  await m.opsLoop.cancelAndWait()
  await m.refreshLoop.cancelAndWait()
  m.opsLoop = nil
  m.refreshLoop = nil
  try:
    (await m.t.call(ReqPubSubStop, Empty(), Empty)).isOkOr:
      warn "failed to stop the libp2p module pubsub", error = error
  except CancelledError:
    discard

proc subscribe*(m: ModulePubSub, topic: string, handler: PubSubHandler) =
  m.handlers[topic] = handler
  m.subscribed.incl(topic)
  m.peersDirty = true
  m.enqueue(request(m, ReqPubSubSubscribe, TopicReq(topic: topic)))

proc unsubscribe*(m: ModulePubSub, topic: string) =
  m.handlers.del(topic)
  m.subscribed.excl(topic)
  m.meshSnapshot.del(topic)
  m.connectedSnapshot.del(topic)
  m.enqueue(request(m, ReqPubSubUnsubscribe, TopicReq(topic: topic)))

proc unsubscribeAll*(m: ModulePubSub, topic: string) =
  m.handlers.del(topic)
  m.subscribed.excl(topic)
  m.meshSnapshot.del(topic)
  m.connectedSnapshot.del(topic)
  m.enqueue(request(m, ReqPubSubUnsubscribeAll, TopicReq(topic: topic)))

proc publish*(
    m: ModulePubSub, topic: string, data: seq[byte]
): Future[int] {.async: (raises: [CancelledError]).} =
  let res = (
    await m.t.call(ReqPubSubPublish, PublishReq(topic: topic, data: data), PublishRes)
  ).valueOr:
    debug "publish through the libp2p module failed", error = error
    return 0
  return int(res.relayed)

proc addValidator*(m: ModulePubSub, topic: string, validator: PubSubValidator) =
  m.validators[topic] = validator
  m.enqueue(request(m, ReqPubSubAddValidator, TopicReq(topic: topic)))

proc removeValidator*(m: ModulePubSub, topic: string) =
  m.validators.del(topic)
  m.enqueue(request(m, ReqPubSubRemoveValidator, TopicReq(topic: topic)))

proc setTopicScoreParams*(m: ModulePubSub, topic: string, params: TopicScoreParams) =
  m.enqueue(
    request(m, ReqPubSubTopicScore, TopicScoreReq(topic: topic, params: params.toDto()))
  )

proc topics*(m: ModulePubSub): seq[string] =
  return toSeq(m.subscribed)

proc meshPeers*(m: ModulePubSub, topic: string): Result[seq[PubSubPeerInfo], string] =
  return ok(m.meshSnapshot.getOrDefault(topic))

proc connectedPeers*(
    m: ModulePubSub, topic: string
): Result[seq[PubSubPeerInfo], string] =
  if topic != "" and topic notin m.connectedSnapshot:
    return err("there is no gossipsub peer for the given pubsub topic: " & topic)
  return ok(m.connectedSnapshot.getOrDefault(topic))

proc params*(m: ModulePubSub): PubSubParams =
  return m.paramsValue

proc selfPeerId*(m: ModulePubSub): PeerIdStr =
  return m.selfId

proc setEventHandler*(m: ModulePubSub, handler: PubSubEventHandler) =
  m.eventHandler = handler

proc setTriggerSelf*(m: ModulePubSub, value: bool) =
  m.enqueue(request(m, ReqPubSubTriggerSelf, TriggerSelfReq(value: value)))

proc enablePeerExchange*(m: ModulePubSub, handler: PubSubPeerExchangeHandler) =
  m.pxHandler = handler
  m.enqueue(request(m, ReqPubSubEnablePx, Empty()))

static:
  doAssert ModulePubSub is IPubSub
