{.push raises: [].}

import
  std/[options],
  chronos,
  chronicles,
  metrics,
  results,
  libp2p/protocols/ping,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/utility

import ../waku_node, ../peer_manager
import libp2p/crypto/rng as libp2p_rng

logScope:
  topics = "waku node ping api"

proc mountLibp2pPing*(node: WakuNode) {.async: (raises: []).} =
  info "mounting libp2p ping protocol"

  try:
    # libp2p 1.15.3: Ping.new now expects libp2p's `Rng` (ref object
    # wrapping a ref HmacDrbgContext).  Wrap the node's BearSSL rng.
    node.libp2pPing = Ping.new(rng = libp2p_rng.newBearSslRng(node.rng))
  except Exception as e:
    error "failed to create ping", error = getCurrentExceptionMsg()

  if node.started:
    # Node has started already. Let's start ping too.
    try:
      await node.libp2pPing.start()
    except CatchableError:
      error "failed to start libp2pPing", error = getCurrentExceptionMsg()

  try:
    node.switch.mount(node.libp2pPing)
  except LPError:
    error "failed to mount libp2pPing", error = getCurrentExceptionMsg()

proc pingPeer(node: WakuNode, peerId: PeerId): Future[Result[void, string]] {.async.} =
  ## Ping a single peer and return the result

  try:
    # Establish a stream
    let stream = (await node.peerManager.dialPeer(peerId, PingCodec)).valueOr:
      error "pingPeer: failed dialing peer", peerId = peerId
      return err("pingPeer failed dialing peer peerId: " & $peerId)
    defer:
      # Always close the stream
      try:
        await stream.close()
      except CatchableError as e:
        info "Error closing ping connection", peerId = peerId, error = e.msg

    # Perform ping
    let pingDuration = await node.libp2pPing.ping(stream)

    trace "Ping successful", peerId = peerId, duration = pingDuration
    return ok()
  except CatchableError as e:
    error "pingPeer: exception raised pinging peer", peerId = peerId, error = e.msg
    return err("pingPeer: exception raised pinging peer: " & e.msg)

# Returns the number of succesful pings performed
proc parallelPings*(node: WakuNode, peerIds: seq[PeerId]): Future[int] {.async.} =
  if len(peerIds) == 0:
    return 0

  var pingFuts: seq[Future[Result[void, string]]]

  # Create ping futures for each peer
  for i, peerId in peerIds:
    let fut = pingPeer(node, peerId)
    pingFuts.add(fut)

  # Wait for all pings to complete
  discard await allFutures(pingFuts).withTimeout(5.seconds)

  var successCount = 0
  for fut in pingFuts:
    if not fut.completed() or fut.failed():
      continue

    let res = fut.read()
    if res.isOk():
      successCount.inc()

  return successCount
