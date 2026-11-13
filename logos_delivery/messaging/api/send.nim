## Messaging layer API — send operation.
import results, chronos, chronicles

import logos_delivery/api/types
import logos_delivery/api/events/messaging_client_events
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/waku
import logos_delivery/messaging/delivery_service/send_service
import logos_delivery/messaging/delivery_service/send_service/delivery_task

proc acceptSend(self: MessagingClient, envelope: MessageEnvelope): SendResult =
  ## The body of `send`. It is not async, so it cannot suspend.
  self.checkApiAvailability().isOkOr:
    return err(SendError.init(SendErrorKind.Other, error))
  # The task sets the message timestamp, and so the message hash.
  let deliveryTask = DeliveryTask.new(envelope, self.waku.brokerCtx).valueOr:
    error "Failed to create delivery task", error
    return err(
      SendError.init(
        SendErrorKind.Other,
        "MessagingClient.send: Failed to create delivery task: " & error,
      )
    )
  ?self.sendService.enqueue(deliveryTask)
  return ok(deliveryTask.msgHash)

proc send*(
    self: MessagingClient, envelope: MessageEnvelope
): Future[SendResult] {.async.} =
  ## Sets the timestamp of the message and returns the hash of the message.
  ## It refuses a message with a `SendError`, and then no event comes.
  ## It never suspends, so the caller gets the hash before any event, also over the FFI.
  return self.acceptSend(envelope)
