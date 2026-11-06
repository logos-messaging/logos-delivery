## A reference implementation of the libp2p module contract, for tests: the
## module side of `libp2p_iface/module_contract`, served by the built-in
## nim-libp2p backend. It lives in-process, so its events are delivered straight
## to the node-side `ModuleTransport`.
{.push raises: [].}

import std/[tables, sequtils, strutils]
import results, chronos, chronicles
import libp2p/[switch, multiaddress, peerid]
import libp2p/stream/[connection, lpstream]
import libp2p/protocols/protocol
import
  logos_delivery/waku/libp2p_iface/[pubsub, module_contract],
  logos_delivery/waku/libp2p_backend/[gossipsub, host, module_transport]

type ReferenceModule* = ref object
  switch*: Switch
  host: Libp2pHost
  pubsub: GossipSubBackend
  transport*: ModuleTransport
  streams: Table[uint64, Connection]
  nextHandle: uint64
  verdicts: Table[uint64, Future[pubsub.ValidationResult]]
  nextVerdictId: uint64

func fromDto(p: PubSubParamsDto): PubSubParams =
  return PubSubParams(
    pruneBackoff: chronos.milliseconds(p.pruneBackoffMs),
    unsubscribeBackoff: chronos.milliseconds(p.unsubscribeBackoffMs),
    floodPublish: p.floodPublish,
    gossipFactor: p.gossipFactor,
    d: int(p.d),
    dLow: int(p.dLow),
    dHigh: int(p.dHigh),
    dScore: int(p.dScore),
    dOut: int(p.dOut),
    dLazy: int(p.dLazy),
    heartbeatInterval: chronos.milliseconds(p.heartbeatIntervalMs),
    historyLength: int(p.historyLength),
    historyGossip: int(p.historyGossip),
    fanoutTTL: chronos.milliseconds(p.fanoutTtlMs),
    seenTTL: chronos.milliseconds(p.seenTtlMs),
    gossipThreshold: p.gossipThreshold,
    publishThreshold: p.publishThreshold,
    graylistThreshold: p.graylistThreshold,
    opportunisticGraftThreshold: p.opportunisticGraftThreshold,
    decayInterval: chronos.milliseconds(p.decayIntervalMs),
    decayToZero: p.decayToZero,
    retainScore: chronos.milliseconds(p.retainScoreMs),
    appSpecificWeight: p.appSpecificWeight,
    ipColocationFactorWeight: p.ipColocationFactorWeight,
    ipColocationFactorThreshold: p.ipColocationFactorThreshold,
    behaviourPenaltyWeight: p.behaviourPenaltyWeight,
    behaviourPenaltyDecay: p.behaviourPenaltyDecay,
    disconnectBadPeers: p.disconnectBadPeers,
  )

func fromDto(p: TopicScoreParamsDto): TopicScoreParams =
  return TopicScoreParams(
    topicWeight: p.topicWeight,
    timeInMeshWeight: p.timeInMeshWeight,
    timeInMeshQuantum: chronos.milliseconds(p.timeInMeshQuantumMs),
    timeInMeshCap: p.timeInMeshCap,
    firstMessageDeliveriesWeight: p.firstMessageDeliveriesWeight,
    firstMessageDeliveriesDecay: p.firstMessageDeliveriesDecay,
    firstMessageDeliveriesCap: p.firstMessageDeliveriesCap,
    meshMessageDeliveriesWeight: p.meshMessageDeliveriesWeight,
    meshMessageDeliveriesDecay: p.meshMessageDeliveriesDecay,
    meshMessageDeliveriesThreshold: p.meshMessageDeliveriesThreshold,
    meshMessageDeliveriesCap: p.meshMessageDeliveriesCap,
    meshMessageDeliveriesActivation:
      chronos.milliseconds(p.meshMessageDeliveriesActivationMs),
    meshMessageDeliveriesWindow: chronos.milliseconds(p.meshMessageDeliveriesWindowMs),
    meshFailurePenaltyWeight: p.meshFailurePenaltyWeight,
    meshFailurePenaltyDecay: p.meshFailurePenaltyDecay,
    invalidMessageDeliveriesWeight: p.invalidMessageDeliveriesWeight,
    invalidMessageDeliveriesDecay: p.invalidMessageDeliveriesDecay,
  )

proc emit[T](m: ReferenceModule, event: string, payload: T) =
  m.transport.deliver(event, cborEncode(payload))

proc toPeers(peers: seq[PubSubPeerInfo]): PeersRes =
  return PeersRes(peers: peers.mapIt(PeerDto(peerId: it.peerId, score: it.score)))

proc storeStream(m: ReferenceModule, conn: Connection): uint64 =
  inc m.nextHandle
  m.streams[m.nextHandle] = conn
  return m.nextHandle

proc streamError(exc: ref CatchableError): string =
  if exc of MaxSizeError:
    return ErrStreamMaxSize & exc.msg
  if exc of LPStreamRemoteClosedError:
    return ErrStreamRemoteClosed & exc.msg
  return ErrStream & exc.msg

proc configure(
    m: ReferenceModule, req: PubSubConfigureReq
): Future[ModuleReply] {.async: (raises: [CancelledError]).} =
  let backend = GossipSubBackend.new(
    m.switch, req.codec, req.params.fromDto(), int(req.maxMessageSize)
  ).valueOr:
    return err(error)
  backend.setEventHandler(
    proc(event: PubSubEvent) {.gcsafe, raises: [].} =
      m.emit(
        EvPubSubObserved,
        PubSubObservedEv(
          kind: uint8(ord(event.kind)),
          peerId: event.peerId,
          topic: event.topic,
          msgId: event.msgId,
          data: event.data,
          subscriptionsChanged: event.subscriptionsChanged,
          meshTopics: event.meshTopics,
        ),
      )
  )
  m.pubsub = backend
  # a running switch only takes a protocol that is already started
  await backend.start()
  let codec = req.codec
  let matcher = proc(proto: string): bool {.gcsafe.} =
    proto.startsWith(codec)
  try:
    backend.mountOn(m.switch, matcher)
  except LPError as exc:
    return err(exc.msg)
  return ok(cborEncode(Empty()))

proc addValidator(m: ReferenceModule, topic: string) =
  m.pubsub.addValidator(
    topic,
    proc(topic: string, data: seq[byte]): Future[pubsub.ValidationResult] {.async.} =
      inc m.nextVerdictId
      let id = m.nextVerdictId
      let fut = newFuture[pubsub.ValidationResult]("referenceValidation")
      m.verdicts[id] = fut
      m.emit(
        EvPubSubValidate, PubSubValidateEv(requestId: id, topic: topic, data: data)
      )
      # a node that gives no verdict in time leaves the message ignored
      let answered = await fut.withTimeout(chronos.milliseconds(ValidationDeadlineMs))
      m.verdicts.del(id)
      if answered:
        return fut.read()
      return pubsub.ValidationResult.Ignore,
  )

proc handleRequest(
    m: ReferenceModule, meth: string, request: seq[byte]
): Future[ModuleReply] {.async: (raises: [CancelledError]).} =
  template decode(T: typedesc): untyped =
    cborDecode(request, T).valueOr:
      return err("invalid request: " & error)

  let empty = ok(cborEncode(Empty()))
  case meth
  of ReqPubSubConfigure:
    return await m.configure(decode(PubSubConfigureReq))
  of ReqPubSubStart:
    await m.pubsub.start()
    return empty
  of ReqPubSubStop:
    await m.pubsub.stop()
    return empty
  of ReqPubSubSubscribe:
    let req = decode(TopicReq)
    m.pubsub.subscribe(
      req.topic,
      proc(topic: string, data: seq[byte]): Future[void] {.gcsafe, raises: [].} =
        m.emit(EvPubSubMessage, PubSubMessageEv(topic: topic, data: data))
        let fut = newFuture[void]()
        fut.complete()
        return fut,
    )
    return empty
  of ReqPubSubUnsubscribe:
    m.pubsub.unsubscribe(decode(TopicReq).topic)
    return empty
  of ReqPubSubUnsubscribeAll:
    m.pubsub.unsubscribeAll(decode(TopicReq).topic)
    return empty
  of ReqPubSubPublish:
    let req = decode(PublishReq)
    let relayed = await m.pubsub.publish(req.topic, req.data)
    return ok(cborEncode(PublishRes(relayed: int64(relayed))))
  of ReqPubSubAddValidator:
    m.addValidator(decode(TopicReq).topic)
    return empty
  of ReqPubSubRemoveValidator:
    m.pubsub.removeValidator(decode(TopicReq).topic)
    return empty
  of ReqPubSubVerdict:
    let req = decode(VerdictReq)
    let fut = m.verdicts.getOrDefault(req.requestId)
    if not fut.isNil() and not fut.finished():
      fut.complete(
        case req.verdict
        of 0: pubsub.ValidationResult.Accept
        of 1: pubsub.ValidationResult.Reject
        else: pubsub.ValidationResult.Ignore
      )
    return empty
  of ReqPubSubTopicScore:
    let req = decode(TopicScoreReq)
    m.pubsub.setTopicScoreParams(req.topic, req.params.fromDto())
    return empty
  of ReqPubSubTopics:
    return ok(cborEncode(TopicsRes(topics: m.pubsub.topics())))
  of ReqPubSubMeshPeers:
    let peers = m.pubsub.meshPeers(decode(PeersReq).topic).valueOr:
      return err(error)
    return ok(cborEncode(peers.toPeers()))
  of ReqPubSubConnectedPeers:
    let peers = m.pubsub.connectedPeers(decode(PeersReq).topic).valueOr:
      return err(error)
    return ok(cborEncode(peers.toPeers()))
  of ReqPubSubSelfPeerId:
    return ok(cborEncode(PeerIdRes(peerId: m.pubsub.selfPeerId())))
  of ReqPubSubTriggerSelf:
    m.pubsub.setTriggerSelf(decode(TriggerSelfReq).value)
    return empty
  of ReqPubSubEnablePx:
    m.pubsub.enablePeerExchange(
      proc(
          fromPeer: PeerIdStr, topic: string, peers: seq[PxPeer]
      ) {.gcsafe, raises: [].} =
        m.emit(
          EvPubSubPeerExchange,
          PubSubPeerExchangeEv(
            fromPeer: fromPeer,
            topic: topic,
            peers: peers.mapIt(PxPeerDto(peerId: it.peerId, addrs: it.addrs)),
          ),
        )
    )
    return empty
  of ReqHostIdentity:
    return ok(
      cborEncode(
        HostIdentityRes(
          peerId: $m.host.peerId(),
          listenAddrs: m.host.listenAddrs().mapIt($it),
          announcedAddrs: m.host.announcedAddrs().mapIt($it),
        )
      )
    )
  of ReqHostStart:
    # the test owns the switch lifecycle
    return empty
  of ReqHostStop:
    return empty
  of ReqHostDisconnect:
    let peerId = PeerId.init(decode(PeerReq).peerId).valueOr:
      return err("invalid peer id")
    await m.host.disconnect(peerId)
    return empty
  of ReqHostConnections:
    return ok(
      cborEncode(
        ConnectionsRes(
          connections: m.host.connections().mapIt(
              ConnectionDto(
                peerId: $it.peerId,
                inbound: it.inbound,
                observedAddr:
                  if it.observedAddr.isSome():
                    $it.observedAddr.get()
                  else:
                    "",
                streams: it.streams.mapIt(
                  StreamDto(protocol: it.protocol, inbound: it.inbound)
                ),
              )
            )
        )
      )
    )
  of ReqHostIsConnected:
    let peerId = PeerId.init(decode(PeerReq).peerId).valueOr:
      return err("invalid peer id")
    return ok(cborEncode(IsConnectedRes(connected: m.host.isConnected(peerId))))
  of ReqHostDial:
    let req = decode(DialReq)
    let peerId = PeerId.init(req.peerId).valueOr:
      return err("invalid peer id")
    let addrs =
      req.addrs.mapIt(MultiAddress.init(it)).filterIt(it.isOk()).mapIt(it.get())
    try:
      let conn = await m.host.dial(peerId, addrs, req.codec)
      return ok(cborEncode(DialRes(handle: m.storeStream(conn))))
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      return err(exc.msg)
  of ReqHostMount:
    let codec = decode(MountReq).codec
    let handler = proc(
        conn: Connection, proto: string
    ) {.async: (raises: [CancelledError]).} =
      let handle = m.storeStream(conn)
      m.emit(
        EvHostStream, HostStreamEv(handle: handle, peerId: $conn.peerId, codec: codec)
      )
      # the stream lives until the node side closes it
      while m.streams.hasKey(handle) and not conn.closed:
        await sleepAsync(chronos.milliseconds(20))
    try:
      m.host.mount(codec, handler)
    except LPError as exc:
      return err(exc.msg)
    return empty
  of ReqStreamWriteLp:
    let req = decode(StreamWriteReq)
    let conn = m.streams.getOrDefault(req.handle)
    if conn.isNil():
      return err(ErrStream & "unknown stream")
    try:
      await conn.writeLP(req.data)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      return err(streamError(exc))
    return empty
  of ReqStreamReadLp:
    let req = decode(StreamReadReq)
    let conn = m.streams.getOrDefault(req.handle)
    if conn.isNil():
      return err(ErrStream & "unknown stream")
    try:
      return ok(cborEncode(StreamReadRes(data: await conn.readLp(int(req.maxSize)))))
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      return err(streamError(exc))
  of ReqStreamClose, ReqStreamCloseWithEof:
    let req = decode(StreamReq)
    let conn = m.streams.getOrDefault(req.handle)
    if not conn.isNil():
      m.streams.del(req.handle)
      if meth == ReqStreamCloseWithEof:
        await conn.closeWithEOF()
      else:
        await conn.close()
    return empty
  else:
    return err("unknown method: " & meth)

proc new*(T: type ReferenceModule, switch: Switch): ReferenceModule =
  let m = ReferenceModule(
    switch: switch,
    host: Libp2pHost.new(switch),
    streams: initTable[uint64, Connection](),
  )
  let callFn = proc(
      meth: string, request: seq[byte]
  ): Future[ModuleReply] {.async: (raises: [CancelledError]).} =
    return await m.handleRequest(meth, request)

  m.transport = ModuleTransport.new(callFn)
  return m
