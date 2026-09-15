{.push raises: [].}

## Conversions from backend-native peer representations to the neutral
## `DiscoveredPeer` DTO of the IPeerDiscovery interface.

import std/sequtils
import results
import logos_delivery/waku/discovery/peer_discovery_interface
import logos_delivery/waku/waku_core, logos_delivery/waku/waku_enr

proc toDiscoveredPeer*(rpi: RemotePeerInfo): DiscoveredPeer =
  let enrUri =
    if rpi.enr.isSome():
      rpi.enr.get().toUri()
    else:
      ""

  DiscoveredPeer(
    peerId: $rpi.peerId,
    addrs: rpi.addrs.mapIt($it),
    enr: enrUri,
    services: rpi.protocols.mapIt(DiscoveredService(id: it)),
  )

proc toDiscoveredPeer*(record: waku_enr.Record): Result[DiscoveredPeer, string] =
  let rpi = record.toRemotePeerInfo().valueOr:
    return err($error)
  var peer = rpi.toDiscoveredPeer()
  peer.enr = record.toUri()
  ok(peer)
