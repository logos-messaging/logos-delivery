import std/[sequtils, strutils, tables]
import chronicles, chronos, results, options, json, ffi
import waku/factory/waku, waku/node/waku_node, waku/node/peer_manager, ../declare_lib

type PeerInfo = object
  protocols: seq[string]
  addresses: seq[string]

proc waku_get_peerids_from_peerstore(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## returns a comma-separated string of peerIDs
  let peerIDs =
    ctx.myLib[].node.peerManager.switch.peerStore.peers().mapIt($it.peerId).join(",")
  return ok(peerIDs)

proc waku_connect(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    peerMultiAddr: cstring,
    timeoutMs: cuint,
) {.ffi.} =
  let peers = ($peerMultiAddr).split(",").mapIt(strip(it))
  await ctx.myLib[].node.connectToNodes(peers, source = "static")
  return ok("")

proc waku_disconnect_peer_by_id(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer, peerId: cstring
) {.ffi.} =
  let pId = PeerId.init($peerId).valueOr:
    error "DISCONNECT_PEER_BY_ID failed", error = $error
    return err($error)
  await ctx.myLib[].node.peerManager.disconnectNode(pId)
  return ok("")

proc waku_disconnect_all_peers(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  await ctx.myLib[].node.peerManager.disconnectAllPeers()
  return ok("")

proc waku_dial_peer(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    peerMultiAddr: cstring,
    protocol: cstring,
    timeoutMs: cuint,
) {.ffi.} =
  let remotePeerInfo = parsePeerInfo($peerMultiAddr).valueOr:
    error "DIAL_PEER failed", error = $error
    return err($error)
  let conn = await ctx.myLib[].node.peerManager.dialPeer(remotePeerInfo, $protocol)
  if conn.isNone():
    let msg = "failed dialing peer"
    error "DIAL_PEER failed", error = msg, peerId = $remotePeerInfo.peerId
    return err(msg)
  return ok("")

proc waku_dial_peer_by_id(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    peerId: cstring,
    protocol: cstring,
    timeoutMs: cuint,
) {.ffi.} =
  let pId = PeerId.init($peerId).valueOr:
    error "DIAL_PEER_BY_ID failed", error = $error
    return err($error)
  let conn = await ctx.myLib[].node.peerManager.dialPeer(pId, $protocol)
  if conn.isNone():
    let msg = "failed dialing peer"
    error "DIAL_PEER_BY_ID failed", error = msg, peerId = $peerId
    return err(msg)

  return ok("")

proc waku_get_connected_peers_info(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## returns a JSON string mapping peerIDs to objects with protocols and addresses

  var peersMap = initTable[string, PeerInfo]()
  let peers = ctx.myLib[].node.peerManager.switch.peerStore.peers().filterIt(
      it.connectedness == Connected
    )

  # Build a map of peer IDs to peer info objects
  for peer in peers:
    let peerIdStr = $peer.peerId
    peersMap[peerIdStr] =
      PeerInfo(protocols: peer.protocols, addresses: peer.addrs.mapIt($it))

  # Convert the map to JSON string
  let jsonObj = %*peersMap
  let jsonStr = $jsonObj
  return ok(jsonStr)

proc waku_get_connected_peers(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## returns a comma-separated string of peerIDs
  let
    (inPeerIds, outPeerIds) = ctx.myLib[].node.peerManager.connectedPeers()
    connectedPeerids = concat(inPeerIds, outPeerIds)

  return ok(connectedPeerids.mapIt($it).join(","))

proc waku_get_peerids_by_protocol(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    protocol: cstring,
) {.ffi.} =
  ## returns a comma-separated string of peerIDs that mount the given protocol
  let connectedPeers = ctx.myLib[].node.peerManager.switch.peerStore
    .peers($protocol)
    .filterIt(it.connectedness == Connected)
    .mapIt($it.peerId)
    .join(",")
  return ok(connectedPeers)
