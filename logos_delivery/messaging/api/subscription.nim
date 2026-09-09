## Messaging layer API — subscription operations.
import results, chronos

import logos_delivery/api/types
import logos_delivery/messaging/messaging_client
import logos_delivery/messaging/delivery_service/recv_service
import logos_delivery/waku/waku
import logos_delivery/waku/api/subscriptions

proc subscribe*(
    self: MessagingClient, contentTopic: ContentTopic
): Future[Result[void, string]] {.async.} =
  ?self.checkApiAvailability()
  ?self.waku.subscribe(contentTopic)
  self.recvService.noteSubscribed()
  return ok()

proc unsubscribe*(
    self: MessagingClient, contentTopic: ContentTopic
): Result[void, string] =
  ?self.checkApiAvailability()
  return self.waku.unsubscribe(contentTopic)
