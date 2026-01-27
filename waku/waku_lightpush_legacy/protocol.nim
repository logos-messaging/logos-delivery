{.push raises: [].}

import std/options, results, stew/byteutils, chronicles, chronos, metrics, bearssl/rand
import
  ../node/peer_manager/peer_manager,
  ../waku_core,
  ./common,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics,
  ../common/rate_limit/request_limiter

logScope:
  topics = "waku lightpush legacy"

type WakuLegacyLightPush* = ref object of LPProtocol
  rng*: ref rand.HmacDrbgContext
  peerManager*: PeerManager
  pushHandler*: PushMessageHandler
  requestRateLimiter*: RequestRateLimiter

proc handleRequest*(
    wl: WakuLegacyLightPush, peerId: PeerId, buffer: seq[byte]
): Future[PushRPC] {.async.} =
  let reqDecodeRes = PushRPC.decode(buffer)
  var
    isSuccess = false
    pushResponseInfo = ""
    requestId = ""

  if reqDecodeRes.isErr():
    pushResponseInfo = decodeRpcFailure & ": " & $reqDecodeRes.error
  elif reqDecodeRes.get().request.isNone():
    pushResponseInfo = emptyRequestBodyFailure
  else:
    let pushRpcRequest = reqDecodeRes.get()

    requestId = pushRpcRequest.requestId

    let
      request = pushRpcRequest.request

      pubSubTopic = request.get().pubSubTopic
      message = request.get().message
    let msg_hash = pubsubTopic.computeMessageHash(message).to0xHex()
    waku_lightpush_messages.inc(labelValues = ["PushRequest"])

    notice "handling legacy lightpush request",
      my_peer_id = wl.peerManager.switch.peerInfo.peerId,
      peer_id = peerId,
      requestId = requestId,
      pubsubTopic = pubsubTopic,
      msg_hash = msg_hash,
      receivedTime = getNowInNanosecondTime()

    let handleRes = await wl.pushHandler(pubsubTopic, message)
    isSuccess = handleRes.isOk()
    pushResponseInfo = (if isSuccess: "OK" else: handleRes.error)

  if not isSuccess:
    waku_lightpush_errors.inc(labelValues = [pushResponseInfo])
    error "failed to push message", error = pushResponseInfo
  let response = PushResponse(isSuccess: isSuccess, info: some(pushResponseInfo))
  let rpc = PushRPC(requestId: requestId, response: some(response))
  return rpc

proc initProtocolHandler(wl: WakuLegacyLightPush) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var rpc: PushRPC
    defer:
      await conn.closeWithEOF()

    wl.requestRateLimiter.checkUsageLimit(WakuLegacyLightPushCodec, conn):
      var buffer: seq[byte]
      try:
        buffer = await conn.readLp(DefaultMaxRpcSize)
      except LPStreamError:
        error "lightpush legacy read stream failed", error = getCurrentExceptionMsg()
        return

      waku_service_network_bytes.inc(
        amount = buffer.len().int64, labelValues = [WakuLegacyLightPushCodec, "in"]
      )

      try:
        rpc = await handleRequest(wl, conn.peerId, buffer)
      except CatchableError:
        error "lightpush legacy handleRequest failed", error = getCurrentExceptionMsg()
    do:
      info "lightpush request rejected due rate limit exceeded",
        peerId = conn.peerId, limit = $wl.requestRateLimiter.setting

      rpc = static(
        PushRPC(
          ## We will not copy and decode RPC buffer from stream only for requestId
          ## in reject case as it is comparably too expensive and opens possible
          ## attack surface
          requestId: "N/A",
          response:
            some(PushResponse(isSuccess: false, info: some(TooManyRequestsMessage))),
        )
      )

    try:
      await conn.writeLp(rpc.encode().buffer)
    except LPStreamError:
      error "lightpush legacy write stream failed", error = getCurrentExceptionMsg()

    ## For lightpush might not worth to measure outgoing trafic as it is only
    ## small respones about success/failure

  wl.handler = handler
  wl.codec = WakuLegacyLightPushCodec

proc new*(
    T: type WakuLegacyLightPush,
    peerManager: PeerManager,
    rng: ref rand.HmacDrbgContext,
    pushHandler: PushMessageHandler,
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): T =
  let wl = WakuLegacyLightPush(
    rng: rng,
    peerManager: peerManager,
    pushHandler: pushHandler,
    requestRateLimiter: newRequestRateLimiter(rateLimitSetting),
  )
  wl.initProtocolHandler()
  setServiceLimitMetric(WakuLegacyLightPushCodec, rateLimitSetting)
  return wl
