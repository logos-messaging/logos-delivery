import libp2p/crypto/crypto
{.push raises: [].}

import std/[tables, sequtils, random], results, chronicles, chronos, metrics
import
  ../node/peer_manager,
  ../utils/requests,
  ../waku_core,
  ./protocol_metrics,
  ./common,
  ./rpc_codec

logScope:
  topics = "waku store client"

const DefaultPageSize*: uint = 20
  # A recommended default number of waku messages per page

const MaxQueryRetries = 5 # Maximum number of store peers to try before giving up

const FailedPeerRankLastPeriod* = chronos.minutes(5)
  ## For this long after a query to a store peer failed, `queryToAny` asks the
  ## peer only after the store peers that did not fail.

const FailedPeerInitialBackoff = chronos.seconds(2)
  ## After a failed query, `queryToAny` does not ask the store peer for this long.
  ## The backoff doubles with each consecutive failure, up to `FailedPeerMaxBackoff`.

const FailedPeerMaxBackoff* = chronos.seconds(8)
  ## The longest backoff of a store peer after its failed queries.

type StorePeerFailure = object ## The failed queries to one store peer.
  at: Moment ## the time of the failure that started the backoff
  count: int ## the number of consecutive failures
  error: StoreError ## the error of that failure

type WakuStoreClient* = ref object
  peerManager: PeerManager
  rng: crypto.Rng
  storeMsgMetricsPerShard*: Table[string, float64]
  metricTopics*: TopicLabels ## the topics that may be metric labels
  maxResponseSize*: int ## the largest response that the client reads
  failures: Table[PeerId, StorePeerFailure]
    ## The failures of the store peers in their `failedPeerRankLastPeriod`.
    ## A success of a later query deletes the record of the peer.
  failedPeerRankLastPeriod*: Duration = FailedPeerRankLastPeriod
    ## see `FailedPeerRankLastPeriod`, shorter in tests
  failedPeerInitialBackoff*: Duration = FailedPeerInitialBackoff
    ## see `FailedPeerInitialBackoff`, shorter in tests

proc new*(
    T: type WakuStoreClient,
    peerManager: PeerManager,
    rng: crypto.Rng,
    maxResponseSize = DefaultMaxQueryResponseSize,
): T {.gcsafe.} =
  WakuStoreClient(peerManager: peerManager, rng: rng, maxResponseSize: maxResponseSize)

proc sendStoreRequest(
    self: WakuStoreClient, request: StoreQueryRequest, connection: Connection
): Future[StoreQueryResult] {.async, gcsafe.} =
  var req = request

  self.peerManager.addActiveStoreRequest(connection.peerId)
  defer:
    self.peerManager.removeActiveStoreRequest(connection.peerId)
    asyncSpawn connection.close()

  if req.requestId == "":
    req.requestId = generateRequestId(self.rng)

  try:
    await connection.writeLP(req.encode())
  except LPStreamError as exc:
    return err(StoreError(kind: ErrorCode.BAD_REQUEST, cause: exc.msg))

  let buf =
    try:
      await connection.readLp(self.maxResponseSize)
    except LPStreamError as exc:
      return err(StoreError(kind: ErrorCode.BAD_RESPONSE, cause: exc.msg))

  let res = StoreQueryResponse.decode(buf).valueOr:
    logos_delivery_store_errors.inc(labelValues = [DecodeRpcFailure])
    return err(StoreError(kind: ErrorCode.BAD_RESPONSE, cause: DecodeRpcFailure))

  if res.statusCode != uint32(StatusCode.SUCCESS):
    logos_delivery_store_errors.inc(labelValues = [NoSuccessStatusCode])
    return err(StoreError.new(res.statusCode, res.statusDesc))

  if req.pubsubTopic.isSome():
    let topic = self.metricTopics.topicLabel(req.pubsubTopic.get())
    if not self.storeMsgMetricsPerShard.hasKey(topic):
      self.storeMsgMetricsPerShard[topic] = 0
    self.storeMsgMetricsPerShard[topic] += float64(req.encode().len)

    logos_delivery_store_fleet_msg_size_bytes.inc(
      self.storeMsgMetricsPerShard[topic], labelValues = [topic]
    )
    logos_delivery_store_fleet_msg_count.inc(1.0, labelValues = [topic])

  return ok(res)

proc query*(
    self: WakuStoreClient, request: StoreQueryRequest, peer: RemotePeerInfo | PeerId
): Future[StoreQueryResult] {.async, gcsafe.} =
  if request.paginationCursor.isSome() and request.paginationCursor.get() == EmptyCursor:
    return err(StoreError(kind: ErrorCode.BAD_REQUEST, cause: "invalid cursor"))

  let connection = (await self.peerManager.dialPeer(peer, WakuStoreCodec)).valueOr:
    logos_delivery_store_errors.inc(labelValues = [DialFailure])

    return err(StoreError(kind: ErrorCode.PEER_DIAL_FAILURE, address: $peer))

  return await self.sendStoreRequest(request, connection)

func timedOutError(): StoreError =
  return StoreError(kind: ErrorCode.BAD_RESPONSE, cause: "store query timed out")

proc timeLeft(timeout: Duration, start: Moment): Duration =
  ## The part of `timeout` that is left now, for a wait that began at `start`.
  if timeout.isInfinite():
    return timeout
  return timeout - (Moment.now() - start)

func backoffFor(self: WakuStoreClient, count: int): Duration =
  ## The backoff after `count` consecutive failures (see `FailedPeerInitialBackoff`).
  var backoff = self.failedPeerInitialBackoff
  for _ in 1 ..< count:
    if backoff >= FailedPeerMaxBackoff:
      break
    backoff = backoff * 2
  return min(backoff, FailedPeerMaxBackoff)

func backoffOf*(self: WakuStoreClient, peerId: PeerId): Duration =
  ## The backoff that the last failure of the peer started.
  ## It is zero for a peer with no failure record.
  let count = self.failures.getOrDefault(peerId).count
  if count == 0:
    return ZeroDuration
  return self.backoffFor(count)

proc inBackoff(self: WakuStoreClient, peerId: PeerId, now: Moment): bool =
  ## True while a peer is in its backoff after a failed query.
  ## The backoff of a failed dial does not apply while the peer has a connection.
  let failure = self.failures.getOrDefault(peerId)
  if failure.count == 0 or now >= failure.at + self.backoffFor(failure.count):
    return false
  return
    failure.error.kind != ErrorCode.PEER_DIAL_FAILURE or
    not self.peerManager.switch.isConnected(peerId)

proc recordFailure(self: WakuStoreClient, peerId: PeerId, error: StoreError) =
  ## The peer gets one more failure.
  ## A failure while the peer is in its backoff does not count.
  let now = Moment.now()
  if self.inBackoff(peerId, now):
    return
  var failure = self.failures.getOrDefault(peerId)
  failure.count.inc()
  failure.at = now
  failure.error = error
  self.failures[peerId] = failure
  debug "Store peer starts a backoff",
    peerId = peerId,
    failures = failure.count,
    backoff = self.backoffFor(failure.count),
    error = $error

proc queryAndRecordFailure(
    self: WakuStoreClient, request: StoreQueryRequest, peer: RemotePeerInfo
): Future[StoreQueryResult] {.async: (raises: [CancelledError]).} =
  ## A query to `peer`. A query that fails counts as a failure of the peer.
  ## A cancel of the query counts as no failure.
  let response =
    try:
      await self.query(request, peer)
    except CancelledError as e:
      raise e
    except CatchableError as e:
      err(StoreError(kind: ErrorCode.BAD_RESPONSE, cause: e.msg))
  if response.isOk():
    self.failures.del(peer.peerId)
  else:
    self.recordFailure(peer.peerId, response.error)
  return response

proc queryInOrder(
    self: WakuStoreClient,
    request: StoreQueryRequest,
    peers: seq[RemotePeerInfo],
    timeout: Duration,
): Future[StoreQueryResult] {.async.} =
  ## Asks the store peers in `peers` in their order until one answers, for `timeout`
  ## at most.
  ## It asks `MaxQueryRetries` peers at most, and no peer in its backoff.
  ## At first a call of `queryToAny` had no time limit.
  ## #4227 gave each backfill call one time limit for all the store peers together.
  ## #4351 gave each Store check of a send one time limit for all the store peers
  ## together.
  ## A store peer that has all of `timeout` and does not answer counts as failed.
  ## A later store peer has only the time that is left, so it does not count as
  ## failed when the time ends.
  let start = Moment.now()
  var left = timeout
  var lastError: StoreError
  var asked = 0
  for peer in peers:
    if asked == MaxQueryRetries:
      break
    if left <= ZeroDuration:
      return err(timedOutError())
    # A caller that tries again at once does not dial a peer in its backoff.
    # A query at the same time can start the backoff after this query ranked the peers.
    if self.inBackoff(peer.peerId, Moment.now()):
      lastError = self.failures.getOrDefault(peer.peerId).error
      continue
    inc asked
    let query = self.queryAndRecordFailure(request, peer)
    if not await query.withTimeout(left): # the end of the time cancels the query
      if left == timeout:
        self.recordFailure(peer.peerId, timedOutError())
      return err(timedOutError())
    left = timeout.timeLeft(start)
    let response = query.read().valueOr:
      debug "Store query failed, trying next peer", peerId = peer.peerId, error = $error
      lastError = error
      continue

    return ok(response)

  return err(lastError)

proc storePeers(self: WakuStoreClient): seq[RemotePeerInfo] =
  # Get all available store peers
  var peers = self.peerManager.candidatePeers(WakuStoreCodec)
  # A configured Store peer sits in its service slot with no protocols recorded
  # until a connection learns them; dial it too.
  self.peerManager.serviceSlots.withValue(WakuStoreCodec, slot):
    if not peers.anyIt(it.peerId == slot[].peerId):
      peers.add(slot[])
  return peers

proc canHaveShard(peer: RemotePeerInfo, shard: RelayShard): bool =
  ## A peer that announced shards can have a shard only when it announced
  ## that one. A peer with no shards from its ENR or from metadata can have
  ## each shard, because the node does not know its shards yet.
  return peer.getShards().len == 0 or peer.supportsShard(shard.clusterId, shard.shardId)

proc canHaveEachShard(peer: RemotePeerInfo, shards: seq[RelayShard]): bool =
  return shards.allIt(peer.canHaveShard(it))

proc toRelayShards(shards: seq[PubsubTopic]): seq[RelayShard] =
  ## Empty when a topic of `shards` is not a shard topic.
  var relayShards: seq[RelayShard]
  for shard in shards:
    let relayShard = RelayShard.parse(shard).valueOr:
      return @[]
    relayShards.add(relayShard)
  return relayShards

type
  StorePeerRank {.pure.} = enum
    ## How soon a query asks a store peer. A query asks the peers of a rank
    ## before the peers of the next rank.
    Preferred
      ## a connected peer that did not fail recently, for a query that prefers
      ## a connection
    Other
    RecentlyFailed ## a query to it failed less than `failedPeerRankLastPeriod` ago

  RankedStorePeer = tuple[peer: RemotePeerInfo, rank: StorePeerRank]

proc clearExpiredFailures(self: WakuStoreClient) =
  let now = Moment.now()
  for peerId in toSeq(self.failures.keys):
    if now - self.failures.getOrDefault(peerId).at >= self.failedPeerRankLastPeriod:
      self.failures.del(peerId)

proc rankStorePeers(
    self: WakuStoreClient, peers: seq[RemotePeerInfo], connectedFirst: bool
): seq[RankedStorePeer] =
  ## `peers` in the order in which a query asks them, by `StorePeerRank`. The
  ## order is random in a rank, to distribute load across store peers.
  ## Without `connectedFirst`, no peer is `Preferred`.
  self.clearExpiredFailures()
  var shuffled = peers
  shuffle(shuffled)
  let switch = self.peerManager.switch
  var byRank: array[StorePeerRank, seq[RankedStorePeer]]
  for peer in shuffled:
    let rank =
      if peer.peerId in self.failures:
        StorePeerRank.RecentlyFailed
      elif connectedFirst and switch.isConnected(peer.peerId):
        StorePeerRank.Preferred
      else:
        StorePeerRank.Other
    byRank[rank].add((peer, rank))
  return
    byRank[StorePeerRank.Preferred] & byRank[StorePeerRank.Other] &
    byRank[StorePeerRank.RecentlyFailed]

proc queryToAny*(
    self: WakuStoreClient,
    request: StoreQueryRequest,
    peerId = Opt.none(PeerId),
    shards: seq[PubsubTopic] = @[],
    timeout = InfiniteDuration,
): Future[StoreQueryResult] {.async.} =
  ## we don't specify a particular peer and instead we get it from peer manager.
  ## It will retry with different store peers if the dial fails.
  ## `shards` are the shards of the query. The pubsub topic of the request is
  ## the default.
  ## `timeout` is the longest time of the query, for all the store peers it asks.
  ## The first store peer has all of this time, and it counts as failed when it does
  ## not answer. A later store peer has only the time that is left, so it does not
  ## count as failed when the time ends.
  ## A store peer in its backoff after a failed query gets no query.
  ## When each store peer is in its backoff, the query fails at once with their error.

  if request.paginationCursor.isSome() and request.paginationCursor.get() == EmptyCursor:
    return err(StoreError(kind: ErrorCode.BAD_REQUEST, cause: "invalid cursor"))

  var peers = self.storePeers()
  if peers.len == 0:
    return err(StoreError(kind: BAD_RESPONSE, cause: "no service store peer connected"))

  # Keep the store peers that can have each shard of the query. When no shard
  # filter applies, or no peer passes it, a connection gives no preference.
  let queryShards =
    if shards.len > 0:
      shards
    elif request.pubsubTopic.isSome():
      @[request.pubsubTopic.get()]
    else:
      newSeq[PubsubTopic]()
  let relayShards = queryShards.toRelayShards()
  var canHaveShards = false
  if relayShards.len > 0 and WakuStoreCodec notin self.peerManager.exclusivePeers:
    let ofShards = peers.filterIt(it.canHaveEachShard(relayShards))
    if ofShards.len > 0:
      peers = ofShards
      canHaveShards = true

  let ranked = self.rankStorePeers(peers, connectedFirst = canHaveShards)
  return await self.queryInOrder(request, ranked.mapIt(it.peer), timeout)
