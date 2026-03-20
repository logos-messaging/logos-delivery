{.push raises: [].}

import std/options, results, chronicles, chronos, metrics, bearssl/rand, stew/byteutils
import libp2p/peerid
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
  topics = "waku lightpush legacy client"

type WakuLegacyLightPushClient* = ref object
  peerManager*: PeerManager
  rng*: ref rand.HmacDrbgContext

proc new*(
    T: type WakuLegacyLightPushClient,
    peerManager: PeerManager,
    rng: ref rand.HmacDrbgContext,
): T =
  WakuLegacyLightPushClient(peerManager: peerManager, rng: rng)

proc sendPushRequest(
    wl: WakuLegacyLightPushClient, req: PushRequest, peer: PeerId | RemotePeerInfo
): Future[WakuLightPushResult[void]] {.async, gcsafe.} =
  let connOpt = await wl.peerManager.dialPeer(peer, WakuLegacyLightPushCodec)
  if connOpt.isNone():
    waku_lightpush_errors.inc(labelValues = [dialFailure])
    return err(dialFailure)
  let connection = connOpt.get()

  defer:
    await connection.closeWithEOF()

  let rpc = PushRPC(requestId: generateRequestId(wl.rng), request: some(req))
  await connection.writeLP(rpc.encode().buffer)

  var buffer: seq[byte]
  try:
    buffer = await connection.readLp(DefaultMaxRpcSize.int)
  except LPStreamRemoteClosedError:
    return err("Exception reading: " & getCurrentExceptionMsg())

  let pushResponseRes = PushRPC.decode(buffer).valueOr:
    error "failed to decode response"
    waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
    return err(decodeRpcFailure)

  if pushResponseRes.response.isNone():
    waku_lightpush_errors.inc(labelValues = [emptyResponseBodyFailure])
    return err(emptyResponseBodyFailure)

  let response = pushResponseRes.response.get()
  if not response.isSuccess:
    if response.info.isSome():
      return err(response.info.get())
    else:
      return err("unknown failure")

  return ok()

proc publish*(
    wl: WakuLegacyLightPushClient,
    pubSubTopic: PubsubTopic,
    wakuMessage: WakuMessage,
    peer: RemotePeerInfo,
): Future[WakuLightPushResult[string]] {.async, gcsafe.} =
  ## On success, returns the msg_hash of the published message

  var message = wakuMessage
  if message.timestamp == 0:
    message.timestamp = getNowInNanosecondTime()

  let msg_hash_hex_str = computeMessageHash(pubsubTopic, message).to0xHex()
  let pushRequest = PushRequest(pubSubTopic: pubSubTopic, message: message)
  ?await wl.sendPushRequest(pushRequest, peer)

  notice "publishing message with lightpush",
    pubsubTopic = pubsubTopic,
    contentTopic = message.contentTopic,
    target_peer_id = peer.peerId,
    msg_hash = msg_hash_hex_str

  return ok(msg_hash_hex_str)

proc publishToAny*(
    wl: WakuLegacyLightPushClient, pubSubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult[void]] {.async, gcsafe.} =
  ## This proc is similar to the publish one but in this case
  ## we don't specify a particular peer and instead we get it from peer manager

  info "publishToAny", msg_hash = computeMessageHash(pubsubTopic, message).to0xHex

  let peer = wl.peerManager.selectPeer(WakuLegacyLightPushCodec).valueOr:
    return err("could not retrieve a peer supporting WakuLegacyLightPushCodec")

  let pushRequest = PushRequest(pubSubTopic: pubSubTopic, message: message)
  ?await wl.sendPushRequest(pushRequest, peer)

  return ok()
