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
import libp2p/crypto/curve25519
import libp2p_mix/mix_protocol
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

proc mixPubKeyOf(peer: DiscoveredPeer): Opt[Curve25519Key] =
  ## The mix key rides in the advertised payload of the mix service, the same
  ## place the in-process backend reads it from.
  for service in peer.services:
    if service.id != MixProtocolID or service.data.len != Curve25519KeySize:
      continue
    return Opt.some(intoCurve25519Key(service.data))
  Opt.none(Curve25519Key)

proc toRemotePeerInfo*(peer: DiscoveredPeer): Result[RemotePeerInfo, string] =
  ## The DTO back into the node's own peer type, for a backend whose source
  ## speaks the DTO rather than an ENR or a peer record. Mirrors
  ## `remotePeerInfoFrom` in the in-process kademlia backend: a peer with no
  ## dialable address is refused rather than stored.
  let peerId = PeerId.init(peer.peerId).valueOr:
    return err("unparseable peer id " & peer.peerId & ": " & $error)

  var addrs: seq[MultiAddress]
  for address in peer.addrs:
    let maddr = MultiAddress.init(address).valueOr:
      return err("unparseable address " & address & ": " & error)
    addrs.add(maddr)
  if addrs.len == 0:
    return err("no dialable address for peer " & peer.peerId)

  ok(
    RemotePeerInfo.init(
      peerId,
      addrs = addrs,
      protocols = peer.services.mapIt(it.id),
      origin = PeerOrigin.Kademlia,
      mixPubKey = mixPubKeyOf(peer),
    )
  )
