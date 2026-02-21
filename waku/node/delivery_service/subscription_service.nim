import std/[sets, tables, options, strutils], chronos, chronicles, results
import
  waku/[
    waku_core,
    waku_core/topics,
    waku_core/topics/sharding,
    events/message_events,
    waku_node,
    waku_relay,
    common/broker/broker_context,
  ]

type SubscriptionService* = ref object of RootObj
  node: WakuNode
  shardSubs: HashSet[PubsubTopic]
  contentTopicSubs: Table[PubsubTopic, HashSet[ContentTopic]]
  relayHandler: WakuRelayHandler

proc new*(T: typedesc[SubscriptionService], node: WakuNode): T =
  let service = SubscriptionService(
    node: node,
    shardSubs: initHashSet[PubsubTopic](),
    contentTopicSubs: initTable[PubsubTopic, HashSet[ContentTopic]](),
  )

  service.relayHandler = proc(
      topic: PubsubTopic, msg: WakuMessage
  ) {.async.} =
    if not service.contentTopicSubs.hasKey(topic) or
        not service.contentTopicSubs[topic].contains(msg.contentTopic):
      return

    let msgHash = computeMessageHash(topic, msg).to0xHex()
    info "MessageReceivedEvent",
      pubsubTopic = topic, contentTopic = msg.contentTopic, msgHash = msgHash

    MessageReceivedEvent.emit(service.node.brokerCtx, msgHash, msg)

  return service

proc getShardForContentTopic(
    self: SubscriptionService, topic: ContentTopic
): Result[PubsubTopic, string] =
  if self.node.wakuAutoSharding.isSome():
    let shardObj = ?self.node.wakuAutoSharding.get().getShard(topic)
    return ok($shardObj)

  return
    err("Manual sharding is not supported in this API. Autosharding must be enabled.")

proc doSubscribe(self: SubscriptionService, shard: PubsubTopic): Result[void, string] =
  self.node.subscribe((kind: PubsubSub, topic: shard), self.relayHandler).isOkOr:
    error "Failed to subscribe to Relay shard", shard = shard, error = error
    return err("Failed to subscribe: " & error)
  return ok()

proc doUnsubscribe(
    self: SubscriptionService, shard: PubsubTopic
): Result[void, string] =
  self.node.unsubscribe((kind: PubsubUnsub, topic: shard)).isOkOr:
    error "Failed to unsubscribe from Relay shard", shard = shard, error = error
    return err("Failed to unsubscribe: " & error)
  return ok()

proc isSubscribed*(
    self: SubscriptionService, topic: ContentTopic
): Result[bool, string] =
  if self.node.wakuRelay.isNil():
    return err("SubscriptionService currently only supports Relay (Core) mode.")

  let shard = ?self.getShardForContentTopic(topic)

  if self.contentTopicSubs.hasKey(shard) and self.contentTopicSubs[shard].contains(
    topic
  ):
    return ok(true)

  return ok(false)

proc subscribe*(self: SubscriptionService, topic: ContentTopic): Result[void, string] =
  if self.node.wakuRelay.isNil():
    return err("SubscriptionService currently only supports Relay (Core) mode.")

  let shard = ?self.getShardForContentTopic(topic)

  let needShardSub =
    not self.shardSubs.contains(shard) and not self.contentTopicSubs.hasKey(shard)

  if needShardSub:
    ?self.doSubscribe(shard)

  self.contentTopicSubs.mgetOrPut(shard, initHashSet[ContentTopic]()).incl(topic)

  return ok()

proc unsubscribe*(
    self: SubscriptionService, topic: ContentTopic
): Result[void, string] =
  if self.node.wakuRelay.isNil():
    return err("SubscriptionService currently only supports Relay (Core) mode.")

  let shard = ?self.getShardForContentTopic(topic)

  if self.contentTopicSubs.hasKey(shard) and self.contentTopicSubs[shard].contains(
    topic
  ):
    let isLastTopic = self.contentTopicSubs[shard].len == 1
    let needShardUnsub = isLastTopic and not self.shardSubs.contains(shard)

    if needShardUnsub:
      ?self.doUnsubscribe(shard)

    self.contentTopicSubs[shard].excl(topic)
    if self.contentTopicSubs[shard].len == 0:
      self.contentTopicSubs.del(shard)

  return ok()

proc subscribeShard*(
    self: SubscriptionService, shards: seq[PubsubTopic]
): Result[void, string] =
  if self.node.wakuRelay.isNil():
    return err("SubscriptionService currently only supports Relay (Core) mode.")

  var errors: seq[string] = @[]

  for shard in shards:
    if not self.shardSubs.contains(shard):
      let needShardSub = not self.contentTopicSubs.hasKey(shard)

      if needShardSub:
        let res = self.doSubscribe(shard)
        if res.isErr():
          errors.add("Shard " & shard & " failed: " & res.error)
          continue

      self.shardSubs.incl(shard)

  if errors.len > 0:
    return err("Batch subscribe had errors: " & errors.join("; "))

  return ok()

proc unsubscribeShard*(
    self: SubscriptionService, shards: seq[PubsubTopic]
): Result[void, string] =
  if self.node.wakuRelay.isNil():
    return err("SubscriptionService currently only supports Relay (Core) mode.")

  var errors: seq[string] = @[]

  for shard in shards:
    if self.shardSubs.contains(shard):
      let needShardUnsub = not self.contentTopicSubs.hasKey(shard)

      if needShardUnsub:
        let res = self.doUnsubscribe(shard)
        if res.isErr():
          errors.add("Shard " & shard & " failed: " & res.error)
          continue

      self.shardSubs.excl(shard)

  if errors.len > 0:
    return err("Batch unsubscribe had errors: " & errors.join("; "))

  return ok()
