import
  std/[options, sequtils, random],
  results,
  chronicles,
  chronos,
  metrics,
  libp2p/protocols/protocol,
  libp2p/crypto/crypto,
  eth/enr/enr
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

declarePublicGauge waku_px_peers_received_unknown,
  "number of previously unknown ENRs received via peer exchange"
declarePublicCounter waku_px_errors, "number of peer exchange errors", ["type"]
declarePublicCounter waku_px_peers_sent,
  "number of ENRs sent to peer exchange requesters"

logScope:
  topics = "waku peer_exchange"

type WakuPeerExchange* = ref object of LPProtocol
  peerManager*: PeerManager
  cluster*: Option[uint16]
    # todo: next step: ring buffer; future: implement cache satisfying https://rfc.vac.dev/spec/34/
  requestRateLimiter*: RequestRateLimiter

proc respond(
    wpx: WakuPeerExchange, enrs: seq[enr.Record], conn: Connection
): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  let rpc = PeerExchangeRpc.makeResponse(enrs.mapIt(PeerExchangePeerInfo(enr: it.raw)))

  try:
    await conn.writeLP(rpc.encode().buffer)
  except CatchableError as exc:
    error "exception when trying to send a respond", error = getCurrentExceptionMsg()
    waku_px_errors.inc(labelValues = [exc.msg])
    return err(
      (
        status_code: PeerExchangeResponseStatusCode.DIAL_FAILURE,
        status_desc: some("exception dialing peer: " & exc.msg),
      )
    )

  return ok()

proc respondError(
    wpx: WakuPeerExchange,
    status_code: PeerExchangeResponseStatusCode,
    status_desc: Option[string],
    conn: Connection,
): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  let rpc = PeerExchangeRpc.makeErrorResponse(status_code, status_desc)

  try:
    await conn.writeLP(rpc.encode().buffer)
  except CatchableError as exc:
    error "exception when trying to send a respond", error = getCurrentExceptionMsg()
    waku_px_errors.inc(labelValues = [exc.msg])
    return err(
      (
        status_code: PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE,
        status_desc: some("exception dialing peer: " & exc.msg),
      )
    )

  return ok()

proc poolFilter*(
    cluster: Option[uint16], origin: PeerOrigin, enr: enr.Record
): Result[void, string] =
  if origin != Discv5:
    trace "peer not from discv5", origin = $origin
    return err("peer not from discv5: " & $origin)
  if cluster.isSome() and enr.isClusterMismatched(cluster.get()):
    trace "peer has mismatching cluster"
    return err("peer has mismatching cluster")
  return ok()

proc poolFilter*(cluster: Option[uint16], peer: RemotePeerInfo): Result[void, string] =
  if peer.enr.isNone():
    info "peer has no ENR", peer = $peer
    return err("peer has no ENR: " & $peer)
  return poolFilter(cluster, peer.origin, peer.enr.get())

proc getEnrsFromStore(
    wpx: WakuPeerExchange, numPeers: uint64
): seq[enr.Record] {.gcsafe.} =
  # Reservoir sampling (Algorithm R)
  var i = 0
  let k = min(MaxPeersCacheSize, numPeers.int)
  let enrStoreLen = wpx.peerManager.switch.peerStore[ENRBook].len
  var enrs = newSeqOfCap[enr.Record](min(k, enrStoreLen))
  wpx.peerManager.switch.peerStore.forEnrPeers(
    peerId, peerConnectedness, peerOrigin, peerEnrRecord
  ):
    if peerConnectedness == CannotConnect:
      debug "Could not retrieve ENR because cannot connect to peer",
        remotePeerId = peerId
      continue
    poolFilter(wpx.cluster, peerOrigin, peerEnrRecord).isOkOr:
      debug "Could not get ENR because no peer matched pool", error = error
      continue
    if i < k:
      enrs.add(peerEnrRecord)
    else:
      # Add some randomness
      let j = rand(i)
      if j < k:
        enrs[j] = peerEnrRecord
    inc(i)
  return enrs

proc initProtocolHandler(wpx: WakuPeerExchange) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var buffer: seq[byte]
    wpx.requestRateLimiter.checkUsageLimit(WakuPeerExchangeCodec, conn):
      try:
        buffer = await conn.readLp(DefaultMaxRpcSize.int)
      except CatchableError as exc:
        error "exception when handling px request", error = getCurrentExceptionMsg()
        waku_px_errors.inc(labelValues = [exc.msg])

        (
          try:
            await wpx.respondError(
              PeerExchangeResponseStatusCode.BAD_REQUEST, some(exc.msg), conn
            )
          except CatchableError:
            error "could not send error response", error = getCurrentExceptionMsg()
            return
        ).isOkOr:
          error "Failed to respond with BAD_REQUEST:", error = $error
        return

      let decBuf = PeerExchangeRpc.decode(buffer).valueOr:
        waku_px_errors.inc(labelValues = [decodeRpcFailure])
        error "Failed to decode PeerExchange request", error = $error

        (
          try:
            await wpx.respondError(
              PeerExchangeResponseStatusCode.BAD_REQUEST, some($error), conn
            )
          except CatchableError:
            error "could not send error response decode",
              error = getCurrentExceptionMsg()
            return
        ).isOkOr:
          error "Failed to respond with BAD_REQUEST:", error = $error
        return

      let enrs = wpx.getEnrsFromStore(decBuf.request.numPeers)

      info "peer exchange request received"
      trace "px enrs to respond", enrs = $enrs
      try:
        (await wpx.respond(enrs, conn)).isErrOr:
          waku_px_peers_sent.inc(enrs.len().int64())
      except CatchableError:
        error "could not send response", error = getCurrentExceptionMsg()
    do:
      defer:
        # close, no data is expected
        await conn.closeWithEof()

      try:
        (
          await wpx.respondError(
            PeerExchangeResponseStatusCode.TOO_MANY_REQUESTS, none(string), conn
          )
        ).isOkOr:
          error "Failed to respond with TOO_MANY_REQUESTS:", error = $error
      except CatchableError:
        error "could not send error response", error = getCurrentExceptionMsg()
        return

  wpx.handler = handler
  wpx.codec = WakuPeerExchangeCodec

proc new*(
    T: type WakuPeerExchange,
    peerManager: PeerManager,
    cluster: Option[uint16] = none(uint16),
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): T =
  let wpx = WakuPeerExchange(
    peerManager: peerManager,
    cluster: cluster,
    requestRateLimiter: newRequestRateLimiter(rateLimitSetting),
  )
  wpx.initProtocolHandler()
  setServiceLimitMetric(WakuPeerExchangeCodec, rateLimitSetting)
  return wpx
