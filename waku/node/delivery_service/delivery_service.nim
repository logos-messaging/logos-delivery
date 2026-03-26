## This module helps to ensure the correct transmission and reception of messages

import std/tables
import results
import chronos, chronicles
import
  ./recv_service,
  ./send_service,
  ./subscription_manager,
  waku/[
    waku_core,
    waku_node,
    waku_store/client,
    waku_relay/protocol,
    waku_lightpush/client,
    waku_filter_v2/client,
    requests/health_requests,
    node/health_monitor/topic_health,
    node/health_monitor/connection_status,
  ]

type DeliveryService* = ref object
  sendService*: SendService
  recvService: RecvService
  subscriptionManager*: SubscriptionManager

proc new*(
    T: type DeliveryService, useP2PReliability: bool, w: WakuNode
): Result[T, string] =
  ## storeClient is needed to give store visitility to DeliveryService
  ## wakuRelay and wakuLightpushClient are needed to give a mechanism to SendService to re-publish
  let subscriptionManager = SubscriptionManager.new(w)
  let sendService = ?SendService.new(useP2PReliability, w, subscriptionManager)
  let recvService = RecvService.new(w, subscriptionManager)

  return ok(
    DeliveryService(
      sendService: sendService,
      recvService: recvService,
      subscriptionManager: subscriptionManager,
    )
  )

proc startDeliveryService*(self: DeliveryService) =
  let sm = self.subscriptionManager
  let node = sm.node

  # Register edge filter broker providers. The shard/content health providers
  # in WakuNode query these via the broker as a fallback when relay health is
  # not available. If edge mode is not active, these providers simply return
  # NOT_SUBSCRIBED / strength 0, which is harmless.
  RequestEdgeShardHealth.setProvider(
    node.brokerCtx,
    proc(shard: PubsubTopic): Result[RequestEdgeShardHealth, string] =
      sm.edgeFilterSubStates.withValue(shard, state):
        return ok(RequestEdgeShardHealth(health: state.currentHealth))
      return ok(RequestEdgeShardHealth(health: TopicHealth.NOT_SUBSCRIBED)),
  ).isOkOr:
    error "Can't set provider for RequestEdgeShardHealth", error = error

  RequestEdgeFilterPeerCount.setProvider(
    node.brokerCtx,
    proc(): Result[RequestEdgeFilterPeerCount, string] =
      var minPeers = high(int)
      for state in sm.edgeFilterSubStates.values:
        minPeers = min(minPeers, state.peers.len)
      if minPeers == high(int):
        minPeers = 0
      return ok(RequestEdgeFilterPeerCount(peerCount: minPeers)),
  ).isOkOr:
    error "Can't set provider for RequestEdgeFilterPeerCount", error = error

  sm.startSubscriptionManager()
  if isNil(sm.node.wakuRelay):
    sm.startEdgeFilterLoops()
  self.recvService.startRecvService()
  self.sendService.startSendService()

proc stopDeliveryService*(self: DeliveryService) {.async.} =
  if isNil(self.subscriptionManager.node.wakuRelay):
    await self.subscriptionManager.stopEdgeFilterLoops()
  await self.sendService.stopSendService()
  await self.recvService.stopRecvService()
  await self.subscriptionManager.stopSubscriptionManager()
  let brokerCtx = self.subscriptionManager.node.brokerCtx
  RequestEdgeShardHealth.clearProvider(brokerCtx)
  RequestEdgeFilterPeerCount.clearProvider(brokerCtx)
