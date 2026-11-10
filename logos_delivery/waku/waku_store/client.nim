import libp2p/crypto/crypto
{.push raises: [].}

import
  std/[tables, sequtils, algorithm, random],
  results,
  chronicles,
  chronos,
  metrics,
  bearssl/rand
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

const FailedPeerBackoff* = chronos.minutes(5)
  ## For this long after a query to a store peer failed, `queryToAny` asks the
  ## peer only after the store peers that did not fail.

type WakuStoreClient* = ref object
  peerManager: PeerManager
  rng: crypto.Rng
  storeMsgMetricsPerShard*: Table[string, float64]
  maxResponseSize*: int ## the largest response that the client reads
  failedAt: Table[PeerId, Moment]
    ## When a query to a store peer failed, for the peers in their
    ## `failedPeerBackoff`. A success of a later query deletes the time.
  failedPeerBackoff*: Duration = FailedPeerBackoff
    ## see `FailedPeerBackoff`, shorter in tests

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
    let topic = req.pubsubTopic.get()
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

proc queryAndRecordFailure(
    self: WakuStoreClient, request: StoreQueryRequest, peer: RemotePeerInfo
): Future[StoreQueryResult] {.async.} =
  ## A query to `peer`. When the query fails, or the caller cancels it, it
  ## writes the time in `failedAt`.
  var failed = true
  try:
    let response = ?await self.query(request, peer)
    failed = false
    self.failedAt.del(peer.peerId)
    return ok(response)
  finally:
    if failed:
      self.failedAt[peer.peerId] = Moment.now()

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
      ## a connected peer that is not in its backoff, for a query that prefers
      ## a connection
    Other
    InBackoff ## a query to the peer failed less than `failedPeerBackoff` ago

  RankedStorePeer = tuple[peer: RemotePeerInfo, rank: StorePeerRank]

proc clearExpiredFailures(self: WakuStoreClient) =
  let now = Moment.now()
  for peerId in toSeq(self.failedAt.keys):
    if now - self.failedAt.getOrDefault(peerId) >= self.failedPeerBackoff:
      self.failedAt.del(peerId)

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
      if peer.peerId in self.failedAt:
        StorePeerRank.InBackoff
      elif connectedFirst and switch.isConnected(peer.peerId):
        StorePeerRank.Preferred
      else:
        StorePeerRank.Other
    byRank[rank].add((peer, rank))
  return
    byRank[StorePeerRank.Preferred] & byRank[StorePeerRank.Other] &
    byRank[StorePeerRank.InBackoff]

proc queryToAny*(
    self: WakuStoreClient,
    request: StoreQueryRequest,
    peerId = Opt.none(PeerId),
    shards: seq[PubsubTopic] = @[],
): Future[StoreQueryResult] {.async.} =
  ## we don't specify a particular peer and instead we get it from peer manager.
  ## It will retry with different store peers if the dial fails.
  ## `shards` are the shards of the query. The pubsub topic of the request is
  ## the default.

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
  let peersToTry = ranked[0 ..< min(ranked.len, MaxQueryRetries)].mapIt(it.peer)

  var lastError: StoreError
  for peer in peersToTry:
    let response = (await self.queryAndRecordFailure(request, peer)).valueOr:
      debug "Store query failed, trying next peer", peerId = peer.peerId, error = $error
      lastError = error
      continue

    return ok(response)

  return err(lastError)
