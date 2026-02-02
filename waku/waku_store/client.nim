{.push raises: [].}

import
  std/[options, tables, sequtils, algorithm],
  results,
  chronicles,
  chronos,
  metrics,
  bearssl/rand
import
  ../node/peer_manager, ../utils/requests, ./protocol_metrics, ./common, ./rpc_codec

logScope:
  topics = "waku store client"

const DefaultPageSize*: uint = 20
const DefaultPageSize_dummy*: uint = 20
  # A recommended default number of waku messages per page

const MaxQueryRetries = 5 # Maximum number of store peers to try before giving up

type WakuStoreClient* = ref object
  peerManager: PeerManager
  rng: ref rand.HmacDrbgContext
  storeMsgMetricsPerShard*: Table[string, float64]

proc new*(
    T: type WakuStoreClient, peerManager: PeerManager,
        rng: ref rand.HmacDrbgContext
): T {.gcsafe.} =
  WakuStoreClient(peerManager: peerManager, rng: rng)

proc sendStoreRequest(
    self: WakuStoreClient, request: StoreQueryRequest, connection: Connection
): Future[StoreQueryResult] {.async, gcsafe.} =
  var req = request

  defer:
    await connection.closeWithEof()

  if req.requestId == "":
    req.requestId = generateRequestId(self.rng)

  let writeRes = catch:
    await connection.writeLP(req.encode().buffer)
  if writeRes.isErr():
    return err(StoreError(kind: ErrorCode.BAD_REQUEST,
        cause: writeRes.error.msg))

  let readRes = catch:
    await connection.readLp(DefaultMaxRpcSize.int)

  let buf = readRes.valueOr:
    return err(StoreError(kind: ErrorCode.BAD_RESPONSE, cause: error.msg))

  let res = StoreQueryResponse.decode(buf).valueOr:
    waku_store_errors.inc(labelValues = [DecodeRpcFailure])
    return err(StoreError(kind: ErrorCode.BAD_RESPONSE,
        cause: DecodeRpcFailure))

  if res.statusCode != uint32(StatusCode.SUCCESS):
    waku_store_errors.inc(labelValues = [NoSuccessStatusCode])
    return err(StoreError.new(res.statusCode, res.statusDesc))

  if req.pubsubTopic.isSome():
    let topic = req.pubsubTopic.get()
    if not self.storeMsgMetricsPerShard.hasKey(topic):
      self.storeMsgMetricsPerShard[topic] = 0
    self.storeMsgMetricsPerShard[topic] += float64(req.encode().buffer.len)

    waku_relay_fleet_store_msg_size_bytes.inc(
      self.storeMsgMetricsPerShard[topic], labelValues = [topic]
    )
    waku_relay_fleet_store_msg_count.inc(1.0, labelValues = [topic])

  return ok(res)

proc query*(
    self: WakuStoreClient, request: StoreQueryRequest, peer: RemotePeerInfo | PeerId
): Future[StoreQueryResult] {.async, gcsafe.} =
  if request.paginationCursor.isSome() and request.paginationCursor.get() == EmptyCursor:
    return err(StoreError(kind: ErrorCode.BAD_REQUEST, cause: "invalid cursor"))

  let connection = (await self.peerManager.dialPeer(peer,
      WakuStoreCodec)).valueOr:
    waku_store_errors.inc(labelValues = [DialFailure])

    return err(StoreError(kind: ErrorCode.PEER_DIAL_FAILURE, address: $peer))

  return await self.sendStoreRequest(request, connection)

proc queryToAny*(
    self: WakuStoreClient, request: StoreQueryRequest, peerId = none(PeerId)
): Future[StoreQueryResult] {.async.} =
  ## we don't specify a particular peer and instead we get it from peer manager.
  ## It will retry with different store peers if the dial fails.

  if request.paginationCursor.isSome() and request.paginationCursor.get() == EmptyCursor:
    return err(StoreError(kind: ErrorCode.BAD_REQUEST, cause: "invalid cursor"))

  # Get all available store peers
  var peers = self.peerManager.switch.peerStore.getPeersByProtocol(WakuStoreCodec)
  if peers.len == 0:
    return err(StoreError(kind: BAD_RESPONSE,
        cause: "no service store peer connected"))

  # Shuffle to distribute load and limit retries
  let peersToTry = peers[0 ..< min(peers.len, MaxQueryRetries)]

  var lastError: StoreError
  for peer in peersToTry:
    let connection = (await self.peerManager.dialPeer(peer,
        WakuStoreCodec)).valueOr:
      waku_store_errors.inc(labelValues = [DialFailure])
      warn "failed to dial store peer, trying next"
      lastError = StoreError(kind: ErrorCode.PEER_DIAL_FAILURE, address: $peer)
      continue

    let response = (await self.sendStoreRequest(request, connection)).valueOr:
      warn "store query failed, trying next peer", peerId = peer.peerId, error = $error
      lastError = error
      continue

    return ok(response)

  return err(lastError)
