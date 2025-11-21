import chronicles, chronos, results
import std/options

import
  waku/waku_node,
  waku/waku_core,
  waku/node/peer_manager,
  waku/waku_lightpush/[callbacks, common, client, rpc]

import ./[delivery_task, send_processor]

logScope:
  topics = "send service lightpush processor"

type LightpushSendProcessor* = ref object of BaseSendProcessor
  peerManager: PeerManager
  lightpushClient: WakuLightPushClient

proc new*(
    T: type LightpushSendProcessor,
    peerManager: PeerManager,
    lightpushClient: WakuLightPushClient,
): T =
  return T(peerManager: peerManager, lightpushClient: lightpushClient)

proc isLightpushPeerAvailable(
    self: LightpushSendProcessor, pubsubTopic: PubsubTopic
): bool =
  return self.peerManager.selectPeer(WakuLightPushCodec, some(pubsubTopic)).isSome()

method isValidProcessor*(
    self: LightpushSendProcessor, task: DeliveryTask
): Future[bool] {.async.} =
  return self.isLightpushPeerAvailable(task.pubsubTopic)

method sendImpl*(
    self: LightpushSendProcessor, task: DeliveryTask
): Future[void] {.async.} =
  task.tryCount.inc()
  info "Trying message delivery via Lightpush",
    requestId = task.requestId, msgHash = task.msgHash, tryCount = task.tryCount

  let peer = self.peerManager.selectPeer(WakuLightPushCodec, some(task.pubsubTopic)).valueOr:
    task.state = DeliveryState.NextRoundRetry
    return

  let pushResult =
    await self.lightpushClient.publish(some(task.pubsubTopic), task.msg, peer)
  if pushResult.isErr:
    error "LightpushSendProcessor sendImpl failed",
      error = pushResult.error.desc.get($pushResult.error.code)
    case pushResult.error.code
    of LightPushErrorCode.NO_PEERS_TO_RELAY, LightPushErrorCode.TOO_MANY_REQUESTS,
        LightPushErrorCode.OUT_OF_RLN_PROOF, LightPushErrorCode.SERVICE_NOT_AVAILABLE,
        LightPushErrorCode.INTERNAL_SERVER_ERROR:
      task.state = DeliveryState.NextRoundRetry
    else:
      # the message is malformed, send error
      task.state = DeliveryState.FailedToDeliver
      task.errorDesc = pushResult.error.desc.get($pushResult.error.code)
      task.deliveryTime = Moment.now()
    return

  if pushResult.isOk and pushResult.get() > 0:
    info "Message propagated via Relay",
      requestId = task.requestId, msgHash = task.msgHash
    task.state = DeliveryState.SuccessfullyPropagated
    task.deliveryTime = Moment.now()
    # TODO: with a simple retry processor it might be more accurate to say `Sent`
  else:
    # Controversial state, publish says ok but no peer. It should not happen.
    task.state = DeliveryState.NextRoundRetry

  return
