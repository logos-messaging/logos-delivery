## Messaging layer API — send operation.
import results, chronos, chronicles

import logos_delivery/api/types
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/waku
import logos_delivery/waku/api/subscriptions
import logos_delivery/messaging/delivery_service/send_service
import logos_delivery/messaging/delivery_service/send_service/delivery_task

proc send*(
    self: MessagingClient, envelope: MessageEnvelope
): Future[Result[RequestId, string]] {.async.} =
  ## High-level messaging API send. Auto-subscribes to the content topic
  ## (so the local node sees its own gossipsub broadcast), builds a
  ## `DeliveryTask`, and hands it to the send service. Returns the request
  ## id the caller can correlate with `MessageSentEvent` / `MessageErrorEvent`.
  ?self.checkApiAvailability()

  let isSubbed = self.waku.isSubscribed(envelope.contentTopic).valueOr(false)
  if not isSubbed:
    info "Auto-subscribing to topic on send", contentTopic = envelope.contentTopic
    self.waku.subscribe(envelope.contentTopic).isOkOr:
      warn "Failed to auto-subscribe", error = error
      return err("Failed to auto-subscribe before sending: " & error)

  let requestId = RequestId.new(self.waku.rng)

  let deliveryTask = DeliveryTask.new(requestId, envelope, self.waku.brokerCtx).valueOr:
    return err("MessagingClient.send: Failed to create delivery task: " & error)

  asyncSpawn self.sendService.send(deliveryTask)

  return ok(requestId)
