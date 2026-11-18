## Messaging layer API — send operation.
import results, chronos, chronicles

import logos_delivery/api/types
import logos_delivery/api/events/messaging_client_events
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/waku
import logos_delivery/messaging/delivery_service/send_service
import logos_delivery/messaging/delivery_service/send_service/delivery_task

proc enqueueSend(self: MessagingClient, envelope: MessageEnvelope): SendResult =
  ## The body of `send`. It is not async, so it cannot suspend.
  self.checkApiAvailability().isOkOr:
    return err(SendError.init(SendErrorKind.NotStarted, error))

  let deliveryTask = DeliveryTask.new(envelope, self.waku.brokerCtx).valueOr:
    error "Failed to create delivery task", error
    return err(
      SendError.init(
        SendErrorKind.NoShard,
        "MessagingClient.send: Failed to create delivery task: " & error,
      )
    )

  ?self.sendService.enqueue(deliveryTask)
  return ok(deliveryTask.msgHash)

proc send*(
    self: MessagingClient, envelope: MessageEnvelope
): Future[SendResult] {.async.} =
  ## Sets the timestamp of the message, queues it and returns its hash.
  ## The hash identifies the send in each event of the message.
  ## An event carries it as text, the `to0xHex()` of the hash.
  ## It refuses a message with a `SendError`, and then no event comes.
  ## It never suspends, so the caller gets the hash before any event, also over the FFI.
  return self.enqueueSend(envelope)
