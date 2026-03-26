import std/[sequtils, sets, tables, options], chronos, chronicles, results
import libp2p/[peerid, peerinfo]
import
  ./subscription_manager,
  waku/[
    waku_core,
    waku_node,
    waku_filter_v2/common as filter_common,
    waku_filter_v2/client as filter_client,
    waku_filter_v2/protocol as filter_protocol,
    events/health_events,
    events/peer_events,
    requests/delivery_requests,
    node/peer_manager,
    node/health_monitor/connection_status,
    node/health_monitor/topic_health,
  ]

# NOTE: This file implements the edge subscription management
# part of the SubscriptionManager.
# It's in a separate file just because it can't be in
# subscription_manager.nim due to circular import/dependencies.

const EdgeFilterSubscribeTimeout = chronos.seconds(15)
  ## Timeout for a single filter subscribe/unsubscribe RPC to a service peer.
const EdgeFilterPingTimeout = chronos.seconds(5)
  ## Timeout for a filter ping health check.
const EdgeFilterLoopInterval = chronos.seconds(30)
  ## Interval for the edge filter health loop and sub loop fallback wakeup.
const EdgeFilterSubLoopDebounce = chronos.seconds(1)
  ## Debounce delay to coalesce rapid-fire wakeups into a single reconciliation pass.

proc pingFilterPeer(
    filterClient: filter_client.WakuFilterClient, peer: RemotePeerInfo
): Future[Option[PeerId]] {.async.} =
  let pingFut = filterClient.ping(peer)
  if not await pingFut.withTimeout(EdgeFilterPingTimeout):
    warn "Peer failed Filter Ping, evicting",
      peer = peer.peerId, timeout = EdgeFilterPingTimeout
    return none(PeerId)

  pingFut.read().isOkOr:
    trace "Peer failed to read Filter Ping, evicting",
      peer = peer.peerId, error = $error
    return none(PeerId)

  return some(peer.peerId)

proc updateShardHealth(
    sm: SubscriptionManager, shard: PubsubTopic, state: var EdgeFilterSubState
) =
  ## Recompute and emit health for a shard after its peer set changed.
  let newHealth = toTopicHealth(state.peers.len)
  if newHealth != state.currentHealth:
    state.currentHealth = newHealth
    EventShardTopicHealthChange.emit(sm.node.brokerCtx, shard, newHealth)

proc evictPeer(sm: SubscriptionManager, shard: PubsubTopic, peerId: PeerId) =
  ## Remove a peer from edgeFilterSubStates for the given shard,
  ## update health, and wake the sub loop to dial a replacement.
  sm.edgeFilterSubStates.withValue(shard, state):
    let oldLen = state.peers.len
    state.peers.keepItIf(it.peerId != peerId)
    if state.peers.len < oldLen:
      sm.updateShardHealth(shard, state[])
      sm.edgeFilterWakeup.fire()

proc syncFilterDeltas(
    sm: SubscriptionManager,
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
      let fut = sm.node.wakuFilterClient.subscribe(peer, shard, chunk)
      if not (await fut.withTimeout(EdgeFilterSubscribeTimeout)) or fut.read().isErr():
        trace "syncFilterDeltas: chunk failed, evicting peer",
          shard = shard, peer = peer.peerId, phase = "subscribe"
        sm.evictPeer(shard, peer.peerId)
        return
      i += filter_protocol.MaxContentTopicsPerRequest

    i = 0
    while i < removed.len:
      let chunk =
        removed[i ..< min(i + filter_protocol.MaxContentTopicsPerRequest, removed.len)]
      let fut = sm.node.wakuFilterClient.unsubscribe(peer, shard, chunk)
      if not (await fut.withTimeout(EdgeFilterSubscribeTimeout)) or fut.read().isErr():
        trace "syncFilterDeltas: chunk failed, evicting peer",
          shard = shard, peer = peer.peerId, phase = "unsubscribe"
        sm.evictPeer(shard, peer.peerId)
        return
      i += filter_protocol.MaxContentTopicsPerRequest
  except CatchableError as exc:
    debug "syncFilterDeltas failed, evicting peer",
      shard = shard, peer = peer.peerId, err = exc.msg
    sm.evictPeer(shard, peer.peerId)

proc dialFilterPeer(
    sm: SubscriptionManager,
    peer: RemotePeerInfo,
    shard: PubsubTopic,
    contentTopics: seq[ContentTopic],
) {.async.} =
  ## Subscribe a new peer to all content topics on a shard and start tracking it.
  try:
    var i = 0

    while i < contentTopics.len:
      let chunk = contentTopics[
        i ..< min(i + filter_protocol.MaxContentTopicsPerRequest, contentTopics.len)
      ]
      let subFut = sm.node.wakuFilterClient.subscribe(peer, shard, chunk)
      let ok = await subFut.withTimeout(EdgeFilterSubscribeTimeout)

      if not ok or subFut.read().isErr():
        debug "dialFilterPeer: chunk subscribe failed or timed out",
          shard = shard, peer = peer.peerId, ok = ok
        return

      i += filter_protocol.MaxContentTopicsPerRequest

    sm.edgeFilterSubStates.withValue(shard, state):
      if state.peers.anyIt(it.peerId == peer.peerId):
        trace "dialFilterPeer: peer already tracked, skipping duplicate",
          shard = shard, peer = peer.peerId
        return

      state.peers.add(peer)
      sm.updateShardHealth(shard, state[])
      trace "dialFilterPeer: successfully subscribed to all chunks",
        shard = shard, peer = peer.peerId, totalPeers = state.peers.len
    do:
      trace "dialFilterPeer: shard removed while subscribing, discarding result",
        shard = shard, peer = peer.peerId
  except CatchableError as exc:
    debug "dialFilterPeer failed", err = exc.msg

proc edgeFilterHealthLoop*(sm: SubscriptionManager) {.async.} =
  ## Periodically pings all connected filter service peers to verify they are
  ## still alive at the application layer. Peers that fail the ping are evicted.
  while sm.node.started:
    await sleepAsync(EdgeFilterLoopInterval)

    if sm.node.wakuFilterClient.isNil():
      continue

    var connected = initTable[PeerId, RemotePeerInfo]()
    for state in sm.edgeFilterSubStates.values:
      for peer in state.peers:
        if sm.node.peerManager.switch.peerStore.isConnected(peer.peerId):
          connected[peer.peerId] = peer

    var alive = initHashSet[PeerId]()

    if connected.len > 0:
      var pingTasks: seq[Future[Option[PeerId]]] = @[]
      for peer in connected.values:
        pingTasks.add(pingFilterPeer(sm.node.wakuFilterClient, peer))

      await allFutures(pingTasks)
      for task in pingTasks:
        let res = task.read()
        if res.isSome():
          alive.incl(res.get())

    var changed = false
    for shard, state in sm.edgeFilterSubStates.mpairs:
      let oldLen = state.peers.len
      state.peers.keepItIf(it.peerId notin connected or alive.contains(it.peerId))

      if state.peers.len < oldLen:
        changed = true
        sm.updateShardHealth(shard, state)
        trace "Edge Filter health degraded by Ping failure",
          shard = shard, new = state.currentHealth

    if changed:
      sm.edgeFilterWakeup.fire()

proc edgeFilterSubLoop*(sm: SubscriptionManager) {.async.} =
  ## Reconciles filter subscriptions with the desired state from SubscriptionManager.
  var lastSynced = initTable[PubsubTopic, HashSet[ContentTopic]]()

  while sm.node.started:
    discard await sm.edgeFilterWakeup.wait().withTimeout(EdgeFilterLoopInterval)
    await sleepAsync(EdgeFilterSubLoopDebounce)
    sm.edgeFilterWakeup.clear()
    trace "edgeFilterSubLoop: woke up"

    if isNil(sm.node.wakuFilterClient):
      trace "edgeFilterSubLoop: wakuFilterClient is nil, skipping"
      continue

    var desired = initTable[PubsubTopic, HashSet[ContentTopic]]()
    for sub in sm.getActiveSubscriptions():
      desired[sub.pubsubTopic] = toHashSet(sub.contentTopics)

    trace "edgeFilterSubLoop: desired state", numShards = desired.len

    let allShards = toHashSet(toSeq(desired.keys)) + toHashSet(toSeq(lastSynced.keys))

    for shard in allShards:
      let currTopics = desired.getOrDefault(shard)
      let prevTopics = lastSynced.getOrDefault(shard)

      if shard notin sm.edgeFilterSubStates:
        sm.edgeFilterSubStates[shard] =
          EdgeFilterSubState(currentHealth: TopicHealth.UNHEALTHY)

      let addedTopics = toSeq(currTopics - prevTopics)
      let removedTopics = toSeq(prevTopics - currTopics)

      sm.edgeFilterSubStates.withValue(shard, state):
        state.peers.keepItIf(
          sm.node.peerManager.switch.peerStore.isConnected(it.peerId)
        )
        state.pending.keepItIf(not it.finished)

        if addedTopics.len > 0 or removedTopics.len > 0:
          for peer in state.peers:
            asyncSpawn sm.syncFilterDeltas(peer, shard, addedTopics, removedTopics)

        if currTopics.len == 0:
          for fut in state.pending:
            if not fut.finished:
              asyncSpawn fut.cancelAndWait()
          sm.edgeFilterSubStates.del(shard)
            # invalidates `state` — do not use after this
        else:
          sm.updateShardHealth(shard, state[])

          let needed = max(0, HealthyThreshold - state.peers.len - state.pending.len)

          if needed > 0:
            let tracked = state.peers.mapIt(it.peerId).toHashSet()
            var candidates = sm.node.peerManager.selectPeers(
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
              let fut = sm.dialFilterPeer(candidates[i], shard, toSeq(currTopics))
              state.pending.add(fut)

    lastSynced = desired

proc startEdgeFilterLoops*(sm: SubscriptionManager) =
  ## Start the edge filter orchestration loops.
  ## Caller must ensure this is only called in edge mode (relay nil, filter client present).
  sm.edgeFilterWakeup = newAsyncEvent()

  let peerRes = WakuPeerEvent.listen(
    sm.node.brokerCtx,
    proc(evt: WakuPeerEvent) {.async: (raises: []), gcsafe.} =
      if evt.kind == WakuPeerEventKind.EventDisconnected or
          evt.kind == WakuPeerEventKind.EventMetadataUpdated:
        sm.edgeFilterWakeup.fire()
    ,
  )

  if peerRes.isOk():
    sm.peerEventListener = peerRes.get()
  else:
    error "Failed to listen to peer events for edge filter", error = peerRes.error

  sm.edgeFilterSubLoopFut = sm.edgeFilterSubLoop()
  sm.edgeFilterHealthLoopFut = sm.edgeFilterHealthLoop()

proc stopEdgeFilterLoops*(sm: SubscriptionManager) {.async.} =
  ## Stop the edge filter orchestration loops and clean up pending futures.
  if not isNil(sm.edgeFilterSubLoopFut):
    await sm.edgeFilterSubLoopFut.cancelAndWait()
    sm.edgeFilterSubLoopFut = nil

  if not isNil(sm.edgeFilterHealthLoopFut):
    await sm.edgeFilterHealthLoopFut.cancelAndWait()
    sm.edgeFilterHealthLoopFut = nil

  for shard, state in sm.edgeFilterSubStates:
    for fut in state.pending:
      if not fut.finished:
        await fut.cancelAndWait()

  if sm.peerEventListener.id != 0:
    WakuPeerEvent.dropListener(sm.node.brokerCtx, sm.peerEventListener)
