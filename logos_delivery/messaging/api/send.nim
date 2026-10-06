## Messaging layer API — send operation.
import results, chronos, chronicles

import logos_delivery/api/types
import logos_delivery/api/events/messaging_client_events
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/waku
import logos_delivery/waku/api/subscriptions
import logos_delivery/messaging/delivery_service/send_service
import logos_delivery/messaging/delivery_service/send_service/delivery_task

proc send*(
    self: MessagingClient, envelope: MessageEnvelope
): Future[Result[RequestId, string]] {.async.} =
  ## High-level messaging API send. At the `None` anonymity level, subscribes
  ## the node to the content topic with a weak interest (see
  ## `SubscriptionManager.subscribe`), so that the app receives its own
  ## message. An app that wants to receive the topic subscribes to it. At a
  ## higher level, the send makes no subscription, because a subscription gives
  ## the topic to filter peers and to Store peers. Builds a `DeliveryTask`, and
  ## hands it to
  ## the send service. Returns the request id the caller can correlate with
  ## `MessageSentEvent` / `MessageErrorEvent`.
  ?self.checkApiAvailability()

  if self.sendService.isFull():
    return err("Send queue full, retry later")

  if self.sendService.subscribesOnSend():
    let isSubbed = self.waku.isSubscribed(envelope.contentTopic).valueOr(false)
    if not isSubbed:
      debug "Auto-subscribing to topic on send", contentTopic = envelope.contentTopic
      self.waku.subscribe(envelope.contentTopic, weak = true).isOkOr:
        error "Failed to auto-subscribe", error = error
        return err("Failed to auto-subscribe before sending: " & error)

  let requestId = RequestId.new(self.waku.rng)

  let deliveryTask = DeliveryTask.new(requestId, envelope, self.waku.brokerCtx).valueOr:
    return err("MessagingClient.send: Failed to create delivery task: " & error)

  asyncSpawn self.sendService.send(deliveryTask)

  return ok(requestId)
