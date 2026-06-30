import std/[strutils, tables, json]
import chronicles, chronos, results, ffi
import logos_delivery, library/declare_lib

type PeerInfo = object
  protocols: seq[string]
  addresses: seq[string]

proc waku_get_peerids_from_peerstore(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## returns a comma-separated string of peerIDs
  let peerIds = (await ctx.myLib[].waku.peerIdsFromPeerstore()).valueOr:
    return err(error)
  return ok(peerIds.join(","))

proc waku_connect(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    peerMultiAddr: cstring,
    timeoutMs: cuint,
) {.ffi.} =
  let peers = ($peerMultiAddr).split(",")
  (await ctx.myLib[].waku.connect(peers, uint32(timeoutMs))).isOkOr:
    return err(error)
  return ok("")

proc waku_disconnect_peer_by_id(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    peerId: cstring,
) {.ffi.} =
  (await ctx.myLib[].waku.disconnectPeerById($peerId)).isOkOr:
    error "DISCONNECT_PEER_BY_ID failed", error = error
    return err(error)
  return ok("")

proc waku_disconnect_all_peers(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  (await ctx.myLib[].waku.disconnectAllPeers()).isOkOr:
    return err(error)
  return ok("")

proc waku_dial_peer(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    peerMultiAddr: cstring,
    protocol: cstring,
    timeoutMs: cuint,
) {.ffi.} =
  (await ctx.myLib[].waku.dialPeer($peerMultiAddr, $protocol, int(timeoutMs))).isOkOr:
    error "DIAL_PEER failed", error = error
    return err(error)
  return ok("")

proc waku_dial_peer_by_id(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    peerId: cstring,
    protocol: cstring,
    timeoutMs: cuint,
) {.ffi.} =
  (await ctx.myLib[].waku.dialPeerById($peerId, $protocol, int(timeoutMs))).isOkOr:
    error "DIAL_PEER_BY_ID failed", error = error
    return err(error)
  return ok("")

proc waku_get_connected_peers_info(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## returns a JSON string mapping peerIDs to objects with protocols and addresses
  let peers = (await ctx.myLib[].waku.connectedPeersInfo()).valueOr:
    return err(error)

  var peersMap = initTable[string, PeerInfo]()
  for peer in peers:
    peersMap[peer.peerId] =
      PeerInfo(protocols: peer.protocols, addresses: peer.addresses)

  return ok($(%*peersMap))

proc waku_get_connected_peers(
    ctx: ptr FFIContext[LogosDelivery], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## returns a comma-separated string of peerIDs
  let peerIds = (await ctx.myLib[].waku.connectedPeers()).valueOr:
    return err(error)
  return ok(peerIds.join(","))

proc waku_get_peerids_by_protocol(
    ctx: ptr FFIContext[LogosDelivery],
    callback: FFICallBack,
    userData: pointer,
    protocol: cstring,
) {.ffi.} =
  ## returns a comma-separated string of peerIDs that mount the given protocol
  let peerIds = (await ctx.myLib[].waku.peerIdsByProtocol($protocol)).valueOr:
    return err(error)
  return ok(peerIds.join(","))
