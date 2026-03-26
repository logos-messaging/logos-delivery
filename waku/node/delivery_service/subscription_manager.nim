import std/[sequtils, sets, tables, options, strutils], chronos, chronicles, results
import libp2p/[peerid, peerinfo]
import
  waku/[
    waku_core,
    waku_core/topics,
    waku_core/topics/sharding,
    waku_node,
    waku_relay,
    waku_filter_v2/common as filter_common,
    waku_filter_v2/client as filter_client,
    waku_filter_v2/protocol as filter_protocol,
    common/broker/broker_context,
    events/health_events,
    events/peer_events,
    requests/delivery_requests,
    node/peer_manager,
    node/health_monitor/topic_health,
    node/health_monitor/connection_status,
  ]

# ---------------------------------------------------------------------------
# LMAPI SubscriptionManager
#
# Maps all topic subscription intent and centralizes all consistency
# maintenance of the pubsub and content topic subscription model across
# the various network drivers that handle topics (Edge/Filter and Core/Relay).
# ---------------------------------------------------------------------------

type EdgeFilterSubState* = object
  peers*: seq[RemotePeerInfo]
    ## Filter service peers with confirmed subscriptions on this shard.
  pending*: seq[Future[void]] ## In-flight dial futures for peers not yet confirmed.
  pendingPeers*: HashSet[PeerId] ## PeerIds of peers currently being dialed.
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
  contentTopicSubs*: Table[PubsubTopic, HashSet[ContentTopic]]
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

# ---------------------------------------------------------------------------
# Edge Filter driver for the LMAPI
#
# The SubscriptionManager absorbs natively the responsibility of using the
# Edge Filter protocol to effect subscriptions and message receipt for edge.
# ---------------------------------------------------------------------------

const EdgeFilterSubscribeTimeout = chronos.seconds(15)
  ## Timeout for a single filter subscribe/unsubscribe RPC to a service peer.
const EdgeFilterPingTimeout = chronos.seconds(5)
  ## Timeout for a filter ping health check.
const EdgeFilterLoopInterval = chronos.seconds(30)
  ## Interval for the edge filter health loop and sub loop fallback wakeup.
const EdgeFilterSubLoopDebounce = chronos.seconds(1)
  ## Debounce delay to coalesce rapid-fire wakeups into a single reconciliation pass.

proc updateShardHealth(
    self: SubscriptionManager, shard: PubsubTopic, state: var EdgeFilterSubState
) =
  ## Recompute and emit health for a shard after its peer set changed.
  let newHealth = toTopicHealth(state.peers.len)
  if newHealth != state.currentHealth:
    state.currentHealth = newHealth
    EventShardTopicHealthChange.emit(self.node.brokerCtx, shard, newHealth)

proc removePeer(self: SubscriptionManager, shard: PubsubTopic, peerId: PeerId) =
  ## Remove a peer from edgeFilterSubStates for the given shard,
  ## update health, and wake the sub loop to dial a replacement.
  self.edgeFilterSubStates.withValue(shard, state):
    let oldLen = state.peers.len
    state.peers.keepItIf(it.peerId != peerId)
    if state.peers.len < oldLen:
      self.updateShardHealth(shard, state[])
      self.edgeFilterWakeup.fire()

proc syncFilterDeltas(
    self: SubscriptionManager,
    peer: RemotePeerInfo,
    shard: PubsubTopic,
    added: seq[ContentTopic],
    removed: seq[ContentTopic],
) {.async.} =
  ## Push content topic changes (adds/removes) to an already-tracked peer.
  try:
    var i = 0
    while i < added.len:
      let chunk =
        added[i ..< min(i + filter_protocol.MaxContentTopicsPerRequest, added.len)]
      let fut = self.node.wakuFilterClient.subscribe(peer, shard, chunk)
      if not (await fut.withTimeout(EdgeFilterSubscribeTimeout)) or fut.read().isErr():
        trace "syncFilterDeltas: subscribe chunk failed, removing peer",
          shard = shard, peer = peer.peerId
        self.removePeer(shard, peer.peerId)
        return
      i += filter_protocol.MaxContentTopicsPerRequest
  except CatchableError as exc:
    debug "syncFilterDeltas: subscribe failed, removing peer",
      shard = shard, peer = peer.peerId, err = exc.msg
    self.removePeer(shard, peer.peerId)
    return

  try:
    var i = 0
    while i < removed.len:
      let chunk =
        removed[i ..< min(i + filter_protocol.MaxContentTopicsPerRequest, removed.len)]
      let fut = self.node.wakuFilterClient.unsubscribe(peer, shard, chunk)
      if not (await fut.withTimeout(EdgeFilterSubscribeTimeout)) or fut.read().isErr():
        trace "syncFilterDeltas: unsubscribe chunk failed, removing peer",
          shard = shard, peer = peer.peerId
        self.removePeer(shard, peer.peerId)
        return
      i += filter_protocol.MaxContentTopicsPerRequest
  except CatchableError as exc:
    debug "syncFilterDeltas: unsubscribe failed, removing peer",
      shard = shard, peer = peer.peerId, err = exc.msg
    self.removePeer(shard, peer.peerId)

proc dialFilterPeer(
    self: SubscriptionManager,
    peer: RemotePeerInfo,
    shard: PubsubTopic,
    contentTopics: seq[ContentTopic],
) {.async.} =
  ## Subscribe a new peer to all content topics on a shard and start tracking it.
  self.edgeFilterSubStates.withValue(shard, state):
    state.pendingPeers.incl(peer.peerId)

  try:
    var i = 0

    while i < contentTopics.len:
      let chunk = contentTopics[
        i ..< min(i + filter_protocol.MaxContentTopicsPerRequest, contentTopics.len)
      ]
      let subFut = self.node.wakuFilterClient.subscribe(peer, shard, chunk)
      let ok = await subFut.withTimeout(EdgeFilterSubscribeTimeout)

      if not ok or subFut.read().isErr():
        debug "dialFilterPeer: chunk subscribe failed or timed out",
          shard = shard, peer = peer.peerId, ok = ok
        return

      i += filter_protocol.MaxContentTopicsPerRequest

    self.edgeFilterSubStates.withValue(shard, state):
      if state.peers.anyIt(it.peerId == peer.peerId):
        trace "dialFilterPeer: peer already tracked, skipping duplicate",
          shard = shard, peer = peer.peerId
        return

      state.peers.add(peer)
      self.updateShardHealth(shard, state[])
      trace "dialFilterPeer: successfully subscribed to all chunks",
        shard = shard, peer = peer.peerId, totalPeers = state.peers.len
    do:
      trace "dialFilterPeer: shard removed while subscribing, discarding result",
        shard = shard, peer = peer.peerId
  except CatchableError as exc:
    debug "dialFilterPeer failed", err = exc.msg
  finally:
    self.edgeFilterSubStates.withValue(shard, state):
      state.pendingPeers.excl(peer.peerId)

proc edgeFilterHealthLoop*(self: SubscriptionManager) {.async.} =
  ## Periodically pings all connected filter service peers to verify they are
  ## still alive at the application layer. Peers that fail the ping are removed.
  while true:
    await sleepAsync(EdgeFilterLoopInterval)

    if self.node.wakuFilterClient.isNil():
      continue

    var connected = initTable[PeerId, RemotePeerInfo]()
    for state in self.edgeFilterSubStates.values:
      for peer in state.peers:
        if self.node.peerManager.switch.peerStore.isConnected(peer.peerId):
          connected[peer.peerId] = peer

    var alive = initHashSet[PeerId]()

    if connected.len > 0:
      var pingTasks: seq[(PeerId, Future[FilterSubscribeResult])] = @[]
      for peer in connected.values:
        pingTasks.add(
          (peer.peerId, self.node.wakuFilterClient.ping(peer, EdgeFilterPingTimeout))
        )

      # extract future tasks from (PeerId, Future) tuples and await them
      await allFutures(pingTasks.mapIt(it[1]))

      for (peerId, task) in pingTasks:
        if task.read().isOk():
          alive.incl(peerId)

    var changed = false
    for shard, state in self.edgeFilterSubStates.mpairs:
      let oldLen = state.peers.len
      state.peers.keepItIf(it.peerId notin connected or alive.contains(it.peerId))

      if state.peers.len < oldLen:
        changed = true
        self.updateShardHealth(shard, state)
        trace "Edge Filter health degraded by Ping failure",
          shard = shard, new = state.currentHealth

    if changed:
      self.edgeFilterWakeup.fire()

proc edgeFilterSubLoop*(self: SubscriptionManager) {.async.} =
  ## Reconciles filter subscriptions with the desired state from SubscriptionManager.
  var lastSynced = initTable[PubsubTopic, HashSet[ContentTopic]]()

  while true:
    discard await self.edgeFilterWakeup.wait().withTimeout(EdgeFilterLoopInterval)
    await sleepAsync(EdgeFilterSubLoopDebounce)
    self.edgeFilterWakeup.clear()
    trace "edgeFilterSubLoop: woke up"

    if isNil(self.node.wakuFilterClient):
      trace "edgeFilterSubLoop: wakuFilterClient is nil, skipping"
      continue

    let desired = self.contentTopicSubs

    trace "edgeFilterSubLoop: desired state", numShards = desired.len

    let allShards = toHashSet(toSeq(desired.keys)) + toHashSet(toSeq(lastSynced.keys))

    for shard in allShards:
      let currTopics = desired.getOrDefault(shard)
      let prevTopics = lastSynced.getOrDefault(shard)

      if shard notin self.edgeFilterSubStates:
        self.edgeFilterSubStates[shard] =
          EdgeFilterSubState(currentHealth: TopicHealth.UNHEALTHY)

      let addedTopics = toSeq(currTopics - prevTopics)
      let removedTopics = toSeq(prevTopics - currTopics)

      self.edgeFilterSubStates.withValue(shard, state):
        state.peers.keepItIf(
          self.node.peerManager.switch.peerStore.isConnected(it.peerId)
        )
        state.pending.keepItIf(not it.finished)

        if addedTopics.len > 0 or removedTopics.len > 0:
          for peer in state.peers:
            asyncSpawn self.syncFilterDeltas(peer, shard, addedTopics, removedTopics)

        if currTopics.len == 0:
          for fut in state.pending:
            if not fut.finished:
              await fut.cancelAndWait()
          self.edgeFilterSubStates.del(shard)
            # invalidates `state` — do not use after this
        else:
          self.updateShardHealth(shard, state[])

          let needed = max(0, HealthyThreshold - state.peers.len - state.pending.len)

          if needed > 0:
            let tracked = state.peers.mapIt(it.peerId).toHashSet() + state.pendingPeers
            var candidates = self.node.peerManager.selectPeers(
              filter_common.WakuFilterSubscribeCodec, some(shard)
            )
            candidates.keepItIf(it.peerId notin tracked)

            let toDial = min(needed, candidates.len)

            trace "edgeFilterSubLoop: shard reconciliation",
              shard = shard,
              peers = state.peers.len,
              pending = state.pending.len,
              needed = needed,
              available = candidates.len,
              toDial = toDial

            for i in 0 ..< toDial:
              let fut = self.dialFilterPeer(candidates[i], shard, toSeq(currTopics))
              state.pending.add(fut)

    lastSynced = desired

proc startEdgeFilterLoops*(self: SubscriptionManager): Result[void, string] =
  ## Start the edge filter orchestration loops.
  ## Caller must ensure this is only called in edge mode (relay nil, filter client present).
  self.edgeFilterWakeup = newAsyncEvent()

  self.peerEventListener = WakuPeerEvent.listen(
    self.node.brokerCtx,
    proc(evt: WakuPeerEvent) {.async: (raises: []), gcsafe.} =
      if evt.kind == WakuPeerEventKind.EventDisconnected or
          evt.kind == WakuPeerEventKind.EventMetadataUpdated:
        self.edgeFilterWakeup.fire()
    ,
  ).valueOr:
    return err("Failed to listen to peer events for edge filter: " & error)

  self.edgeFilterSubLoopFut = self.edgeFilterSubLoop()
  self.edgeFilterHealthLoopFut = self.edgeFilterHealthLoop()
  return ok()

proc stopEdgeFilterLoops*(self: SubscriptionManager) {.async.} =
  ## Stop the edge filter orchestration loops and clean up pending futures.
  if not isNil(self.edgeFilterSubLoopFut):
    await self.edgeFilterSubLoopFut.cancelAndWait()
    self.edgeFilterSubLoopFut = nil

  if not isNil(self.edgeFilterHealthLoopFut):
    await self.edgeFilterHealthLoopFut.cancelAndWait()
    self.edgeFilterHealthLoopFut = nil

  for shard, state in self.edgeFilterSubStates:
    for fut in state.pending:
      if not fut.finished:
        await fut.cancelAndWait()

  WakuPeerEvent.dropListener(self.node.brokerCtx, self.peerEventListener)
