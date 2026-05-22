{.push raises: [].}

import std/options, results, chronicles, chronos, metrics, bearssl/rand, stew/byteutils
import libp2p/peerid, libp2p/stream/connection
import
  ../waku_core/peers,
  ../node/peer_manager,
  ../utils/requests,
  ../waku_core,
  ./common,
  ./protocol_metrics,
  ./rpc,
  ./rpc_codec

logScope:
  topics = "waku lightpush client"

type WakuLightPushClient* = ref object
  rng*: ref rand.HmacDrbgContext
  peerManager*: PeerManager

proc new*(
    T: type WakuLightPushClient, peerManager: PeerManager, rng: ref rand.HmacDrbgContext
): T =
  WakuLightPushClient(peerManager: peerManager, rng: rng)

proc ensureTimestampSet(message: var WakuMessage) =
  if message.timestamp == 0:
    message.timestamp = getNowInNanosecondTime()

## Short log string for peer identifiers (overloads for convenience)
func shortPeerId(peer: PeerId): string =
  shortLog(peer)

func shortPeerId(peer: RemotePeerInfo): string =
  shortLog(peer.peerId)

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
    dest: Connection | PeerId | RemotePeerInfo,
): Future[WakuLightPushResult] {.async, gcsafe.} =
  var message = wakuMessage
  ensureTimestampSet(message)

  let msgHash = computeMessageHash(pubSubTopic.get(""), message).to0xHex()

  let peerIdStr =
    when dest is Connection:
      shortPeerId(dest.peerId)
    else:
      shortPeerId(dest)

  info "publish",
    myPeerId = wl.peerManager.switch.peerInfo.peerId,
    peerId = peerIdStr,
    msgHash = msgHash,
    sentTime = getNowInNanosecondTime()

  let request = LightpushRequest(
    requestId: generateRequestId(wl.rng), pubsubTopic: pubSubTopic, message: message
  )

  let relayPeerCount =
    when dest is Connection:
      ?await wl.sendPushRequest(request, dest.peerId, some(dest))
    else:
      ?await wl.sendPushRequest(request, dest)

  return lightpushSuccessResult(relayPeerCount)

proc publishToAny*(
    wl: WakuLightPushClient, pubsubTopic: PubsubTopic, wakuMessage: WakuMessage
): Future[WakuLightPushResult] {.async, gcsafe.} =
  # Like publish, but selects a peer automatically from the peer manager
  let peer = wl.peerManager.selectPeer(WakuLightPushCodec).valueOr:
    # TODO: check if it is matches the situation - shall we distinguish client side missing peers from server side?
    return lighpushErrorResult(
      LightPushErrorCode.NO_PEERS_TO_RELAY, "no suitable remote peers"
    )
  return await wl.publish(some(pubsubTopic), wakuMessage, peer)

proc publishWithConn*(
    wl: WakuLightPushClient,
    pubSubTopic: PubsubTopic,
    message: WakuMessage,
    conn: Connection,
    destPeer: PeerId,
): Future[WakuLightPushResult] {.async, gcsafe.} =
  return await wl.publish(some(pubSubTopic), message, conn)
