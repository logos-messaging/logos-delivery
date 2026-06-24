import logos_delivery/waku/compat/option_valueor
import std/[sequtils, sets, tables, options], chronos, chronicles, metrics, results
import libp2p/[peerid, peerinfo]
import brokers/broker_context

import
  logos_delivery/waku/[
    waku_core,
    waku_core/topics/sharding,
    node/waku_node,
    node/node_telemetry,
    waku_relay,
    waku_archive,
    waku_mix,
    waku_store_sync,
    waku_filter_v2/common as filter_common,
    waku_filter_v2/client as filter_client,
    waku_filter_v2/protocol as filter_protocol,
    events/health_events,
    events/message_events,
    events/peer_events,
    requests/health_requests,
    node/peer_manager,
    node/health_monitor/topic_health,
    node/health_monitor/connection_status,
  ]

{.push raises: [].}

proc registerRelayHandler(
    node: WakuNode, shard: PubsubTopic, appHandler: WakuRelayHandler = nil
): bool =
  ## Returns true iff we did a new (and only) subscription for this shard in GossipSub.
  let alreadySubscribed = node.wakuRelay.isSubscribed(shard)

  if not appHandler.isNil():
    if not alreadySubscribed or not node.legacyAppHandlers.hasKey(shard):
      node.legacyAppHandlers[shard] = appHandler
    else:
      debug "Legacy appHandler already exists for active shard, ignoring new handler",
        shard

  if alreadySubscribed:
    return false

  proc traceHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    let msgSizeKB = msg.payload.len / 1000

    waku_node_messages.inc(labelValues = ["relay"])
    waku_histogram_message_size.observe(msgSizeKB)

  proc filterHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuFilter.isNil():
      return

    await node.wakuFilter.handleMessage(topic, msg)

  proc archiveHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuArchive.isNil():
      return

    await node.wakuArchive.handleMessage(topic, msg)

  proc syncHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuStoreReconciliation.isNil():
      return

    node.wakuStoreReconciliation.messageIngress(topic, msg)

  proc mixHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuMix.isNil():
      return

    await node.wakuMix.handleMessage(topic, msg)

  proc internalHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    MessageSeenEvent.emit(node.brokerCtx, topic, msg)

  let uniqueTopicHandler = proc(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    await traceHandler(topic, msg)
    await filterHandler(topic, msg)
    await archiveHandler(topic, msg)
    await syncHandler(topic, msg)
    await mixHandler(topic, msg)
    await internalHandler(topic, msg)

    if node.legacyAppHandlers.hasKey(topic) and not node.legacyAppHandlers[topic].isNil():
      await node.legacyAppHandlers[topic](topic, msg)

  node.wakuRelay.subscribe(shard, uniqueTopicHandler)
  return true

proc unregisterRelayHandler(node: WakuNode, shard: PubsubTopic): bool =
  ## Returns true iff we had a subscription for this shard in GossipSub and it was removed.
  if node.legacyAppHandlers.hasKey(shard):
    node.legacyAppHandlers.del(shard)

  if node.wakuRelay.isSubscribed(shard):
    node.wakuRelay.unsubscribe(shard)
    return true
  return false

proc doRelaySubscribe(
    node: WakuNode, shard: PubsubTopic, appHandler: WakuRelayHandler = nil
): bool =
  ## Subscribes the node to a shard.
  ## Returns true if we actually subscribed (transitioned from unsubscribed to subscribed).
  ## Emit the shard subscription event if we actually subscribed.
  let installed = node.registerRelayHandler(shard, appHandler)
  if installed:
    node.topicSubscriptionQueue.emit((kind: PubsubSub, topic: shard))
  return installed

proc doRelayUnsubscribe(node: WakuNode, shard: PubsubTopic): bool =
  ## Unsubscribes the node from a shard.
  ## Returns true if we actually unsubscribed (transitioned from subscribed to unsubscribed).
  ## Emit the shard unsubscription event if we actually unsubscribed.
  let unsubscribed = node.unregisterRelayHandler(shard)
  if unsubscribed:
    node.topicSubscriptionQueue.emit((kind: PubsubUnsub, topic: shard))
  return unsubscribed

proc new*(T: type SubscriptionManager, node: WakuNode): T =
  T(
    node: node,
    shards: initTable[PubsubTopic, ShardSubscription](),
    edgeFilterSubStates: initTable[PubsubTopic, EdgeFilterSubState](),
    edgeFilterWakeup: newAsyncEvent(),
  )

func wanted(entry: ShardSubscription): bool =
  ## True if the shard has content-topic interest or a direct subscription.
  return entry.contentTopics.len > 0 or entry.directShardSub

proc isContentSubscribed*(
    self: SubscriptionManager, shard: PubsubTopic, contentTopic: ContentTopic
): bool =
  self.shards.withValue(shard, sub):
    return contentTopic in sub.contentTopics
  return false

iterator subscribedContentTopics*(
    self: SubscriptionManager
): (PubsubTopic, HashSet[ContentTopic]) =
  ## Yields each shard with its non-empty content-topic set.
  for shard, sub in self.shards.pairs:
    if sub.contentTopics.len > 0:
      yield (shard, sub.contentTopics)

func toTopicHealth*(peersCount: int): TopicHealth =
  if peersCount >= HealthyThreshold:
    return TopicHealth.SUFFICIENTLY_HEALTHY
  elif peersCount > 0:
    return TopicHealth.MINIMALLY_HEALTHY
  else:
    return TopicHealth.UNHEALTHY

proc edgeFilterPeerCount*(self: SubscriptionManager, shard: PubsubTopic): int =
  self.edgeFilterSubStates.withValue(shard, state):
    return state.peers.len
  return 0

proc getShardForContentTopic(
    self: SubscriptionManager, topic: ContentTopic
): Result[PubsubTopic, string] =
  if self.node.wakuAutoSharding.isSome():
    let shardObj = ?self.node.wakuAutoSharding.get().getShard(topic)
    return ok($shardObj)

  return err("autosharding is not configured; pass an explicit shard")

proc subscribeShard*(
    self: SubscriptionManager, shard: PubsubTopic, handler: WakuRelayHandler = nil
): Result[void, string] =
  ## Subscribes to the shard directly and joins the relay mesh.
  var added = false
  self.shards.withValue(shard, entry):
    if not entry.directShardSub:
      entry.directShardSub = true
      added = true
  do:
    self.shards[shard] = ShardSubscription(
      contentTopics: initHashSet[ContentTopic](), directShardSub: true
    )
    added = true
  if added:
    self.edgeFilterWakeup.fire()
  if not isNil(self.node.wakuRelay):
    discard self.node.doRelaySubscribe(shard, handler)
  return ok()

proc unsubscribeShard*(
    self: SubscriptionManager, shard: PubsubTopic
): Result[void, string] =
  ## Drops the direct shard subscription; unsubscribes the mesh if no content topic wants it.
  var removed = false
  var shardEmpty = false
  self.shards.withValue(shard, entry):
    if entry.directShardSub:
      entry.directShardSub = false
      removed = true
      shardEmpty = not entry[].wanted()
  if removed:
    self.edgeFilterWakeup.fire()
    if shardEmpty:
      self.shards.del(shard)
      if not isNil(self.node.wakuRelay):
        discard self.node.doRelayUnsubscribe(shard)
  return ok()

proc subscribe*(
    self: SubscriptionManager,
    shard: PubsubTopic,
    contentTopic: ContentTopic,
    handler: WakuRelayHandler = nil,
): Result[void, string] =
  ## Adds content-topic interest on the shard and joins the relay mesh.
  var added = false
  self.shards.withValue(shard, entry):
    if contentTopic notin entry.contentTopics:
      entry.contentTopics.incl(contentTopic)
      added = true
  do:
    var entry = ShardSubscription(contentTopics: initHashSet[ContentTopic]())
    entry.contentTopics.incl(contentTopic)
    self.shards[shard] = entry
    added = true
  if added:
    self.edgeFilterWakeup.fire()
  if not isNil(self.node.wakuRelay):
    discard self.node.doRelaySubscribe(shard, handler)
  return ok()

proc unsubscribe*(
    self: SubscriptionManager, shard: PubsubTopic, contentTopic: ContentTopic
): Result[void, string] =
  ## Drops content-topic interest on the shard; unsubscribes the mesh if nothing else wants it.
  var removed = false
  var shardEmpty = false
  self.shards.withValue(shard, entry):
    if contentTopic in entry.contentTopics:
      entry.contentTopics.excl(contentTopic)
      removed = true
      shardEmpty = not entry[].wanted()
  if removed:
    self.edgeFilterWakeup.fire()
    if shardEmpty:
      self.shards.del(shard)
      if not isNil(self.node.wakuRelay):
        discard self.node.doRelayUnsubscribe(shard)
  return ok()

proc subscribe*(self: SubscriptionManager, topic: ContentTopic): Result[void, string] =
  ## Subscribes to a content topic, resolving its shard via autosharding.
  let shard = ?self.getShardForContentTopic(topic)
  return self.subscribe(shard, topic)

proc unsubscribe*(
    self: SubscriptionManager, topic: ContentTopic
): Result[void, string] =
  ## Unsubscribes from a content topic, resolving its shard via autosharding.
  let shard = ?self.getShardForContentTopic(topic)
  return self.unsubscribe(shard, topic)

proc unsubscribeAll*(
    self: SubscriptionManager, shard: PubsubTopic
): Result[void, string] =
  ## Drops every content topic on the shard, then the direct subscription.
  var snapshot: seq[ContentTopic]
  self.shards.withValue(shard, sub):
    snapshot = toSeq(sub.contentTopics)
  for contentTopic in snapshot:
    ?self.unsubscribe(shard, contentTopic)
  return self.unsubscribeShard(shard)

proc isSubscribed*(
    self: SubscriptionManager, topic: ContentTopic
): Result[bool, string] =
  let shard = ?self.getShardForContentTopic(topic)
  return ok(self.isContentSubscribed(shard, topic))

proc subscribeAllAutoshards*(self: SubscriptionManager): Result[void, string] =
  ## Subscribes the relay to every shard in the configured autosharding cluster.
  if self.node.wakuRelay.isNil() or self.node.wakuAutoSharding.isNone():
    return ok()

  let autoSharding = self.node.wakuAutoSharding.get()
  let numShards = autoSharding.shardCountGenZero
  if numShards == 0:
    return ok()

  for i in 0'u32 ..< numShards:
    let shardObj = RelayShard(clusterId: autoSharding.clusterId, shardId: uint16(i))
    self.subscribeShard(PubsubTopic($shardObj)).isOkOr:
      error "failed to auto-subscribe relay to cluster shard",
        shard = $shardObj, error = error

  ok()

{.pop.}

const EdgeFilterSubscribeTimeout = chronos.seconds(15)
  ## Timeout for a single filter subscribe/unsubscribe RPC to a service peer.
const EdgeFilterPingTimeout = chronos.seconds(5)
  ## Timeout for a filter ping health check.
const EdgeFilterLoopInterval = chronos.seconds(30)
  ## Interval for the edge filter health ping loop.
const EdgeFilterSubLoopDebounce = chronos.seconds(1)
  ## Debounce delay to coalesce rapid-fire wakeups into a single reconciliation pass.

type EdgeFilterSubscribeTask = object
  peer: RemotePeerInfo
  shard: PubsubTopic
  topics: seq[ContentTopic]

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
  ## update health, and wake the sub loop to filter-subscribe a replacement.
  ## Best-effort unsubscribe so the service peer stops pushing to us.
  self.edgeFilterSubStates.withValue(shard, state):
    var idx = -1
    for i, p in state.peers:
      if p.peerId == peerId:
        idx = i
        break
    if idx < 0:
      return

    let peer = state.peers[idx]
    state.peers.del(idx)
    self.updateShardHealth(shard, state[])
    self.edgeFilterWakeup.fire()

    if not self.node.wakuFilterClient.isNil():
      self.shards.withValue(shard, sub):
        let ct = toSeq(sub.contentTopics)
        if ct.len > 0:
          proc doUnsubscribe() {.async.} =
            discard await self.node.wakuFilterClient.unsubscribe(peer, shard, ct)

          asyncSpawn doUnsubscribe()

type SendChunkedFilterRpcKind = enum
  FilterSubscribe
  FilterUnsubscribe

proc sendChunkedFilterRpc(
    self: SubscriptionManager,
    peer: RemotePeerInfo,
    shard: PubsubTopic,
    topics: seq[ContentTopic],
    kind: SendChunkedFilterRpcKind,
): Future[bool] {.async.} =
  ## Send a chunked filter subscribe or unsubscribe RPC. Returns true on
  ## success. On failure the peer is removed and false is returned.
  try:
    var i = 0
    while i < topics.len:
      let chunk =
        topics[i ..< min(i + filter_protocol.MaxContentTopicsPerRequest, topics.len)]
      let fut =
        case kind
        of FilterSubscribe:
          self.node.wakuFilterClient.subscribe(peer, shard, chunk)
        of FilterUnsubscribe:
          self.node.wakuFilterClient.unsubscribe(peer, shard, chunk)
      if not (await fut.withTimeout(EdgeFilterSubscribeTimeout)) or fut.read().isErr():
        trace "sendChunkedFilterRpc: chunk failed",
          op = kind, shard = shard, peer = peer.peerId
        self.removePeer(shard, peer.peerId)
        return false
      i += filter_protocol.MaxContentTopicsPerRequest
  except CatchableError as exc:
    debug "sendChunkedFilterRpc: failed",
      op = kind, shard = shard, peer = peer.peerId, err = exc.msg
    self.removePeer(shard, peer.peerId)
    return false
  return true

proc syncFilterDeltas(
    self: SubscriptionManager,
    peer: RemotePeerInfo,
    shard: PubsubTopic,
    added: seq[ContentTopic],
    removed: seq[ContentTopic],
) {.async.} =
  ## Push content topic changes (adds/removes) to an already-tracked peer.
  if added.len > 0:
    if not await self.sendChunkedFilterRpc(peer, shard, added, FilterSubscribe):
      return

  if removed.len > 0:
    discard await self.sendChunkedFilterRpc(peer, shard, removed, FilterUnsubscribe)

proc subscribeFilterPeer(
    self: SubscriptionManager,
    peer: RemotePeerInfo,
    shard: PubsubTopic,
    contentTopics: seq[ContentTopic],
) {.async.} =
  ## Filter-subscribe to a service peer for all content topics on a shard and
  ## start tracking it (note that the filter client dials the peer if not connected).
  self.edgeFilterSubStates.withValue(shard, state):
    state.pendingPeers.incl(peer.peerId)

  try:
    if not await self.sendChunkedFilterRpc(peer, shard, contentTopics, FilterSubscribe):
      return

    self.edgeFilterSubStates.withValue(shard, state):
      if state.peers.anyIt(it.peerId == peer.peerId):
        trace "subscribeFilterPeer: peer already tracked, skipping duplicate",
          shard = shard, peer = peer.peerId
        return

      state.peers.add(peer)
      self.updateShardHealth(shard, state[])
      trace "subscribeFilterPeer: successfully subscribed to all chunks",
        shard = shard, peer = peer.peerId, totalPeers = state.peers.len
    do:
      trace "subscribeFilterPeer: shard removed while subscribing, discarding result",
        shard = shard, peer = peer.peerId
  finally:
    self.edgeFilterSubStates.withValue(shard, state):
      state.pendingPeers.excl(peer.peerId)

proc edgeFilterConnectionLoop(self: SubscriptionManager) {.async.} =
  ## Periodically pings all tracked filter service peers to verify they are
  ## still alive at the application layer. Peers that fail the ping are removed.
  while true:
    await sleepAsync(EdgeFilterLoopInterval)

    if self.node.wakuFilterClient.isNil():
      warn "filter client is nil within edge filter connection loop"
      continue

    var connected = initTable[PeerId, RemotePeerInfo]()
    for state in self.edgeFilterSubStates.values:
      for peer in state.peers:
        if self.node.peerManager.switch.peerStore.isConnected(peer.peerId):
          connected[peer.peerId] = peer

    var alive = initHashSet[PeerId]()

    if connected.len > 0:
      var pingTasks: seq[(PeerId, Future[FilterSubscribeResult])]
      for peer in connected.values:
        pingTasks.add(
          (peer.peerId, self.node.wakuFilterClient.ping(peer, EdgeFilterPingTimeout))
        )

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

proc selectFilterCandidates(
    self: SubscriptionManager, shard: PubsubTopic, exclude: HashSet[PeerId], needed: int
): seq[RemotePeerInfo] =
  ## Select filter service peer candidates for a shard.

  # Start with every filter server peer that can serve the shard
  var allCandidates = self.node.peerManager.selectPeers(
    filter_common.WakuFilterSubscribeCodec, some(shard)
  )

  # Remove all already used in this shard or being filter-subscribed for it
  allCandidates.keepItIf(it.peerId notin exclude)

  # Collect peer IDs already tracked on other shards
  var trackedOnOther = initHashSet[PeerId]()
  for otherShard, otherState in self.edgeFilterSubStates.pairs:
    if otherShard != shard:
      for peer in otherState.peers:
        trackedOnOther.incl(peer.peerId)

  # Prefer peers we already have a connection to first, preserving shuffle
  var candidates =
    allCandidates.filterIt(it.peerId in trackedOnOther) &
    allCandidates.filterIt(it.peerId notin trackedOnOther)

  # We need to return 'needed' peers only
  if candidates.len > needed:
    candidates.setLen(needed)
  return candidates

proc edgeFilterSubLoop(self: SubscriptionManager) {.async.} =
  ## Reconciles filter subscriptions with the desired state from SubscriptionManager.
  var lastSynced = initTable[PubsubTopic, HashSet[ContentTopic]]()

  while true:
    await self.edgeFilterWakeup.wait()
    await sleepAsync(EdgeFilterSubLoopDebounce)
    self.edgeFilterWakeup.clear()
    trace "edgeFilterSubLoop: woke up"

    if isNil(self.node.wakuFilterClient):
      trace "edgeFilterSubLoop: wakuFilterClient is nil, skipping"
      continue

    var newSynced = initTable[PubsubTopic, HashSet[ContentTopic]]()
    var allShards: HashSet[PubsubTopic]
    for shard, sub in self.shards.pairs:
      if sub.contentTopics.len > 0:
        newSynced[shard] = sub.contentTopics
        allShards.incl(shard)
    for shard in lastSynced.keys:
      allShards.incl(shard)

    trace "edgeFilterSubLoop: desired state", numShards = newSynced.len

    # Step 1: read state across all shards at once and
    # create a list of peer filter-subscribe tasks and shard tracking to delete.

    var subscribeTasks: seq[EdgeFilterSubscribeTask]
    var shardsToDelete: seq[PubsubTopic]

    for shard in allShards:
      # Compute added/removed deltas via direct iteration; no HashSet copies.
      var addedTopics: seq[ContentTopic]
      var removedTopics: seq[ContentTopic]
      newSynced.withValue(shard, curr):
        lastSynced.withValue(shard, prev):
          for t in curr[]:
            if t notin prev[]:
              addedTopics.add(t)
          for t in prev[]:
            if t notin curr[]:
              removedTopics.add(t)
        do:
          for t in curr[]:
            addedTopics.add(t)
      do:
        lastSynced.withValue(shard, prev):
          for t in prev[]:
            removedTopics.add(t)

      discard self.edgeFilterSubStates.mgetOrPut(
        shard, EdgeFilterSubState(currentHealth: TopicHealth.UNHEALTHY)
      )

      self.edgeFilterSubStates.withValue(shard, state):
        state.peers.keepItIf(
          self.node.peerManager.switch.peerStore.isConnected(it.peerId)
        )
        state.pending.keepItIf(not it.finished)

        if addedTopics.len > 0 or removedTopics.len > 0:
          for peer in state.peers:
            asyncSpawn self.syncFilterDeltas(peer, shard, addedTopics, removedTopics)

        if shard notin newSynced:
          shardsToDelete.add(shard)
        else:
          self.updateShardHealth(shard, state[])

          let needed = max(0, HealthyThreshold - state.peers.len - state.pending.len)

          if needed > 0:
            var tracked: HashSet[PeerId]
            for p in state.peers:
              tracked.incl(p.peerId)
            for p in state.pendingPeers:
              tracked.incl(p)
            let candidates = self.selectFilterCandidates(shard, tracked, needed)
            let toSubscribe = min(needed, candidates.len)

            trace "edgeFilterSubLoop: shard reconciliation",
              shard = shard,
              num_peers = state.peers.len,
              num_pending = state.pending.len,
              num_needed = needed,
              num_available = candidates.len,
              toSubscribe = toSubscribe

            var subscribeTopics: seq[ContentTopic]
            newSynced.withValue(shard, curr):
              subscribeTopics = toSeq(curr[])

            for i in 0 ..< toSubscribe:
              subscribeTasks.add(
                EdgeFilterSubscribeTask(
                  peer: candidates[i], shard: shard, topics: subscribeTopics
                )
              )

    # Step 2: execute deferred shard tracking deletion and filter-subscribe tasks.

    for shard in shardsToDelete:
      self.edgeFilterSubStates.withValue(shard, state):
        for fut in state.pending:
          if not fut.finished:
            await fut.cancelAndWait()
      self.edgeFilterSubStates.del(shard)

    for task in subscribeTasks:
      let fut = self.subscribeFilterPeer(task.peer, task.shard, task.topics)
      self.edgeFilterSubStates.withValue(task.shard, state):
        state.pending.add(fut)

    lastSynced = newSynced

proc startEdgeFilterLoops(self: SubscriptionManager): Result[void, string] =
  ## Start the edge filter orchestration loops.
  ## Caller must ensure this is only called in edge mode (relay nil, filter client present).
  self.peerEventListener = WakuPeerEvent.listen(
    self.node.brokerCtx,
    proc(evt: WakuPeerEvent) {.async: (raises: []), gcsafe.} =
      if evt.kind == WakuPeerEventKind.EventDisconnected:
        # We know a peer is gone, so if it was a service filter peer for this
        # edge node, remove it from the list of service filter peers for each
        # shard it served and re-evaluate shard health for the affected shards.
        for shard, state in self.edgeFilterSubStates.mpairs:
          let oldLen = state.peers.len
          state.peers.keepItIf(it.peerId != evt.peerId)
          if state.peers.len < oldLen:
            self.updateShardHealth(shard, state)
        self.edgeFilterWakeup.fire()
      elif evt.kind == WakuPeerEventKind.EventMetadataUpdated:
        self.edgeFilterWakeup.fire(),
  ).valueOr:
    return err("Failed to listen to peer events for edge filter: " & error)

  self.edgeFilterSubLoopFut = self.edgeFilterSubLoop()
  self.edgeFilterConnectionLoopFut = self.edgeFilterConnectionLoop()
  return ok()

proc stopEdgeFilterLoops(self: SubscriptionManager) {.async: (raises: []).} =
  ## Stop the edge filter orchestration loops and clean up pending futures.
  if not isNil(self.edgeFilterSubLoopFut):
    await self.edgeFilterSubLoopFut.cancelAndWait()
    self.edgeFilterSubLoopFut = nil

  if not isNil(self.edgeFilterConnectionLoopFut):
    await self.edgeFilterConnectionLoopFut.cancelAndWait()
    self.edgeFilterConnectionLoopFut = nil

  for shard, state in self.edgeFilterSubStates:
    for fut in state.pending:
      if not fut.finished:
        await fut.cancelAndWait()

  await WakuPeerEvent.dropListener(self.node.brokerCtx, self.peerEventListener)

proc start*(self: SubscriptionManager): Result[void, string] =
  let edgeShardHealthRes = RequestEdgeShardHealth.setProvider(
    self.node.brokerCtx,
    proc(shard: PubsubTopic): Result[RequestEdgeShardHealth, string] =
      self.edgeFilterSubStates.withValue(shard, state):
        return ok(RequestEdgeShardHealth(health: state.currentHealth))
      return ok(RequestEdgeShardHealth(health: TopicHealth.NOT_SUBSCRIBED)),
  )
  self.ownsEdgeShardHealthProvider = edgeShardHealthRes.isOk()
  if edgeShardHealthRes.isErr():
    error "Can't set provider for RequestEdgeShardHealth",
      error = edgeShardHealthRes.error

  let edgeFilterPeerCountRes = RequestEdgeFilterPeerCount.setProvider(
    self.node.brokerCtx,
    proc(): Result[RequestEdgeFilterPeerCount, string] =
      var minPeers = high(int)
      for state in self.edgeFilterSubStates.values:
        minPeers = min(minPeers, state.peers.len)
      if minPeers == high(int):
        minPeers = 0
      return ok(RequestEdgeFilterPeerCount(peerCount: minPeers)),
  )
  self.ownsEdgeFilterPeerCountProvider = edgeFilterPeerCountRes.isOk()
  if edgeFilterPeerCountRes.isErr():
    error "Can't set provider for RequestEdgeFilterPeerCount",
      error = edgeFilterPeerCountRes.error

  # Start Edge workers only when we are in Edge mode (relay not mounted)
  # AND the filter client is mounted (otherwise the loops have nothing
  # to talk to and just spam "filter client is nil" warnings).
  if self.node.wakuRelay.isNil() and not self.node.wakuFilterClient.isNil():
    return self.startEdgeFilterLoops()

  return ok()

proc stop*(self: SubscriptionManager) {.async: (raises: []).} =
  # Stop Edge workers if we started them in `start` (Edge mode + filter client).
  if self.node.wakuRelay.isNil() and not self.node.wakuFilterClient.isNil():
    await self.stopEdgeFilterLoops()

  # Only clear providers we actually registered: another SubscriptionManager
  # sharing this brokerCtx may have won the race, and clearing its provider
  # would leave the broker silently provider-less.
  if self.ownsEdgeShardHealthProvider:
    RequestEdgeShardHealth.clearProvider(self.node.brokerCtx)
    self.ownsEdgeShardHealthProvider = false
  if self.ownsEdgeFilterPeerCountProvider:
    RequestEdgeFilterPeerCount.clearProvider(self.node.brokerCtx)
    self.ownsEdgeFilterPeerCountProvider = false
