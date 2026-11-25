{.push raises: [].}

## Conversions between backend-native peer representations and the neutral
## `DiscoveredPeer` DTO of the IPeerDiscovery interface.

import std/sequtils
import results
import logos_delivery/waku/discovery/peer_discovery_interface
import libp2p/[peerid, multiaddress]
# RemotePeerInfo.init defaults to `crypto.PublicKey()`, and a default
# expression is expanded in the caller's scope, so `crypto` must resolve here.
import libp2p/crypto/crypto
import logos_delivery/waku/discovery/delivery_advert
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
    peer: DiscoveredPeer, clusterId = Opt.none(uint16)
): Result[RemotePeerInfo, string] =
  ## The DTO back into the node's own peer type, for a backend whose source
  ## speaks the DTO rather than an ENR or a peer record. Mirrors
  ## `remotePeerInfoFrom` in the in-process kademlia backend: a peer with no
  ## dialable address is refused rather than stored. The codecs and shards its
  ## delivery payload claims are stored with it, see `advertisedServing`.
  let peerId = PeerId.init(peer.peerId).valueOr:
    return err("unparseable peer id " & peer.peerId & ": " & $error)

  var addrs: seq[MultiAddress]
  for address in peer.addrs:
    let maddr = MultiAddress.init(address).valueOr:
      return err("unparseable address " & address & ": " & $error)
    addrs.add(maddr)
  if addrs.len == 0:
    return err("no dialable address for peer " & peer.peerId)

  let (codecs, shards) = advertisedServing(peer.services, clusterId)
  ok(
    RemotePeerInfo.init(
      peerId,
      addrs = addrs,
      protocols = deduplicate(peer.services.mapIt(it.id) & codecs),
      shards = shards,
      origin = PeerOrigin.Kademlia,
      mixPubKey = advertisedMixKey(peer.services),
    )
  )
