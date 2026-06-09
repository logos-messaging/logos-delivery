{.push raises: [].}

import
  std/[options, sets, tables, sequtils],
  chronicles,
  chronos,
  libp2p/peerid,
  libp2p/stream/connection,
  stew/shims/sets
import ../waku_core, ../utils/tableutils, ../node/peer_manager

logScope:
  topics = "waku filter subscriptions"

const
  MaxFilterPeers* = 100
  MaxFilterCriteriaPerPeer* = 1000
  DefaultSubscriptionTimeToLiveSec* = 5.minutes
  MessageCacheTTL* = 2.minutes

type
  # a single filter criterion is fully defined by a pubsub topic and content topic
  FilterCriterion* = tuple[pubsubTopic: PubsubTopic, contentTopic: ContentTopic]

  FilterCriteria* = HashSet[FilterCriterion] # a sequence of filter criteria

  SubscribedPeers* = HashSet[PeerID] # a sequence of peer ids

  PeerData* = tuple[lastSeen: Moment, criteriaCount: uint]

  FilterSubscriptions* = ref object
    peersSubscribed*: Table[PeerID, PeerData]
    subscriptions*: Table[FilterCriterion, SubscribedPeers]
    subscriptionTimeout: Duration
    maxPeers: uint
    maxCriteriaPerPeer: uint

proc new*(
    T: type FilterSubscriptions,
    subscriptionTimeout: Duration = DefaultSubscriptionTimeToLiveSec,
    maxFilterPeers: uint32 = MaxFilterPeers,
    maxFilterCriteriaPerPeer: uint32 = MaxFilterCriteriaPerPeer,
): FilterSubscriptions =
  return FilterSubscriptions(
    peersSubscribed: initTable[PeerID, PeerData](),
    subscriptions: initTable[FilterCriterion, SubscribedPeers](),
    subscriptionTimeout: subscriptionTimeout,
    maxPeers: maxFilterPeers,
    maxCriteriaPerPeer: maxFilterCriteriaPerPeer,
  )

proc isSubscribed*(s: FilterSubscriptions, peerId: PeerID): bool =
  s.peersSubscribed.withValue(peerId, data):
    return Moment.now() - data.lastSeen <= s.subscriptionTimeout

  return false

proc subscribedPeerCount*(s: FilterSubscriptions): uint =
  return cast[uint](s.peersSubscribed.len)

proc getPeerSubscriptions*(
    s: FilterSubscriptions, peerId: PeerID
): seq[FilterCriterion] =
  ## Get all pubsub-content topics a peer is subscribed to
  var subscribedContentTopics: seq[FilterCriterion] = @[]
  s.peersSubscribed.withValue(peerId, data):
    if data.criteriaCount == 0:
      return subscribedContentTopics

    for filterCriterion, subscribedPeers in s.subscriptions.mpairs:
      if peerId in subscribedPeers:
        subscribedContentTopics.add(filterCriterion)

  return subscribedContentTopics

proc findSubscribedPeers*(
    s: FilterSubscriptions, pubsubTopic: PubsubTopic, contentTopic: ContentTopic
): seq[PeerID] =
  let filterCriterion: FilterCriterion = (pubsubTopic, contentTopic)

  var foundPeers: seq[PeerID] = @[]
  # only peers subscribed to criteria and with legit subscription is counted
  s.subscriptions.withValue(filterCriterion, peers):
    for peer in peers[]:
      if s.isSubscribed(peer):
        foundPeers.add(peer)

  info "findSubscribedPeers result",
    filter_criterion = filterCriterion,
    subscr_set = s.subscriptions,
    found_peers = foundPeers

  return foundPeers

proc removePeer*(s: FilterSubscriptions, peerId: PeerID) {.async.} =
  ## Remove all subscriptions for a given peer
  info "removePeer",
    currentPeerIds = toSeq(s.peersSubscribed.keys).mapIt(shortLog(it)), peerId = peerId

  s.peersSubscribed.del(peerId)

  info "removePeer after deletion",
    currentPeerIds = toSeq(s.peersSubscribed.keys).mapIt(shortLog(it)), peerId = peerId

proc removePeers*(s: FilterSubscriptions, peerIds: seq[PeerID]) {.async.} =
  ## Remove all subscriptions for a given list of peers
  info "removePeers",
    currentPeerIds = toSeq(s.peersSubscribed.keys).mapIt(shortLog(it)),
    peerIds = peerIds.mapIt(shortLog(it))

  for peer in peerIds:
    await s.removePeer(peer)

  info "removePeers after deletion",
    currentPeerIds = toSeq(s.peersSubscribed.keys).mapIt(shortLog(it)),
    peerIds = peerIds.mapIt(shortLog(it))

proc cleanUp*(fs: FilterSubscriptions) =
  info "cleanUp", currentPeerIds = toSeq(fs.peersSubscribed.keys).mapIt(shortLog(it))

  ## Remove all subscriptions for peers that have not been seen for a while
  let now = Moment.now()
  fs.peersSubscribed.keepItIf(now - val.lastSeen <= fs.subscriptionTimeout)

  var filtersToRemove: seq[FilterCriterion] = @[]
  for filterCriterion, subscribedPeers in fs.subscriptions.mpairs:
    subscribedPeers.keepItIf(fs.isSubscribed(it) == true)

  fs.subscriptions.keepItIf(val.len > 0)

  info "after cleanUp",
    currentPeerIds = toSeq(fs.peersSubscribed.keys).mapIt(shortLog(it))

proc refreshSubscription*(s: var FilterSubscriptions, peerId: PeerID) =
  s.peersSubscribed.withValue(peerId, data):
    data.lastSeen = Moment.now()

proc addSubscription*(
    s: FilterSubscriptions, peerId: PeerID, filterCriteria: FilterCriteria
): Future[Result[void, string]] {.async.} =
  ## Add a subscription for a given peer

  var peerData: ptr PeerData

  s.peersSubscribed.withValue(peerId, data):
    if data.criteriaCount + cast[uint](filterCriteria.len) > s.maxCriteriaPerPeer:
      return err("peer has reached maximum number of filter criteria")

    data.lastSeen = Moment.now()
    peerData = data
  do:
    ## not yet subscribed
    if cast[uint](s.peersSubscribed.len) >= s.maxPeers:
      return err("node has reached maximum number of subscriptions: " & $(s.maxPeers))

    let newPeerData: PeerData = (lastSeen: Moment.now(), criteriaCount: 0)
    peerData = addr(s.peersSubscribed.mgetOrPut(peerId, newPeerData))

  for filterCriterion in filterCriteria:
    var peersOfSub = addr(s.subscriptions.mgetOrPut(filterCriterion, SubscribedPeers()))
    if peerId notin peersOfSub[]:
      peersOfSub[].incl(peerId)
      peerData.criteriaCount += 1

  info "subscription added correctly",
    new_peer = shortLog(peerId), subscr_set = s.subscriptions

  return ok()

proc removeSubscription*(
    s: FilterSubscriptions, peerId: PeerID, filterCriteria: FilterCriteria
): Result[void, string] =
  ## Remove a subscription for a given peer

  s.peersSubscribed.withValue(peerId, peerData):
    peerData.lastSeen = Moment.now()
    for filterCriterion in filterCriteria:
      s.subscriptions.withValue(filterCriterion, peers):
        if peers[].missingOrexcl(peerId) == false:
          peerData.criteriaCount -= 1

          if peers[].len == 0:
            s.subscriptions.del(filterCriterion)
          if peerData.criteriaCount == 0:
            s.peersSubscribed.del(peerId)
      do:
        ## Maybe let just run through and log it as a warning
        return err("Peer was not subscribed to criterion")

    return ok()
  do:
    return err("Peer has no subscriptions")

proc setSubscriptionTimeout*(s: FilterSubscriptions, newTimeout: Duration) =
  s.subscriptionTimeout = newTimeout
