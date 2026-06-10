{.push raises: [].}

import libp2p/[peerinfo, switch]

import ./peers

proc constructMultiaddrStr*(wireaddr: MultiAddress, peerId: PeerId): string =
  # Constructs a multiaddress with both wire address and p2p identity
  return $wireaddr & "/p2p/" & $peerId

proc constructMultiaddrStr*(peerInfo: PeerInfo): string =
  # Constructs a multiaddress with both location (wire) address and p2p identity
  if peerInfo.listenAddrs.len == 0:
    return ""
  return constructMultiaddrStr(peerInfo.listenAddrs[0], peerInfo.peerId)

proc constructMultiaddrStr*(remotePeerInfo: RemotePeerInfo): string =
  # Constructs a multiaddress with both location (wire) address and p2p identity
  if remotePeerInfo.addrs.len == 0:
    return ""
  return constructMultiaddrStr(remotePeerInfo.addrs[0], remotePeerInfo.peerId)
