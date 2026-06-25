import std/sequtils

type ConnectedPeersInfoResponse {.ffi.} = object
  peers: seq[PeerConnInfoFFI]

proc get_peerids_from_peerstore*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  let ids = (await self.waku.peerIdsFromPeerstore()).valueOr:
    return err(error)
  return ok(ids.join(","))

proc connect_peers*(
    self: LogosDelivery, peers: seq[string], timeoutMs: uint32
): Future[Result[string, string]] {.ffi.} =
  ## `peers` are multiaddrs.
  (await self.waku.connect(peers, timeoutMs)).isOkOr:
    return err(error)
  return ok("")

proc disconnect_peer_by_id*(
    self: LogosDelivery, peerId: string
): Future[Result[string, string]] {.ffi.} =
  (await self.waku.disconnectPeerById(peerId)).isOkOr:
    return err(error)
  return ok("")

proc disconnect_all_peers*(
    self: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  (await self.waku.disconnectAllPeers()).isOkOr:
    return err(error)
  return ok("")

proc dial_peer*(
    self: LogosDelivery, peer: string, protocol: string, timeoutMs: int
): Future[Result[string, string]] {.ffi.} =
  ## `peer` is a multiaddr.
  (await self.waku.dialPeer(peer, protocol, timeoutMs)).isOkOr:
    return err(error)
  return ok("")

proc dial_peer_by_id*(
    self: LogosDelivery, peer: string, protocol: string, timeoutMs: int
): Future[Result[string, string]] {.ffi.} =
  ## `peer` is a peerId.
  (await self.waku.dialPeerById(peer, protocol, timeoutMs)).isOkOr:
    return err(error)
  return ok("")

proc get_connected_peers_info*(
    self: LogosDelivery
): Future[Result[ConnectedPeersInfoResponse, string]] {.ffi.} =
  let infos = (await self.waku.connectedPeersInfo()).valueOr:
    return err(error)
  return ok(
    ConnectedPeersInfoResponse(
      peers: infos.mapIt(
        PeerConnInfoFFI(
          peerId: it.peerId, protocols: it.protocols, addresses: it.addresses
        )
      )
    )
  )

proc get_connected_peers*(self: LogosDelivery): Future[Result[string, string]] {.ffi.} =
  let ids = (await self.waku.connectedPeers()).valueOr:
    return err(error)
  return ok(ids.join(","))

proc get_peerids_by_protocol*(
    self: LogosDelivery, protocol: string
): Future[Result[string, string]] {.ffi.} =
  let ids = (await self.waku.peerIdsByProtocol(protocol)).valueOr:
    return err(error)
  return ok(ids.join(","))
