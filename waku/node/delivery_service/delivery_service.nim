## This module helps to ensure the correct transmission and reception of messages

import results
import chronos
import
  ./recv_service,
  ./send_service,
  waku/[
    waku_core,
    waku_node,
    waku_store/client,
    waku_relay/protocol,
    waku_lightpush/client,
    waku_filter_v2/client,
  ]

type DeliveryService* = ref object
  sendService*: SendService
  recvService: RecvService

proc new*(
    T: type DeliveryService, useP2PReliability: bool, w: WakuNode
): Result[T, string] =
  ## storeClient is needed to give store visitility to DeliveryService
  ## wakuRelay and wakuLightpushClient are needed to give a mechanism to SendService to re-publish
  let sendService = ?SendService.new(useP2PReliability, w)
  let recvService = RecvService.new(w)
  return ok(DeliveryService(sendService: sendService, recvService: recvService))

proc startDeliveryService*(self: DeliveryService) =
  self.sendService.startSendService()
  self.recvService.startRecvService()

proc stopDeliveryService*(self: DeliveryService) {.async.} =
  self.sendService.stopSendService()
  await self.recvService.stopRecvService()
