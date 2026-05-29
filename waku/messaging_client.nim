import results, chronos
import
  ./node/waku_node,
  ./node/delivery_service/[recv_service, send_service]

type MessagingClient* = ref object
  sendService*: SendService
  recvService*: RecvService
  started: bool

proc new*(
    T: type MessagingClient, useP2PReliability: bool, node: WakuNode
): Result[T, string] =
  let sendService = ?SendService.new(useP2PReliability, node)
  let recvService = RecvService.new(node)
  ok(T(sendService: sendService, recvService: recvService))

proc start*(self: MessagingClient): Result[void, string] =
  if self.started:
    return ok()
  self.recvService.startRecvService()
  self.sendService.startSendService()
  self.started = true
  ok()

proc stop*(self: MessagingClient) {.async.} =
  if not self.started:
    return
  await self.sendService.stopSendService()
  await self.recvService.stopRecvService()
  self.started = false
