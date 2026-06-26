## Messaging layer API — subscription operations.
import results, chronos

import logos_delivery/api/types
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/waku
import logos_delivery/waku/node/[waku_node, subscription_manager]

proc subscribe*(
    self: MessagingClient, contentTopic: ContentTopic
): Future[Result[void, string]] {.async.} =
  ?self.checkApiAvailability()
  return self.waku.node.subscriptionManager.subscribe(contentTopic)

proc unsubscribe*(
    self: MessagingClient, contentTopic: ContentTopic
): Result[void, string] =
  ?self.checkApiAvailability()
  return self.waku.node.subscriptionManager.unsubscribe(contentTopic)
