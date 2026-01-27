{.push raises: [].}

import
  std/[options, strutils],
  results,
  stew/byteutils,
  chronicles,
  chronos,
  metrics,
  bearssl/rand
import
  ../node/peer_manager/peer_manager,
  ../waku_core,
  ../waku_core/topics/sharding,
  ./common,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics,
  ../common/rate_limit/request_limiter

logScope:
  topics = "waku lightpush"

type WakuLightPush* = ref object of LPProtocol
  rng*: ref rand.HmacDrbgContext
  peerManager*: PeerManager
  pushHandler*: PushMessageHandler
  requestRateLimiter*: RequestRateLimiter
  autoSharding: Option[Sharding]

proc handleRequest(
    wl: WakuLightPush, peerId: PeerId, pushRequest: LightpushRequest
): Future[WakuLightPushResult] {.async.} =
  let pubsubTopic = pushRequest.pubSubTopic.valueOr:
    if wl.autoSharding.isNone():
      let msg = "Pubsub topic must be specified when static sharding is enabled"
      error "lightpush request handling error", error = msg
      return WakuLightPushResult.err(
        (code: LightPushErrorCode.INVALID_MESSAGE, desc: some(msg))
      )

    let parsedTopic = NsContentTopic.parse(pushRequest.message.contentTopic).valueOr:
      let msg = "Invalid content-topic:" & $error
      error "lightpush request handling error", error = msg
      return WakuLightPushResult.err(
        (code: LightPushErrorCode.INVALID_MESSAGE, desc: some(msg))
      )

    wl.autoSharding.get().getShard(parsedTopic).valueOr:
      let msg = "Auto-sharding error: " & error
      error "lightpush request handling error", error = msg
      return WakuLightPushResult.err(
        (code: LightPushErrorCode.INTERNAL_SERVER_ERROR, desc: some(msg))
      )

  # ensure checking topic will not cause error at gossipsub level
  if pubsubTopic.isEmptyOrWhitespace():
    let msg = "topic must not be empty"
    error "lightpush request handling error", error = msg
    return
      WakuLightPushResult.err((code: LightPushErrorCode.BAD_REQUEST, desc: some(msg)))

  waku_lightpush_v3_messages.inc(labelValues = ["PushRequest"])

  let msg_hash = pubsubTopic.computeMessageHash(pushRequest.message).to0xHex()
  notice "handling lightpush request",
    my_peer_id = wl.peerManager.switch.peerInfo.peerId,
    peer_id = peerId,
    requestId = pushRequest.requestId,
    pubsubTopic = pushRequest.pubsubTopic,
    msg_hash = msg_hash,
    receivedTime = getNowInNanosecondTime()

  let res = (await wl.pushHandler(pubsubTopic, pushRequest.message)).valueOr:
    return err((code: error.code, desc: error.desc))
  return ok(res)

proc handleRequest*(
    wl: WakuLightPush, peerId: PeerId, buffer: seq[byte]
): Future[LightPushResponse] {.async.} =
  let request = LightPushRequest.decode(buffer).valueOr:
    let desc = decodeRpcFailure & ": " & $error
    error "failed to decode Lightpush request", error = desc
    let errorCode = LightPushErrorCode.BAD_REQUEST
    waku_lightpush_v3_errors.inc(labelValues = [$errorCode])
    return LightPushResponse(
      requestId: "N/A", # due to decode failure we don't know requestId
      statusCode: errorCode,
      statusDesc: some(desc),
    )

  let relayPeerCount = (await wl.handleRequest(peerId, request)).valueOr:
    let desc = error.desc
    waku_lightpush_v3_errors.inc(labelValues = [$error.code])
    error "failed to push message", error = desc
    return LightPushResponse(
      requestId: request.requestId, statusCode: error.code, statusDesc: desc
    )

  return LightPushResponse(
    requestId: request.requestId,
    statusCode: LightPushSuccessCode.SUCCESS,
    statusDesc: none[string](),
    relayPeerCount: some(relayPeerCount),
  )

proc initProtocolHandler(wl: WakuLightPush) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var rpc: LightPushResponse
    defer:
      await conn.closeWithEOF()

    wl.requestRateLimiter.checkUsageLimit(WakuLightPushCodec, conn):
      var buffer: seq[byte]
      try:
        buffer = await conn.readLp(DefaultMaxRpcSize)
      except LPStreamError:
        error "lightpush read stream failed", error = getCurrentExceptionMsg()
        return

      waku_service_network_bytes.inc(
        amount = buffer.len().int64, labelValues = [WakuLightPushCodec, "in"]
      )

      try:
        rpc = await wl.handleRequest(conn.peerId, buffer)
      except CatchableError:
        error "lightpush failed handleRequest", error = getCurrentExceptionMsg()
    do:
      info "lightpush request rejected due rate limit exceeded",
        peerId = conn.peerId, limit = $wl.requestRateLimiter.setting

      rpc = static(
        LightPushResponse(
          ## We will not copy and decode RPC buffer from stream only for requestId
          ## in reject case as it is comparably too expensive and opens possible
          ## attack surface
          requestId: "N/A",
          statusCode: LightPushErrorCode.TOO_MANY_REQUESTS,
          statusDesc: some(TooManyRequestsMessage),
        )
      )

    try:
      await conn.writeLp(rpc.encode().buffer)
    except LPStreamError:
      error "lightpush write stream failed", error = getCurrentExceptionMsg()

    ## For lightpush might not worth to measure outgoing traffic as it is only
    ## small response about success/failure

  wl.handler = handler
  wl.codec = WakuLightPushCodec

proc new*(
    T: type WakuLightPush,
    peerManager: PeerManager,
    rng: ref rand.HmacDrbgContext,
    pushHandler: PushMessageHandler,
    autoSharding: Option[Sharding],
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): T =
  let wl = WakuLightPush(
    rng: rng,
    peerManager: peerManager,
    pushHandler: pushHandler,
    requestRateLimiter: newRequestRateLimiter(rateLimitSetting),
    autoSharding: autoSharding,
  )
  wl.initProtocolHandler()
  setServiceLimitMetric(WakuLightpushCodec, rateLimitSetting)
  return wl
