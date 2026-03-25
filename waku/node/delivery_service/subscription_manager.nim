import std/[sets, tables, options, strutils], chronos, chronicles, results
import libp2p/peerinfo
import
  waku/[
    waku_core,
    waku_core/topics,
    waku_core/topics/sharding,
    waku_node,
    waku_relay,
    common/broker/broker_context,
    events/peer_events,
    requests/delivery_requests,
    node/health_monitor/topic_health,
    node/health_monitor/connection_status,
  ]

type EdgeFilterSubState* = object
  peers*: seq[RemotePeerInfo]
    ## Filter service peers with confirmed subscriptions on this shard.
  pending*: seq[Future[void]]
    ## In-flight dial futures for peers not yet confirmed.
  currentHealth*: TopicHealth
    ## Cached health derived from peers.len; updated on every peer set change.

func toTopicHealth*(peersCount: int): TopicHealth =
  if peersCount >= HealthyThreshold:
    TopicHealth.SUFFICIENTLY_HEALTHY
  elif peersCount > 0:
    TopicHealth.MINIMALLY_HEALTHY
  else:
    TopicHealth.UNHEALTHY

type SubscriptionManager* = ref object of RootObj
  node*: WakuNode
  contentTopicSubs: Table[PubsubTopic, HashSet[ContentTopic]]
    ## Map of Shard to ContentTopic needed because e.g. WakuRelay is PubsubTopic only.
    ## A present key with an empty HashSet value means pubsubtopic already subscribed
    ## (via subscribePubsubTopics()) but there's no specific content topic interest yet.
  edgeFilterSubStates*: Table[PubsubTopic, EdgeFilterSubState]
    ## Per-shard filter subscription state for edge mode.
  edgeFilterWakeup*: AsyncEvent
    ## Signalled when the edge filter sub loop should re-reconcile.
  edgeFilterSubLoopFut*: Future[void]
  edgeFilterHealthLoopFut*: Future[void]
  peerEventListener*: WakuPeerEventListener
    ## Listener for peer connect/disconnect events (edge filter wakeup).

proc edgeFilterPeerCount*(sm: SubscriptionManager, shard: PubsubTopic): int =
  sm.edgeFilterSubStates.withValue(shard, state):
    return state.peers.len
  return 0

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

  if changed and not isNil(self.edgeFilterWakeup):
    self.edgeFilterWakeup.fire()

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

  if changed and not isNil(self.edgeFilterWakeup):
    self.edgeFilterWakeup.fire()

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

  if isNil(self.node.wakuRelay):
    return

  if self.node.wakuAutoSharding.isSome():
    # Core mode: auto-subscribe relay to all shards in autosharding.
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
