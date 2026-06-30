## Waku layer API — peer management operations.
{.push raises: [].}

import std/[options, sequtils, strutils]
import results, chronos, chronicles
import libp2p/[peerid, peerstore]

import logos_delivery/waku/waku
import logos_delivery/waku/[waku_core, node/waku_node, node/peer_manager]

type PeerConnInfo* = object ## structured connected-peer info for the api boundary
  peerId*: string
  protocols*: seq[string]
  addresses*: seq[string]

proc connect*(
    self: Waku, peers: seq[string], timeoutMs: uint32
): Future[Result[bool, string]] {.async.} =
  try:
    await self.node.connectToNodes(peers.mapIt(strip(it)), source = "static")
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc disconnectPeerById*(
    self: Waku, peerId: string
): Future[Result[bool, string]] {.async.} =
  try:
    let pId = PeerId.init(peerId).valueOr:
      return err($error)
    await self.node.peerManager.disconnectNode(pId)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc disconnectAllPeers*(self: Waku): Future[Result[bool, string]] {.async.} =
  try:
    await self.node.peerManager.disconnectAllPeers()
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc dialPeer*(
    self: Waku, peerAddr: string, protocol: string, timeoutMs: int
): Future[Result[bool, string]] {.async.} =
  try:
    let remotePeerInfo = parsePeerInfo(peerAddr).valueOr:
      return err($error)
    let conn = await self.node.peerManager.dialPeer(remotePeerInfo, protocol)
    if conn.isNone():
      return err("failed dialing peer")
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc dialPeerById*(
    self: Waku, peerId: string, protocol: string, timeoutMs: int
): Future[Result[bool, string]] {.async.} =
  try:
    let pId = PeerId.init(peerId).valueOr:
      return err($error)
    let conn = await self.node.peerManager.dialPeer(pId, protocol)
    if conn.isNone():
      return err("failed dialing peer")
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc peerIdsFromPeerstore*(self: Waku): Future[Result[seq[string], string]] {.async.} =
  try:
    return ok(self.node.peerManager.switch.peerStore.peers().mapIt($it.peerId))
  except CatchableError as e:
    return err(e.msg)

proc connectedPeersInfo*(
    self: Waku
): Future[Result[seq[PeerConnInfo], string]] {.async.} =
  ## Structured info (protocols, addresses) for every connected peer.
  try:
    var infos: seq[PeerConnInfo]
    for peer in self.node.peerManager.switch.peerStore.peers():
      if peer.connectedness == Connected:
        infos.add(
          PeerConnInfo(
            peerId: $peer.peerId,
            protocols: peer.protocols,
            addresses: peer.addrs.mapIt($it),
          )
        )
    return ok(infos)
  except CatchableError as e:
    return err(e.msg)

proc connectedPeers*(self: Waku): Future[Result[seq[string], string]] {.async.} =
  try:
    let (inPeerIds, outPeerIds) = self.node.peerManager.connectedPeers()
    return ok(concat(inPeerIds, outPeerIds).mapIt($it))
  except CatchableError as e:
    return err(e.msg)

proc peerIdsByProtocol*(
    self: Waku, protocol: string
): Future[Result[seq[string], string]] {.async.} =
  try:
    return ok(
      self.node.peerManager.switch.peerStore
        .peers(protocol)
        .filterIt(it.connectedness == Connected)
        .mapIt($it.peerId)
    )
  except CatchableError as e:
    return err(e.msg)
