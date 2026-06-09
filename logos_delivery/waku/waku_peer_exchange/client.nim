import std/options, results, chronicles, chronos, metrics

import ./common, ./rpc, ./rpc_codec, ../node/peer_manager

from ../waku_core/codecs import WakuPeerExchangeCodec

declarePublicGauge waku_px_peers_received_total,
  "number of ENRs received via peer exchange"
declarePublicCounter waku_px_client_errors, "number of peer exchange errors", ["type"]

logScope:
  topics = "waku peer_exchange client"

type WakuPeerExchangeClient* = ref object
  peerManager*: PeerManager
  pxLoopHandle*: Future[void]

proc new*(T: type WakuPeerExchangeClient, peerManager: PeerManager): T =
  WakuPeerExchangeClient(peerManager: peerManager)

proc request*(
    wpx: WakuPeerExchangeClient, numPeers = DefaultPXNumPeersReq, conn: Connection
): Future[WakuPeerExchangeResult[PeerExchangeResponse]] {.async: (raises: []).} =
  let rpc = PeerExchangeRpc.makeRequest(numPeers)

  var buffer: seq[byte]
  var callResult =
    (status_code: PeerExchangeResponseStatusCode.SUCCESS, status_desc: none(string))
  try:
    await conn.writeLP(rpc.encode().buffer)
    buffer = await conn.readLp(DefaultMaxRpcSize.int)
  except CatchableError as exc:
    error "exception when handling peer exchange request", error = exc.msg
    waku_px_client_errors.inc(labelValues = ["error_sending_or_receiving_px_req"])
    callResult = (
      status_code: PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE,
      status_desc: some($exc.msg),
    )
  finally:
    # close, no more data is expected
    await conn.closeWithEof()

  if callResult.status_code != PeerExchangeResponseStatusCode.SUCCESS:
    error "peer exchange request failed", status_code = callResult.status_code
    return err(callResult)

  let decoded = PeerExchangeRpc.decode(buffer).valueOr:
    error "peer exchange request error decoding buffer", error = $error
    return err(
      (
        status_code: PeerExchangeResponseStatusCode.BAD_RESPONSE,
        status_desc: some($error),
      )
    )
  if decoded.response.status_code != PeerExchangeResponseStatusCode.SUCCESS:
    error "peer exchange request error", status_code = decoded.response.status_code
    return err(
      (
        status_code: decoded.response.status_code,
        status_desc: decoded.response.status_desc,
      )
    )

  return ok(decoded.response)

proc request*(
    wpx: WakuPeerExchangeClient, numPeers = DefaultPXNumPeersReq, peer: RemotePeerInfo
): Future[WakuPeerExchangeResult[PeerExchangeResponse]] {.async: (raises: []).} =
  try:
    let connOpt = await wpx.peerManager.dialPeer(peer, WakuPeerExchangeCodec)
    if connOpt.isNone():
      error "error in request connOpt is none"
      return err(
        (
          status_code: PeerExchangeResponseStatusCode.DIAL_FAILURE,
          status_desc: some(dialFailure),
        )
      )
    return await wpx.request(numPeers, connOpt.get())
  except CatchableError:
    error "peer exchange request exception", error = getCurrentExceptionMsg()
    return err(
      (
        status_code: PeerExchangeResponseStatusCode.BAD_RESPONSE,
        status_desc: some("exception dialing peer: " & getCurrentExceptionMsg()),
      )
    )

proc request*(
    wpx: WakuPeerExchangeClient, numPeers = DefaultPXNumPeersReq
): Future[WakuPeerExchangeResult[PeerExchangeResponse]] {.async: (raises: []).} =
  let peerOpt = wpx.peerManager.selectPeer(WakuPeerExchangeCodec)
  if peerOpt.isNone():
    waku_px_client_errors.inc(labelValues = [peerNotFoundFailure])
    info "peer exchange request could not be made as no peer exchange peers found"
    return err(
      (
        status_code: PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE,
        status_desc: some(peerNotFoundFailure),
      )
    )
  return await wpx.request(numPeers, peerOpt.get())
