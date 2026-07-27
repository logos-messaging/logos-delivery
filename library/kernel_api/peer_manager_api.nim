import std/[strutils, tables, json]
import chronicles, chronos, results, ffi
import logos_delivery, library/declare_lib

type PeerInfo = object
  protocols: seq[string]
  addresses: seq[string]

proc waku_get_peerids_from_peerstore(
    ld: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## returns a comma-separated string of peerIDs
  let peerIds = (await ld.waku.peerIdsFromPeerstore()).valueOr:
    return err(error)
  return ok(peerIds.join(","))

proc waku_connect(
    ld: LogosDelivery, peerMultiAddr: cstring, timeoutMs: cuint
): Future[Result[string, string]] {.ffi.} =
  let peers = ($peerMultiAddr).split(",")
  (await ld.waku.connect(peers, uint32(timeoutMs))).isOkOr:
    return err(error)
  return ok("")

proc waku_disconnect_peer_by_id(
    ld: LogosDelivery, peerId: cstring
): Future[Result[string, string]] {.ffi.} =
  (await ld.waku.disconnectPeerById($peerId)).isOkOr:
    error "DISCONNECT_PEER_BY_ID failed", error = error
    return err(error)
  return ok("")

proc waku_disconnect_all_peers(
    ld: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  (await ld.waku.disconnectAllPeers()).isOkOr:
    return err(error)
  return ok("")

proc waku_dial_peer(
    ld: LogosDelivery, peerMultiAddr: cstring, protocol: cstring, timeoutMs: cuint
): Future[Result[string, string]] {.ffi.} =
  (await ld.waku.dialPeer($peerMultiAddr, $protocol, int(timeoutMs))).isOkOr:
    error "DIAL_PEER failed", error = error
    return err(error)
  return ok("")

proc waku_dial_peer_by_id(
    ld: LogosDelivery, peerId: cstring, protocol: cstring, timeoutMs: cuint
): Future[Result[string, string]] {.ffi.} =
  (await ld.waku.dialPeerById($peerId, $protocol, int(timeoutMs))).isOkOr:
    error "DIAL_PEER_BY_ID failed", error = error
    return err(error)
  return ok("")

proc waku_get_connected_peers_info(
    ld: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## returns a JSON string mapping peerIDs to objects with protocols and addresses
  let peers = (await ld.waku.connectedPeersInfo()).valueOr:
    return err(error)

  var peersMap = initTable[string, PeerInfo]()
  for peer in peers:
    peersMap[peer.peerId] =
      PeerInfo(protocols: peer.protocols, addresses: peer.addresses)

  return ok($(%*peersMap))

proc waku_get_connected_peers(
    ld: LogosDelivery
): Future[Result[string, string]] {.ffi.} =
  ## returns a comma-separated string of peerIDs
  let peerIds = (await ld.waku.connectedPeers()).valueOr:
    return err(error)
  return ok(peerIds.join(","))

proc waku_get_peerids_by_protocol(
    ld: LogosDelivery, protocol: cstring
): Future[Result[string, string]] {.ffi.} =
  ## returns a comma-separated string of peerIDs that mount the given protocol
  let peerIds = (await ld.waku.peerIdsByProtocol($protocol)).valueOr:
    return err(error)
  return ok(peerIds.join(","))
