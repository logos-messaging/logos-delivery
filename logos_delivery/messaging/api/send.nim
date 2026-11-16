## Messaging layer API — send operation.
import results, chronos, chronicles

import logos_delivery/api/types
import logos_delivery/api/events/messaging_client_events
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/waku
import logos_delivery/messaging/delivery_service/send_service
import logos_delivery/messaging/delivery_service/send_service/delivery_task

proc enqueueSend(
    self: MessagingClient, envelope: MessageEnvelope
): Result[RequestId, string] =
  let requestId = RequestId.new(self.waku.rng)
  info "Messaging API enqueueSend", requestId

  ## The body of `send`. It is not async, so it cannot suspend.
  ?self.checkApiAvailability()

  let deliveryTask = DeliveryTask.new(requestId, envelope, self.waku.brokerCtx).valueOr:
    error "Failed to create delivery task", error, requestId
    return err("MessagingClient.send: Failed to create delivery task: " & error)

  return self.sendService.enqueue(deliveryTask)

proc send*(
    self: MessagingClient, envelope: MessageEnvelope
): Future[Result[RequestId, string]] {.async.} =
  ## Queues the message and returns its request id. It never suspends, so the
  ## caller gets the id before any event of the request, also over the FFI.
  return self.enqueueSend(envelope)
