## Mix spam protection coordination via filter protocol
## This module handles filter-based subscription for spam protection coordination
## when relay is not available.

{.push raises: [].}

import chronos, chronicles, std/options
import
  ../waku_core,
  ../waku_core/topics/sharding,
  ../waku_filter_v2/common,
  ./peer_manager,
  ../waku_filter_v2/client,
  ../waku_mix/protocol

logScope:
  topics = "waku node mix_coordination"

# Type aliases for callbacks to avoid circular imports
type
  FilterSubscribeProc* = proc(
    pubsubTopic: Option[PubsubTopic],
    contentTopics: seq[ContentTopic],
    peer: RemotePeerInfo,
  ): Future[FilterSubscribeResult] {.async, gcsafe.}

  FilterPingProc* =
    proc(peer: RemotePeerInfo): Future[FilterSubscribeResult] {.async, gcsafe.}

# Forward declaration
proc subscribeSpamProtectionViaFilter(
  wakuMix: WakuMix,
  peerManager: PeerManager,
  filterClient: WakuFilterClient,
  filterSubscribe: FilterSubscribeProc,
  contentTopics: seq[ContentTopic],
) {.async.}

proc setupSpamProtectionViaFilter*(
    wakuMix: WakuMix,
    peerManager: PeerManager,
    filterClient: WakuFilterClient,
    filterSubscribe: FilterSubscribeProc,
) =
  ## Set up filter-based spam protection coordination.
  ## Registers message handler and spawns subscription maintenance task.
  let spamTopics = wakuMix.getSpamProtectionContentTopics()
  if spamTopics.len == 0:
    return

  info "Relay not available, subscribing to spam protection via filter",
    topics = spamTopics

  # Register handler for spam protection messages  
  filterClient.registerPushHandler(
    proc(pubsubTopic: PubsubTopic, message: WakuMessage) {.async, gcsafe.} =
      if message.contentTopic in spamTopics:
        await wakuMix.handleMessage(pubsubTopic, message)
  )

  # Wait for filter peer to be available and maintain subscription
  asyncSpawn subscribeSpamProtectionViaFilter(
    wakuMix, peerManager, filterClient, filterSubscribe, spamTopics
  )

proc subscribeSpamProtectionViaFilter(
    wakuMix: WakuMix,
    peerManager: PeerManager,
    filterClient: WakuFilterClient,
    filterSubscribe: FilterSubscribeProc,
    contentTopics: seq[ContentTopic],
) {.async.} =
  ## Subscribe to spam protection topics via filter and maintain the subscription.
  ## Waits for a filter peer to be available before subscribing.
  ## Continuously monitors the subscription health with periodic pings.
  const RetryInterval = chronos.seconds(5)
  const SubscriptionMaintenance = chronos.seconds(30)
  const MaxFailedSubscribes = 3
  var currentFilterPeer: Option[RemotePeerInfo] = none(RemotePeerInfo)
  var noFailedSubscribes = 0

  while true:
    # Select or reuse filter peer
    if currentFilterPeer.isNone():
      let filterPeerOpt = peerManager.selectPeer(WakuFilterSubscribeCodec)
      if filterPeerOpt.isNone():
        debug "No filter peer available yet for spam protection, retrying..."
        await sleepAsync(RetryInterval)
        continue
      currentFilterPeer = some(filterPeerOpt.get())
      info "Selected filter peer for spam protection",
        peer = currentFilterPeer.get().peerId

    # Check if subscription is still alive with ping
    let pingErr = (await filterClient.ping(currentFilterPeer.get())).errorOr:
      # Subscription is alive, wait before next check
      await sleepAsync(SubscriptionMaintenance)
      if noFailedSubscribes > 0:
        noFailedSubscribes = 0
      continue

    # Subscription lost, need to re-subscribe
    warn "Spam protection filter subscription ping failed, re-subscribing",
      error = pingErr, peer = currentFilterPeer.get().peerId

    # Subscribe to spam protection topics
    let res =
      await filterSubscribe(none(PubsubTopic), contentTopics, currentFilterPeer.get())
    if res.isErr():
      noFailedSubscribes += 1
      warn "Failed to subscribe to spam protection topics via filter",
        error = res.error, topics = contentTopics, failCount = noFailedSubscribes

      if noFailedSubscribes >= MaxFailedSubscribes:
        # Try with a different peer
        warn "Max subscription failures reached, selecting new filter peer"
        currentFilterPeer = none(RemotePeerInfo)
        noFailedSubscribes = 0

      await sleepAsync(RetryInterval)
    else:
      info "Successfully subscribed to spam protection topics via filter",
        topics = contentTopics, peer = currentFilterPeer.get().peerId
      noFailedSubscribes = 0
      await sleepAsync(SubscriptionMaintenance)
