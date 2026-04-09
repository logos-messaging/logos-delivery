## This module helps to ensure the correct transmission and reception of messages

import results
import chronos, chronicles
import
  ./recv_service,
  ./send_service,
  ./subscription_manager,
  waku/[
    waku_core, waku_node, waku_store/client, waku_relay/protocol, waku_lightpush/client
  ]

type DeliveryService* = ref object
  sendService*: SendService
  recvService*: RecvService
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

proc startDeliveryService*(self: DeliveryService): Result[void, string] =
  ?self.subscriptionManager.startSubscriptionManager()
  self.recvService.startRecvService()
  self.sendService.startSendService()
  return ok()

proc stopDeliveryService*(self: DeliveryService) {.async.} =
  await self.sendService.stopSendService()
  await self.recvService.stopRecvService()
  await self.subscriptionManager.stopSubscriptionManager()
