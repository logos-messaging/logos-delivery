## Messaging layer core: the `MessagingClient` type plus its construction and
## lifecycle. The public operations (subscribe / unsubscribe / send) live in
## `messaging/api.nim`.
import results, chronos
import chronicles
import
  logos_delivery/messaging/messaging_client,
  logos_delivery/messaging/api/send,
  logos_delivery/api/requests/messaging_client_requests,
  logos_delivery/waku/waku,
  logos_delivery/messaging/delivery_service/[recv_service, send_service]

# Surfaces the messaging API interface (and its Message* events) to consumers.
export messaging_client

proc start*(self: MessagingClient): Result[void, string] =
  if self.started:
    return ok()
  self.recvService.startRecvService()
  self.sendService.startSendService()

  ?MessagingSend.setProvider(
    self.brokerCtx,
    proc(envelope: MessageEnvelope): Future[Result[RequestId, string]] {.async.} =
      return await self.send(envelope),
  )

  self.started = true
  ok()

proc stop*(self: MessagingClient) {.async.} =
  if not self.started:
    return
  MessagingSend.clearProvider(self.brokerCtx)
  await self.sendService.stopSendService()
  await self.recvService.stopRecvService()
  self.started = false
