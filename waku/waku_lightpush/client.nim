{.push raises: [].}

import std/options, results, chronicles, chronos, metrics, bearssl/rand, stew/byteutils
import libp2p/peerid, libp2p/stream/connection
import
  ../waku_core/peers,
  ../node/peer_manager,
  ../node/delivery_monitor/publish_observer,
  ../utils/requests,
  ../waku_core,
  ./common,
  ./protocol_metrics,
  ./rpc,
  ./rpc_codec,
  ../common/benchmark_metrics

logScope:
  topics = "waku lightpush client"

type WakuLightPushClient* = ref object
  peerManager*: PeerManager
  rng*: ref rand.HmacDrbgContext
  publishObservers: seq[PublishObserver]

proc new*(
    T: type WakuLightPushClient, peerManager: PeerManager, rng: ref rand.HmacDrbgContext
): T =
  WakuLightPushClient(peerManager: peerManager, rng: rng)

proc addPublishObserver*(wl: WakuLightPushClient, obs: PublishObserver) =
  wl.publishObservers.add(obs)

proc sendPushRequest(
    wl: WakuLightPushClient,
    req: LightPushRequest,
    peer: PeerId | RemotePeerInfo,
    conn: Option[Connection] = none(Connection),
): Future[WakuLightPushResult] {.async.} =
  let connection = conn.valueOr:
    (await wl.peerManager.dialPeer(peer, WakuLightPushCodec)).valueOr:
      waku_lightpush_v3_errors.inc(labelValues = [dialFailure])
      return lighpushErrorResult(
        LightPushErrorCode.NO_PEERS_TO_RELAY,
        dialFailure & ": " & $peer & " is not accessible",
      )

  defer:
    await connection.closeWithEOF()

  await connection.writeLP(req.encode().buffer)

  var buffer: seq[byte]
  try:
    buffer = await connection.readLp(DefaultMaxRpcSize.int)
  except LPStreamRemoteClosedError:
    error "Failed to read response from peer", error = getCurrentExceptionMsg()
    return lightpushResultInternalError(
      "Failed to read response from peer: " & getCurrentExceptionMsg()
    )

  let response = LightpushResponse.decode(buffer).valueOr:
    error "failed to decode response"
    waku_lightpush_v3_errors.inc(labelValues = [decodeRpcFailure])
    return lightpushResultInternalError(decodeRpcFailure)

  if response.requestId != req.requestId and
      response.statusCode != LightPushErrorCode.TOO_MANY_REQUESTS:
    error "response failure, requestId mismatch",
      requestId = req.requestId, responseRequestId = response.requestId
    return lightpushResultInternalError("response failure, requestId mismatch")

  return toPushResult(response)

proc publish*(
    wl: WakuLightPushClient,
    pubSubTopic: Option[PubsubTopic] = none(PubsubTopic),
    wakuMessage: WakuMessage,
    peer: PeerId | RemotePeerInfo,
): Future[WakuLightPushResult] {.async, gcsafe.} =
  benchmarkPoint("waku_lightpush_client", "publish")
  var message = wakuMessage
  if message.timestamp == 0:
    message.timestamp = getNowInNanosecondTime()

  when peer is PeerId:
    info "publish",
      peerId = shortLog(peer),
      msg_hash = computeMessageHash(pubsubTopic.get(""), message).to0xHex
  else:
    info "publish",
      peerId = shortLog(peer.peerId),
      msg_hash = computeMessageHash(pubsubTopic.get(""), message).to0xHex

  let pushRequest = LightpushRequest(
    requestId: generateRequestId(wl.rng), pubSubTopic: pubSubTopic, message: message
  )
  let publishedCount = ?await wl.sendPushRequest(pushRequest, peer)

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubSubTopic.get(""), message)

  return lightpushSuccessResult(publishedCount)

proc publishToAny*(
    wl: WakuLightPushClient, pubSubTopic: PubsubTopic, wakuMessage: WakuMessage
): Future[WakuLightPushResult] {.async, gcsafe.} =
  ## This proc is similar to the publish one but in this case
  ## we don't specify a particular peer and instead we get it from peer manager
  benchmarkPoint("waku_lightpush_client", "publishToAny")

  var message = wakuMessage
  if message.timestamp == 0:
    message.timestamp = getNowInNanosecondTime()

  let peer = wl.peerManager.selectPeer(WakuLightPushCodec).valueOr:
    # TODO: check if it is matches the situation - shall we distinguish client side missing peers from server side?
    return lighpushErrorResult(
      LightPushErrorCode.NO_PEERS_TO_RELAY, "no suitable remote peers"
    )

  info "publishToAny",
    my_peer_id = wl.peerManager.switch.peerInfo.peerId,
    peer_id = peer.peerId,
    msg_hash = computeMessageHash(pubsubTopic, message).to0xHex,
    sentTime = getNowInNanosecondTime()

  let pushRequest = LightpushRequest(
    requestId: generateRequestId(wl.rng),
    pubSubTopic: some(pubSubTopic),
    message: message,
  )
  let publishedCount = ?await wl.sendPushRequest(pushRequest, peer)

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubSubTopic, message)

  return lightpushSuccessResult(publishedCount)

proc publishWithConn*(
    wl: WakuLightPushClient,
    pubSubTopic: PubsubTopic,
    message: WakuMessage,
    conn: Connection,
    destPeer: PeerId,
): Future[WakuLightPushResult] {.async, gcsafe.} =
  benchmarkPoint("waku_lightpush_client", "publishWithConn")
  info "publishWithConn",
    my_peer_id = wl.peerManager.switch.peerInfo.peerId,
    peer_id = destPeer,
    msg_hash = computeMessageHash(pubsubTopic, message).to0xHex,
    sentTime = getNowInNanosecondTime()

  let pushRequest = LightpushRequest(
    requestId: generateRequestId(wl.rng),
    pubSubTopic: some(pubSubTopic),
    message: message,
  )
  #TODO: figure out how to not pass destPeer as this is just a hack
  let publishedCount =
    ?await wl.sendPushRequest(pushRequest, destPeer, conn = some(conn))

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubSubTopic, message)

  return lightpushSuccessResult(publishedCount)
