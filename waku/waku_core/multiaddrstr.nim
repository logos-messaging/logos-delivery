{.push raises: [].}

import std/strutils
import libp2p/[peerinfo, switch]

import ./peers

proc constructMultiaddrStr*(wireaddr: MultiAddress, peerId: PeerId): string =
  # Constructs a multiaddress with both wire address and p2p identity
  return $wireaddr & "/p2p/" & $peerId

proc firstAddr(addrs: seq[MultiAddress]): MultiAddress =
  for a in addrs:
    if "/quic-v1" notin $a:
      return a
  return addrs[0]

proc constructMultiaddrStr*(peerInfo: PeerInfo): string =
  if peerInfo.listenAddrs.len == 0:
    return ""
  return constructMultiaddrStr(firstAddr(peerInfo.listenAddrs), peerInfo.peerId)

proc constructMultiaddrStr*(remotePeerInfo: RemotePeerInfo): string =
  if remotePeerInfo.addrs.len == 0:
    return ""
  return constructMultiaddrStr(firstAddr(remotePeerInfo.addrs), remotePeerInfo.peerId)
