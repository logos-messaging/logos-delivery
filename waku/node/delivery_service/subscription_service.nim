import chronos, chronicles
import
  waku/[
    waku_core,
    waku_core/topics,
    events/message_events,
    waku_node,
    common/broker/broker_context,
  ]

type SubscriptionService* = ref object of RootObj
  brokerCtx: BrokerContext
  node: WakuNode

proc new*(T: typedesc[SubscriptionService], node: WakuNode): T =
  ## The storeClient will help to acquire any possible missed messages

  return SubscriptionService(brokerCtx: node.brokerCtx, node: node)

proc isSubscribed*(
    self: SubscriptionService, topic: ContentTopic
): Result[bool, string] =
  var isSubscribed = false
  if self.node.wakuRelay.isNil() == false:
    return self.node.isSubscribed((kind: ContentSub, topic: topic))

  # TODO: Add support for edge mode with Filter subscription management
  return ok(isSubscribed)

#TODO: later PR may consider to refactor or place this function elsewhere
# The only important part is that it emits MessageReceivedEvent
proc getReceiveHandler(self: SubscriptionService): WakuRelayHandler =
  return proc(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
    let msgHash = computeMessageHash(topic, msg).to0xHex()
    info "API received message",
      pubsubTopic = topic, contentTopic = msg.contentTopic, msgHash = msgHash

    MessageReceivedEvent.emit(self.brokerCtx, msgHash, msg)

proc subscribe*(self: SubscriptionService, topic: ContentTopic): Result[void, string] =
  let isSubscribed = self.isSubscribed(topic).valueOr:
    error "Failed to check subscription status: ", error = error
    return err("Failed to check subscription status: " & error)

  if isSubscribed == false:
    if self.node.wakuRelay.isNil() == false:
      self.node.subscribe((kind: ContentSub, topic: topic), self.getReceiveHandler()).isOkOr:
        error "Failed to subscribe: ", error = error
        return err("Failed to subscribe: " & error)

    # TODO: Add support for edge mode with Filter subscription management

  return ok()

proc unsubscribe*(
    self: SubscriptionService, topic: ContentTopic
): Result[void, string] =
  if self.node.wakuRelay.isNil() == false:
    self.node.unsubscribe((kind: ContentSub, topic: topic)).isOkOr:
      error "Failed to unsubscribe: ", error = error
      return err("Failed to unsubscribe: " & error)

  # TODO: Add support for edge mode with Filter subscription management
  return ok()
