import
  std/[sequtils, random, tables],
  results,
  chronicles,
  chronos,
  metrics,
  libp2p/protocols/protocol,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  eth/p2p/discoveryv5/enr
import
  ../common/nimchronos,
  ../node/peer_manager,
  ../waku_core,
  ../discovery/waku_discv5,
  ./rpc,
  ./rpc_codec,
  ../common/rate_limit/request_limiter,
  ./common

from ../waku_core/codecs import WakuPeerExchangeCodec
export WakuPeerExchangeCodec

declarePublicGauge logos_delivery_px_peers_received_unknown,
  "number of previously unknown ENRs received via peer exchange"
declarePublicCounter logos_delivery_px_errors,
  "number of peer exchange errors", ["type"]
declarePublicCounter logos_delivery_px_peers_sent,
  "number of ENRs sent to peer exchange requesters"

logScope:
  topics = "waku peer_exchange"

type
  PxRandomWalk* =
    proc(): Future[seq[enr.Record]] {.async: (raises: [CancelledError]), gcsafe.}
    ## One random walk over the discv5 DHT, separate from the walks that feed
    ## the node's own peer store.

  PxCacheEntry = object
    record: enr.Record
    expiresAt: Moment

  WakuPeerExchange* = ref object of LPProtocol
    peerManager*: PeerManager
    cluster*: Opt[uint16]
    requestRateLimiter*: RequestRateLimiter
    cacheTtl*: Duration
    enrCache: OrderedTable[PeerId, PxCacheEntry]
      ## Oldest entry first. Fed only by discv5 random walks, never by the
      ## node's peer store, so a response reveals nothing about our own peers
      ## (RFC 34, requester-side neighbourhood surveillance).
    refreshLoopHandle: Future[void].Raising([CancelledError])

proc respond(
    wpx: WakuPeerExchange, enrs: seq[enr.Record], conn: Connection
): Future[WakuPeerExchangeResult[void]] {.async: (raises: [CancelledError]), gcsafe.} =
  let rpc = PeerExchangeRpc.makeResponse(enrs.mapIt(PeerExchangePeerInfo(enr: it.raw)))

  try:
    await conn.writeLP(rpc.encode())
  except LPStreamError as exc:
    # Remote closed the stream before we responded - expected during peer churn.
    debug "peer exchange response not delivered: stream closed",
      peerId = conn.peerId, error = exc.msg
    logos_delivery_px_errors.inc(labelValues = [streamClosedFailure])
    return err(
      (
        status_code: PeerExchangeResponseStatusCode.DIAL_FAILURE,
        status_desc: Opt.some("stream closed before response: " & exc.msg),
      )
    )

  return ok()

proc respondError(
    wpx: WakuPeerExchange,
    status_code: PeerExchangeResponseStatusCode,
    status_desc: Opt[string],
    conn: Connection,
): Future[WakuPeerExchangeResult[void]] {.async: (raises: [CancelledError]), gcsafe.} =
  let rpc = PeerExchangeRpc.makeErrorResponse(status_code, status_desc)

  try:
    await conn.writeLP(rpc.encode())
  except LPStreamError as exc:
    # Remote closed the stream before we responded - expected during peer churn.
    debug "peer exchange error response not delivered: stream closed",
      peerId = conn.peerId, error = exc.msg
    logos_delivery_px_errors.inc(labelValues = [streamClosedFailure])
    return err(
      (
        status_code: PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE,
        status_desc: Opt.some("stream closed before response: " & exc.msg),
      )
    )

  return ok()

proc poolFilter*(
    cluster: Opt[uint16], origin: PeerOrigin, enr: enr.Record
): Result[void, string] =
  if origin != Discv5:
    trace "peer not from discv5", origin = $origin
    return err("peer not from discv5: " & $origin)
  if cluster.isSome() and enr.isClusterMismatched(cluster.get()):
    trace "peer has mismatching cluster"
    return err("peer has mismatching cluster")
  ## A record with no dialable endpoint is nothing to hand on.
  if enr.toRemotePeerInfo().isErr():
    trace "peer has no dialable endpoint"
    return err("peer has no dialable endpoint")
  return ok()

proc poolFilter*(cluster: Opt[uint16], peer: RemotePeerInfo): Result[void, string] =
  if peer.enr.isNone():
    debug "Peer has no ENR", peer = $peer
    return err("peer has no ENR: " & $peer)
  return poolFilter(cluster, peer.origin, peer.enr.get())

proc pruneCache(wpx: WakuPeerExchange, now: Moment) =
  var expired: seq[PeerId]
  for peerId, entry in wpx.enrCache:
    if entry.expiresAt <= now:
      expired.add(peerId)
  for peerId in expired:
    wpx.enrCache.del(peerId)

proc addToCache*(wpx: WakuPeerExchange, records: openArray[enr.Record]) =
  let now = Moment.now()
  wpx.pruneCache(now)
  for record in records:
    poolFilter(wpx.cluster, Discv5, record).isOkOr:
      continue
    let peerInfo = record.toRemotePeerInfo().valueOr:
      continue
    # Re-insert so a rediscovered peer moves to the young end.
    wpx.enrCache.del(peerInfo.peerId)
    wpx.enrCache[peerInfo.peerId] =
      PxCacheEntry(record: record, expiresAt: now + wpx.cacheTtl)
  while wpx.enrCache.len > MaxPeersCacheSize:
    var oldest: PeerId
    for peerId in wpx.enrCache.keys:
      oldest = peerId
      break
    wpx.enrCache.del(oldest)

proc cacheLen*(wpx: WakuPeerExchange): int =
  wpx.pruneCache(Moment.now())
  return wpx.enrCache.len

proc getEnrsFromCache*(
    wpx: WakuPeerExchange, numPeers: uint64
): seq[enr.Record] {.gcsafe.} =
  wpx.pruneCache(Moment.now())
  var enrs = toSeq(wpx.enrCache.values).mapIt(it.record)
  shuffle(enrs)
  enrs.setLen(int(min(uint64(enrs.len), numPeers)))
  return enrs

proc cacheRefreshLoop(
    wpx: WakuPeerExchange, walk: PxRandomWalk
) {.async: (raises: [CancelledError]).} =
  while true:
    wpx.addToCache(await walk())
    await sleepAsync(CacheRefreshInterval)

proc stopCacheRefresh*(wpx: WakuPeerExchange) {.async: (raises: []).} =
  if not wpx.refreshLoopHandle.isNil():
    await wpx.refreshLoopHandle.cancelAndWait()
    wpx.refreshLoopHandle = nil

proc startCacheRefresh*(wpx: WakuPeerExchange, walk: PxRandomWalk) =
  if not wpx.refreshLoopHandle.isNil():
    wpx.refreshLoopHandle.cancelSoon()
  wpx.refreshLoopHandle = wpx.cacheRefreshLoop(walk)

proc randomWalk*(wd: WakuDiscoveryV5): PxRandomWalk =
  return proc(): Future[seq[enr.Record]] {.async: (raises: [CancelledError]).} =
    if wd.isNil() or not wd.listening:
      return @[]
    try:
      return await wd.findRandomPeers()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      logos_delivery_px_errors.inc(labelValues = [retrievePeersDiscv5Error])
      debug "peer exchange cache refresh walk failed", error = exc.msg
      return @[]

proc initProtocolHandler(wpx: WakuPeerExchange) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var buffer: seq[byte]
    wpx.requestRateLimiter.checkUsageLimit(WakuPeerExchangeCodec, conn):
      try:
        buffer = await conn.readLp(DefaultMaxRpcSize.int)
      except LPStreamError as exc:
        # Remote disconnected before sending a full request - expected churn;
        # no point responding on a dead stream.
        debug "peer exchange request not received: stream closed",
          peerId = conn.peerId, error = exc.msg
        logos_delivery_px_errors.inc(labelValues = [streamClosedFailure])
        return

      let decBuf = PeerExchangeRpc.decode(buffer).valueOr:
        logos_delivery_px_errors.inc(labelValues = [decodeRpcFailure])
        debug "Failed to decode PeerExchange request", error = $error

        (
          await wpx.respondError(
            PeerExchangeResponseStatusCode.BAD_REQUEST, Opt.some($error), conn
          )
        ).isOkOr:
          debug "Failed to respond with BAD_REQUEST", error = $error
        return

      let request = decBuf.request.valueOr:
        logos_delivery_px_errors.inc(labelValues = [decodeRpcFailure])
        (
          await wpx.respondError(
            PeerExchangeResponseStatusCode.BAD_REQUEST,
            Opt.some("missing request"),
            conn,
          )
        ).isOkOr:
          debug "Failed to respond with BAD_REQUEST", error = $error
        return

      let enrs = wpx.getEnrsFromCache(request.numPeers)

      debug "Peer exchange request received"
      trace "px enrs to respond", enrs = $enrs
      (await wpx.respond(enrs, conn)).isErrOr:
        logos_delivery_px_peers_sent.inc(enrs.len().int64())
    do:
      defer:
        # close, no data is expected
        await conn.closeWithEof()

      (
        await wpx.respondError(
          PeerExchangeResponseStatusCode.TOO_MANY_REQUESTS, Opt.none(string), conn
        )
      ).isOkOr:
        debug "Failed to respond with TOO_MANY_REQUESTS", error = $error

  wpx.handler = handler
  wpx.codec = WakuPeerExchangeCodec

proc new*(
    T: type WakuPeerExchange,
    peerManager: PeerManager,
    cluster: Opt[uint16] = Opt.none(uint16),
    rateLimitSetting: Opt[RateLimitSetting] = Opt.none(RateLimitSetting),
): T =
  let wpx = WakuPeerExchange(
    peerManager: peerManager,
    cluster: cluster,
    requestRateLimiter: newRequestRateLimiter(rateLimitSetting),
    cacheTtl: CacheEntryTtl,
  )
  wpx.initProtocolHandler()
  setServiceLimitMetric(WakuPeerExchangeCodec, rateLimitSetting)
  return wpx
