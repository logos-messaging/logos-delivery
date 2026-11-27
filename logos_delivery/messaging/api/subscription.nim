## Messaging layer API — subscription operations.
import results, chronos

import logos_delivery/api/types
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/waku
import logos_delivery/waku/api/subscriptions

proc subscribe*(
    self: MessagingClient, contentTopic: ContentTopic, startTime = Opt.none(Timestamp)
): Future[Result[void, string]] {.async.} =
  ## A first subscribe with a `startTime` also gets the messages since then from Store.
  ?self.checkApiAvailability()
  return self.waku.subscribe(contentTopic, startTime)

proc unsubscribe*(
    self: MessagingClient, contentTopic: ContentTopic
): Result[void, string] =
  ?self.checkApiAvailability()
  return self.waku.unsubscribe(contentTopic)
