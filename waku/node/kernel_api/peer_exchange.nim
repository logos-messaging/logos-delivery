{.push raises: [].}

import
  std/[options, tables, net],
  chronos,
  chronicles,
  metrics,
  results,
  eth/keys,
  eth/enr/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport,
  libp2p/utility

import
  ../waku_node,
  ../../waku_peer_exchange,
  ../../waku_core,
  ../peer_manager,
  ../../common/rate_limit/setting

logScope:
  topics = "waku node peerexchange api"

## Waku peer-exchange

proc mountPeerExchange*(
    node: WakuNode,
    cluster: Option[uint16] = none(uint16),
    rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit,
) {.async: (raises: []).} =
  info "mounting waku peer exchange"

  node.wakuPeerExchange =
    WakuPeerExchange.new(node.peerManager, cluster, some(rateLimit))

  if node.started:
    try:
      await node.wakuPeerExchange.start()
    except CatchableError:
      error "failed to start wakuPeerExchange", error = getCurrentExceptionMsg()

  try:
    node.switch.mount(node.wakuPeerExchange, protocolMatcher(WakuPeerExchangeCodec))
  except LPError:
    error "failed to mount wakuPeerExchange", error = getCurrentExceptionMsg()

proc mountPeerExchangeClient*(node: WakuNode) {.async: (raises: []).} =
  info "mounting waku peer exchange client"
  if node.wakuPeerExchangeClient.isNil():
    node.wakuPeerExchangeClient = WakuPeerExchangeClient.new(node.peerManager)

proc fetchPeerExchangePeers*(
    node: Wakunode, amount = DefaultPXNumPeersReq
): Future[Result[int, PeerExchangeResponseStatus]] {.async: (raises: []).} =
  if node.wakuPeerExchangeClient.isNil():
    error "could not get peers from px, waku peer-exchange-client is nil"
    return err(
      (
        status_code: PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE,
        status_desc: some("PeerExchangeClient is not mounted"),
      )
    )

  info "Retrieving peer info via peer exchange protocol", amount
  let pxPeersRes = await node.wakuPeerExchangeClient.request(amount)
  if pxPeersRes.isOk():
    var validPeers = 0
    let peers = pxPeersRes.get().peerInfos
    for pi in peers:
      var record: enr.Record
      if enr.fromBytes(record, pi.enr):
        node.peerManager.addPeer(record.toRemotePeerInfo().get, PeerExchange)
        validPeers += 1
    info "Retrieved peer info via peer exchange protocol",
      validPeers = validPeers, totalPeers = peers.len
    return ok(validPeers)
  else:
    warn "failed to retrieve peer info via peer exchange protocol",
      error = pxPeersRes.error
    return err(pxPeersRes.error)

proc peerExchangeLoop(node: WakuNode) {.async.} =
  while true:
    if not node.started:
      await sleepAsync(5.seconds)
      continue
    (await node.fetchPeerExchangePeers()).isOkOr:
      warn "Cannot fetch peers from peer exchange", cause = error
    await sleepAsync(1.minutes)

proc startPeerExchangeLoop*(node: WakuNode) =
  if node.wakuPeerExchangeClient.isNil():
    error "startPeerExchangeLoop: Peer Exchange is not mounted"
    return
  info "Starting peer exchange loop"
  node.wakuPeerExchangeClient.pxLoopHandle = node.peerExchangeLoop()

# TODO: Move to application module (e.g., wakunode2.nim)
proc setPeerExchangePeer*(
    node: WakuNode, peer: RemotePeerInfo | MultiAddress | string
) =
  if node.wakuPeerExchange.isNil():
    error "could not set peer, waku peer-exchange is nil"
    return

  info "Set peer-exchange peer", peer = peer

  let remotePeer = parsePeerInfo(peer).valueOr:
    error "could not parse peer info", error = error
    return

  node.peerManager.addPeer(remotePeer, PeerExchange)
  waku_px_peers.inc()
