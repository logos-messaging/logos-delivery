{.push raises: [].}

## Conversions between backend-native peer representations and the neutral
## `DiscoveredPeer` DTO of the IPeerDiscovery interface.

import std/sequtils
import results
import libp2p/[peerid, multiaddress, crypto/crypto, crypto/curve25519]
import libp2p_mix/mix_protocol
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

proc toRemotePeerInfo*(
    peer: DiscoveredPeer, origin: PeerOrigin
): Result[RemotePeerInfo, string] =
  ## The reverse direction, for backends whose host returns neutral DTOs. A
  ## mix service entry carrying a Curve25519 key becomes the peer's mix key.
  let peerId = PeerId.init(peer.peerId).valueOr:
    return err("invalid peer id " & peer.peerId & ": " & $error)

  var addrs: seq[MultiAddress]
  for a in peer.addrs:
    let ma = MultiAddress.init(a).valueOr:
      continue
    addrs.add(ma)
  if addrs.len == 0:
    return err("no dialable address for " & peer.peerId)

  var mixPubKey = Opt.none(Curve25519Key)
  for svc in peer.services:
    if svc.id == MixProtocolID and svc.data.len == Curve25519KeySize:
      mixPubKey = Opt.some(intoCurve25519Key(svc.data))
      break

  ok(
    RemotePeerInfo.init(
      peerId,
      addrs = addrs,
      protocols = peer.services.mapIt(it.id),
      origin = origin,
      mixPubKey = mixPubKey,
    )
  )
