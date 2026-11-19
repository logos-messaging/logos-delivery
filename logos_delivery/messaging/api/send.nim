## Messaging layer API — send operation.
import results, chronos, chronicles

import logos_delivery/api/types
import logos_delivery/api/events/messaging_client_events
import logos_delivery/messaging/messaging_client
import logos_delivery/waku/waku
import logos_delivery/waku/api/publish
import logos_delivery/waku/waku_core/codecs
import logos_delivery/waku/node/peer_manager
import logos_delivery/messaging/delivery_service/send_service
import logos_delivery/messaging/delivery_service/send_service/delivery_task

proc canReachPeer(self: MessagingClient): bool =
  ## True when the node has a connected peer, or knows a lightpush peer. A
  ## lightpush attempt dials its peer, so an edge whose only peer is its
  ## lightpush service peer gets its first connection from a send.
  let (inPeers, outPeers) = self.waku.node.peerManager.connectedPeers()
  if inPeers.len + outPeers.len > 0:
    return true
  return
    self.waku.hasLightpush() and
    self.waku.node.peerManager.selectPeer(WakuLightPushCodec).isSome()

proc send*(
    self: MessagingClient, envelope: MessageEnvelope
): Future[Result[WakuMessageHash, SendError]] {.async: (raises: []).} =
  ## Stamps the message, charges the rate-limit budget and returns the message
  ## hash. It never suspends: the budget is the one that the rate limit manager
  ## last read. A refused message gets a `SendError` and no event. The events of
  ## an accepted message carry its hash and come after `send` returns, also over
  ## the FFI.
  self.checkApiAvailability().isOkOr:
    return err(SendError.init(SendErrorKind.NotStarted, error))

  # Only a node that can reach no peer is refused: the health status needs more
  # than a send does, such as a filter peer for an edge or relay peers for a node
  # that falls back to lightpush.
  if not self.canReachPeer():
    return err(SendError.init(SendErrorKind.NotConnected, "node has no connected peer"))

  let deliveryTask = DeliveryTask.new(envelope, self.waku.brokerCtx).valueOr:
    debug "Failed to create delivery task", error
    return err(SendError.init(SendErrorKind.NoShard, error))

  let msgHash = self.sendService.enqueue(deliveryTask).valueOr:
    debug "Send refused", msgHash = deliveryTask.loggedHash(), error = $error
    return err(error)
  return ok(msgHash)
