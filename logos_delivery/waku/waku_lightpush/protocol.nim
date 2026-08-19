import libp2p/crypto/crypto
{.push raises: [].}

import std/strutils, results, stew/byteutils, chronicles, chronos, metrics, bearssl/rand
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
  rng*: crypto.Rng
  peerManager*: PeerManager
  pushHandler*: PushMessageHandler
  requestRateLimiter*: RequestRateLimiter
  autoSharding: Opt[Sharding]

proc handleRequest(
    wl: WakuLightPush, peerId: PeerId, pushRequest: LightpushRequest
): Future[WakuLightPushResult] {.async.} =
  let pubsubTopic = pushRequest.pubSubTopic.valueOr:
    if wl.autoSharding.isNone():
      let msg = "Pubsub topic must be specified when static sharding is enabled"
      debug "Lightpush request handling error", error = msg
      return WakuLightPushResult.err(
        (code: LightPushErrorCode.INVALID_MESSAGE, desc: Opt.some(msg))
      )

    let parsedTopic = NsContentTopic.parse(pushRequest.message.contentTopic).valueOr:
      let msg = "Invalid content-topic:" & $error
      debug "Lightpush request handling error", error = msg
      return WakuLightPushResult.err(
        (code: LightPushErrorCode.INVALID_MESSAGE, desc: Opt.some(msg))
      )

    wl.autoSharding.get().getShard(parsedTopic).valueOr:
      let msg = "Auto-sharding error: " & error
      debug "Lightpush request handling error", error = msg
      return WakuLightPushResult.err(
        (code: LightPushErrorCode.INTERNAL_SERVER_ERROR, desc: Opt.some(msg))
      )

  # ensure checking topic will not cause error at gossipsub level
  if pubsubTopic.isEmptyOrWhitespace():
    let msg = "topic must not be empty"
    debug "Lightpush request handling error", error = msg
    return WakuLightPushResult.err(
      (code: LightPushErrorCode.BAD_REQUEST, desc: Opt.some(msg))
    )

  logos_delivery_lightpush_v3_messages.inc(labelValues = ["PushRequest"])

  let msg_hash = pubsubTopic.computeMessageHash(pushRequest.message).to0xHex()
  debug "Handling lightpush request",
    my_peer_id = wl.peerManager.switch.peerInfo.peerId,
    peer_id = peerId,
    requestId = pushRequest.requestId,
    pubsubTopic = pushRequest.pubsubTopic,
    contentTopic = pushRequest.message.contentTopic,
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
    debug "Failed to decode Lightpush request", error = desc
    let errorCode = LightPushErrorCode.BAD_REQUEST
    logos_delivery_lightpush_v3_errors.inc(labelValues = [$errorCode])
    return LightPushResponse(
      requestId: "N/A", # due to decode failure we don't know requestId
      statusCode: errorCode,
      statusDesc: Opt.some(desc),
    )

  let relayPeerCount = (await wl.handleRequest(peerId, request)).valueOr:
    let desc = error.desc
    logos_delivery_lightpush_v3_errors.inc(labelValues = [$error.code])
    debug "Failed to push message", error = desc.get("")
    return LightPushResponse(
      requestId: request.requestId, statusCode: error.code, statusDesc: desc
    )

  return LightPushResponse(
    requestId: request.requestId,
    statusCode: LightPushSuccessCode.SUCCESS,
    statusDesc: Opt.none(string),
    relayPeerCount: Opt.some(relayPeerCount),
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
        debug "Lightpush read stream failed", error = getCurrentExceptionMsg()
        return

      logos_delivery_service_network_bytes.inc(
        amount = buffer.len().int64, labelValues = [WakuLightPushCodec, "in"]
      )

      try:
        rpc = await wl.handleRequest(conn.peerId, buffer)
      except CatchableError:
        error "lightpush failed handleRequest", error = getCurrentExceptionMsg()
    do:
      debug "Lightpush request rejected due rate limit exceeded",
        peerId = conn.peerId, limit = $wl.requestRateLimiter.setting

      rpc = static(
        LightPushResponse(
          ## We will not copy and decode RPC buffer from stream only for requestId
          ## in reject case as it is comparably too expensive and opens possible
          ## attack surface
          requestId: "N/A",
          statusCode: LightPushErrorCode.TOO_MANY_REQUESTS,
          statusDesc: Opt.some(TooManyRequestsMessage),
        )
      )

    try:
      await conn.writeLp(rpc.encode().buffer)
    except LPStreamError:
      debug "Lightpush write stream failed", error = getCurrentExceptionMsg()

    ## For lightpush might not worth to measure outgoing traffic as it is only
    ## small response about success/failure

  wl.handler = handler
  wl.codec = WakuLightPushCodec

proc new*(
    T: type WakuLightPush,
    peerManager: PeerManager,
    rng: crypto.Rng,
    pushHandler: PushMessageHandler,
    autoSharding: Opt[Sharding],
    rateLimitSetting: Opt[RateLimitSetting] = Opt.none(RateLimitSetting),
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
