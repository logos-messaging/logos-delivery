## Waku Filter client for subscribing and receiving filtered messages

{.push raises: [].}

import
  std/options,
  chronicles,
  chronos,
  libp2p/protocols/protocol,
  bearssl/rand,
  stew/byteutils
import
  waku/[node/peer_manager, waku_core, events/delivery_events],
  ./common,
  ./protocol_metrics,
  ./rpc_codec,
  ./rpc

logScope:
  topics = "waku filter client"

type WakuFilterClient* = ref object of LPProtocol
  rng: ref HmacDrbgContext
  peerManager: PeerManager
  pushHandlers: seq[FilterPushHandler]

func generateRequestId(rng: ref HmacDrbgContext): string =
  var bytes: array[10, byte]
  hmacDrbgGenerate(rng[], bytes)
  return toHex(bytes)

proc sendSubscribeRequest(
    wfc: WakuFilterClient,
    servicePeer: RemotePeerInfo,
    filterSubscribeRequest: FilterSubscribeRequest,
): Future[FilterSubscribeResult] {.async: (raises: []).} =
  trace "Sending filter subscribe request",
    peerId = servicePeer.peerId, filterSubscribeRequest

  var connOpt: Option[Connection]
  try:
    connOpt = await wfc.peerManager.dialPeer(servicePeer, WakuFilterSubscribeCodec)
    if connOpt.isNone():
      trace "Failed to dial filter service peer", servicePeer
      waku_filter_errors.inc(labelValues = [dialFailure])
      return err(FilterSubscribeError.peerDialFailure($servicePeer))
  except CatchableError:
    let errMsg = "failed to dialPeer: " & getCurrentExceptionMsg()
    trace "failed to dialPeer", error = getCurrentExceptionMsg()
    waku_filter_errors.inc(labelValues = [errMsg])
    return err(FilterSubscribeError.badResponse(errMsg))

  let connection = connOpt.get()

  defer:
    await connection.closeWithEOF()

  try:
    await connection.writeLP(filterSubscribeRequest.encode().buffer)
  except CatchableError:
    let errMsg =
      "exception in waku_filter_v2 client writeLP: " & getCurrentExceptionMsg()
    trace "exception in waku_filter_v2 client writeLP", error = getCurrentExceptionMsg()
    waku_filter_errors.inc(labelValues = [errMsg])
    return err(FilterSubscribeError.badResponse(errMsg))

  var respBuf: seq[byte]
  try:
    respBuf = await connection.readLp(DefaultMaxSubscribeResponseSize)
  except CatchableError:
    let errMsg =
      "exception in waku_filter_v2 client readLp: " & getCurrentExceptionMsg()
    trace "exception in waku_filter_v2 client readLp", error = getCurrentExceptionMsg()
    waku_filter_errors.inc(labelValues = [errMsg])
    return err(FilterSubscribeError.badResponse(errMsg))

  let response = FilterSubscribeResponse.decode(respBuf).valueOr:
    trace "Failed to decode filter subscribe response", servicePeer
    waku_filter_errors.inc(labelValues = [decodeRpcFailure])
    return err(FilterSubscribeError.badResponse(decodeRpcFailure))

  # DOS protection rate limit checks does not know about request id
  if response.statusCode != FilterSubscribeErrorKind.TOO_MANY_REQUESTS.uint32 and
      response.requestId != filterSubscribeRequest.requestId:
    trace "Filter subscribe response requestId mismatch", servicePeer, response
    waku_filter_errors.inc(labelValues = [requestIdMismatch])
    return err(FilterSubscribeError.badResponse(requestIdMismatch))

  if response.statusCode != 200:
    trace "Filter subscribe error response", servicePeer, response
    waku_filter_errors.inc(labelValues = [errorResponse])
    let cause =
      if response.statusDesc.isSome():
        response.statusDesc.get()
      else:
        "filter subscribe error"
    return err(FilterSubscribeError.parse(response.statusCode, cause = cause))

  return ok()

proc ping*(
    wfc: WakuFilterClient, servicePeer: RemotePeerInfo
): Future[FilterSubscribeResult] {.async.} =
  info "sending ping", servicePeer = shortLog($servicePeer)
  let requestId = generateRequestId(wfc.rng)
  let filterSubscribeRequest = FilterSubscribeRequest.ping(requestId)

  return await wfc.sendSubscribeRequest(servicePeer, filterSubscribeRequest)

proc subscribe*(
    wfc: WakuFilterClient,
    servicePeer: RemotePeerInfo,
    pubsubTopic: PubsubTopic,
    contentTopics: ContentTopic | seq[ContentTopic],
): Future[FilterSubscribeResult] {.async: (raises: []).} =
  var contentTopicSeq: seq[ContentTopic]
  when contentTopics is seq[ContentTopic]:
    contentTopicSeq = contentTopics
  else:
    contentTopicSeq = @[contentTopics]

  let requestId = generateRequestId(wfc.rng)
  let filterSubscribeRequest = FilterSubscribeRequest.subscribe(
    requestId = requestId, pubsubTopic = pubsubTopic, contentTopics = contentTopicSeq
  )

  ?await wfc.sendSubscribeRequest(servicePeer, filterSubscribeRequest)

  OnFilterSubscribeEvent.emit(pubSubTopic, contentTopicSeq)

  return ok()

proc unsubscribe*(
    wfc: WakuFilterClient,
    servicePeer: RemotePeerInfo,
    pubsubTopic: PubsubTopic,
    contentTopics: ContentTopic | seq[ContentTopic],
): Future[FilterSubscribeResult] {.async: (raises: []).} =
  var contentTopicSeq: seq[ContentTopic]
  when contentTopics is seq[ContentTopic]:
    contentTopicSeq = contentTopics
  else:
    contentTopicSeq = @[contentTopics]

  let requestId = generateRequestId(wfc.rng)
  let filterSubscribeRequest = FilterSubscribeRequest.unsubscribe(
    requestId = requestId, pubsubTopic = pubsubTopic, contentTopics = contentTopicSeq
  )

  ?await wfc.sendSubscribeRequest(servicePeer, filterSubscribeRequest)

  OnFilterUnSubscribeEvent.emit(pubSubTopic, contentTopicSeq)

  return ok()

proc unsubscribeAll*(
    wfc: WakuFilterClient, servicePeer: RemotePeerInfo
): Future[FilterSubscribeResult] {.async: (raises: []).} =
  let requestId = generateRequestId(wfc.rng)
  let filterSubscribeRequest =
    FilterSubscribeRequest.unsubscribeAll(requestId = requestId)

  return await wfc.sendSubscribeRequest(servicePeer, filterSubscribeRequest)

proc registerPushHandler*(wfc: WakuFilterClient, handler: FilterPushHandler) =
  wfc.pushHandlers.add(handler)

proc initProtocolHandler(wfc: WakuFilterClient) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    ## Notice that the client component is acting as a server of WakuFilterPushCodec messages
    while not conn.atEof():
      var buf: seq[byte]
      try:
        buf = await conn.readLp(int(DefaultMaxPushSize))
      except CancelledError, LPStreamError:
        error "error while reading conn", error = getCurrentExceptionMsg()

      let msgPush = MessagePush.decode(buf).valueOr:
        error "Failed to decode message push", peerId = conn.peerId, error = $error
        waku_filter_errors.inc(labelValues = [decodeRpcFailure])
        return

      let msg_hash =
        computeMessageHash(msgPush.pubsubTopic, msgPush.wakuMessage).to0xHex()

      info "Received message push",
        peerId = conn.peerId,
        msg_hash,
        payload = shortLog(msgPush.wakuMessage.payload),
        pubsubTopic = msgPush.pubsubTopic,
        content_topic = msgPush.wakuMessage.contentTopic,
        conn

      for handler in wfc.pushHandlers:
        asyncSpawn handler(msgPush.pubsubTopic, msgPush.wakuMessage)

      # Protocol specifies no response for now

  wfc.handler = handler
  wfc.codec = WakuFilterPushCodec

proc new*(
    T: type WakuFilterClient, peerManager: PeerManager, rng: ref HmacDrbgContext
): T =
  let wfc = WakuFilterClient(rng: rng, peerManager: peerManager, pushHandlers: @[])
  wfc.initProtocolHandler()
  wfc
