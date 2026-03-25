import std/[sets, tables, options, strutils], chronos, chronicles, results
import
  waku/[
    waku_core,
    waku_core/topics,
    waku_core/topics/sharding,
    waku_node,
    waku_relay,
    common/broker/broker_context,
    events/delivery_events,
    requests/delivery_requests,
  ]

type SubscriptionManager* = ref object of RootObj
  node: WakuNode
  contentTopicSubs: Table[PubsubTopic, HashSet[ContentTopic]]
    ## Map of Shard to ContentTopic needed because e.g. WakuRelay is PubsubTopic only.
    ## A present key with an empty HashSet value means pubsubtopic already subscribed
    ## (via subscribePubsubTopics()) but there's no specific content topic interest yet.
  filterSubListener: OnFilterSubscribeEventListener
    ## Broker-generated listener for OnFilterSubscribeEvent (emitted by WakuFilterClient).
  filterUnsubListener: OnFilterUnSubscribeEventListener
    ## Broker-generated listener for OnFilterUnSubscribeEvent (emitted by WakuFilterClient).
  relaySubListener: OnRelaySubscribeEventListener
    ## Broker-generated listener for OnRelaySubscribeEvent (emitted by WakuRelay).
  relayUnsubListener: OnRelayUnsubscribeEventListener
    ## Broker-generated listener for OnRelayUnsubscribeEvent (emitted by WakuRelay).

proc new*(T: typedesc[SubscriptionManager], node: WakuNode): T =
  SubscriptionManager(
    node: node, contentTopicSubs: initTable[PubsubTopic, HashSet[ContentTopic]]()
  )

proc addContentTopicInterest(
    self: SubscriptionManager, shard: PubsubTopic, topic: ContentTopic
): Result[void, string] =
  var changed = false
  if not self.contentTopicSubs.hasKey(shard):
    self.contentTopicSubs[shard] = initHashSet[ContentTopic]()
    changed = true

  self.contentTopicSubs.withValue(shard, cTopics):
    if not cTopics[].contains(topic):
      cTopics[].incl(topic)
      changed = true

  if changed:
    self.node.notifySubscriptionsChanged()

  return ok()

proc removeContentTopicInterest(
    self: SubscriptionManager, shard: PubsubTopic, topic: ContentTopic
): Result[void, string] =
  var changed = false
  self.contentTopicSubs.withValue(shard, cTopics):
    if cTopics[].contains(topic):
      cTopics[].excl(topic)
      changed = true

      if cTopics[].len == 0 and isNil(self.node.wakuRelay):
        self.contentTopicSubs.del(shard) # We're done with cTopics here

  if changed:
    self.node.notifySubscriptionsChanged()

  return ok()

proc subscribePubsubTopics(
    self: SubscriptionManager, shards: seq[PubsubTopic]
): Result[void, string] =
  if isNil(self.node.wakuRelay):
    return err("subscribePubsubTopics requires a Relay")

  var errors: seq[string] = @[]

  for shard in shards:
    if not self.contentTopicSubs.hasKey(shard):
      self.node.subscribe((kind: PubsubSub, topic: shard), nil).isOkOr:
        errors.add("shard " & shard & ": " & error)
        continue

      self.contentTopicSubs[shard] = initHashSet[ContentTopic]()

  if errors.len > 0:
    return err("subscribeShard errors: " & errors.join("; "))

  return ok()

proc getActiveSubscriptions*(
    self: SubscriptionManager
): seq[tuple[pubsubTopic: string, contentTopics: seq[ContentTopic]]] =
  var activeSubs: seq[tuple[pubsubTopic: string, contentTopics: seq[ContentTopic]]] =
    @[]

  for pubsub, cTopicSet in self.contentTopicSubs.pairs:
    if cTopicSet.len > 0:
      var cTopicSeq = newSeqOfCap[ContentTopic](cTopicSet.len)
      for t in cTopicSet:
        cTopicSeq.add(t)
      activeSubs.add((pubsub, cTopicSeq))

  return activeSubs

proc startSubscriptionManager*(self: SubscriptionManager) =
  RequestActiveSubscriptions.setProvider(
    self.node.brokerCtx,
    proc(): Result[RequestActiveSubscriptions, string] =
      return ok(RequestActiveSubscriptions(activeSubs: self.getActiveSubscriptions())),
  ).isOkOr:
    error "Failed to set provider for RequestActiveSubscriptions", error = error

  self.filterSubListener = OnFilterSubscribeEvent.listen(
    self.node.brokerCtx,
    proc(evt: OnFilterSubscribeEvent): Future[void] {.async: (raises: []), gcsafe.} =
      for topic in evt.contentTopics:
        discard self.addContentTopicInterest(evt.pubsubTopic, topic),
  ).valueOr:
    error "Failed to listen to OnFilterSubscribeEvent: ", error = error
    return

  self.filterUnsubListener = OnFilterUnSubscribeEvent.listen(
    self.node.brokerCtx,
    proc(evt: OnFilterUnSubscribeEvent): Future[void] {.async: (raises: []), gcsafe.} =
      for topic in evt.contentTopics:
        discard self.removeContentTopicInterest(evt.pubsubTopic, topic),
  ).valueOr:
    error "Failed to listen to OnFilterUnSubscribeEvent: ", error = error
    return

  self.relaySubListener = OnRelaySubscribeEvent.listen(
    self.node.brokerCtx,
    proc(evt: OnRelaySubscribeEvent): Future[void] {.async: (raises: []), gcsafe.} =
      if not self.contentTopicSubs.hasKey(evt.pubsubTopic):
        self.contentTopicSubs[evt.pubsubTopic] = initHashSet[ContentTopic]()
    ,
  ).valueOr:
    error "Failed to listen to OnRelaySubscribeEvent: ", error = error
    return

  self.relayUnsubListener = OnRelayUnsubscribeEvent.listen(
    self.node.brokerCtx,
    proc(evt: OnRelayUnsubscribeEvent): Future[void] {.async: (raises: []), gcsafe.} =
      self.contentTopicSubs.del(evt.pubsubTopic),
  ).valueOr:
    error "Failed to listen to OnRelayUnsubscribeEvent: ", error = error
    return

  if isNil(self.node.wakuRelay):
    return

  if self.node.wakuAutoSharding.isSome():
    # Subscribe relay to all shards in autosharding.
    let autoSharding = self.node.wakuAutoSharding.get()
    let clusterId = autoSharding.clusterId
    let numShards = autoSharding.shardCountGenZero

    if numShards > 0:
      var clusterPubsubTopics = newSeqOfCap[PubsubTopic](numShards)

      for i in 0 ..< numShards:
        let shardObj = RelayShard(clusterId: clusterId, shardId: uint16(i))
        clusterPubsubTopics.add(PubsubTopic($shardObj))

      self.subscribePubsubTopics(clusterPubsubTopics).isOkOr:
        error "Failed to auto-subscribe Relay to cluster shards: ", error = error
  else:
    info "SubscriptionManager has no AutoSharding configured; skipping auto-subscribe."

proc stopSubscriptionManager*(self: SubscriptionManager) {.async.} =
  OnFilterSubscribeEvent.dropListener(self.node.brokerCtx, self.filterSubListener)
  OnFilterUnSubscribeEvent.dropListener(self.node.brokerCtx, self.filterUnsubListener)
  OnRelaySubscribeEvent.dropListener(self.node.brokerCtx, self.relaySubListener)
  OnRelayUnsubscribeEvent.dropListener(self.node.brokerCtx, self.relayUnsubListener)
  RequestActiveSubscriptions.clearProvider(self.node.brokerCtx)

proc getShardForContentTopic(
    self: SubscriptionManager, topic: ContentTopic
): Result[PubsubTopic, string] =
  if self.node.wakuAutoSharding.isSome():
    let shardObj = ?self.node.wakuAutoSharding.get().getShard(topic)
    return ok($shardObj)

  return err("SubscriptionManager requires AutoSharding")

proc isSubscribed*(
    self: SubscriptionManager, topic: ContentTopic
): Result[bool, string] =
  let shard = ?self.getShardForContentTopic(topic)
  return ok(
    self.contentTopicSubs.hasKey(shard) and self.contentTopicSubs[shard].contains(topic)
  )

proc isSubscribed*(
    self: SubscriptionManager, shard: PubsubTopic, contentTopic: ContentTopic
): bool {.raises: [].} =
  self.contentTopicSubs.withValue(shard, cTopics):
    return cTopics[].contains(contentTopic)
  return false

proc subscribe*(self: SubscriptionManager, topic: ContentTopic): Result[void, string] =
  if isNil(self.node.wakuRelay) and isNil(self.node.wakuFilterClient):
    return err("SubscriptionManager requires either Relay or Filter Client.")

  let shard = ?self.getShardForContentTopic(topic)

  if not isNil(self.node.wakuRelay) and not self.contentTopicSubs.hasKey(shard):
    ?self.subscribePubsubTopics(@[shard])

  ?self.addContentTopicInterest(shard, topic)

  return ok()

proc unsubscribe*(
    self: SubscriptionManager, topic: ContentTopic
): Result[void, string] =
  if isNil(self.node.wakuRelay) and isNil(self.node.wakuFilterClient):
    return err("SubscriptionManager requires either Relay or Filter Client.")

  let shard = ?self.getShardForContentTopic(topic)

  if self.isSubscribed(shard, topic):
    ?self.removeContentTopicInterest(shard, topic)

  return ok()
