{.push raises: [].}

## This node's signed extended peer record for one service.
##
## The in-process kademlia host never needs this: nim-libp2p builds the record
## from the switch it runs on, which is the delivery node's. The plugin host
## runs on libp2p_module's switch, so a record built there would carry
## libp2p_module's peer id and could not be dialled as this node. This is the
## record the plugin publishes instead, signed with this node's key.
##
## Registrars file a record only under the service key it was REGISTERed with,
## and lookups read one shelf: the record is found under `serviceId` alone.
## `extraServices` are listed in the same record for whoever reads it
## there, as the mix key of a delivery node is. They cost no registration of
## their own, and a second registration is what a registrar makes a node wait
## for.

import std/sequtils
import results
import libp2p/[peerinfo, crypto/crypto, extended_peer_record, signed_envelope]
import logos_delivery/waku/discovery/peer_discovery_interface

proc signedServiceRecord*(
    peerInfo: PeerInfo,
    key: crypto.PrivateKey,
    serviceId: string,
    data: seq[byte],
    extraServices: seq[DiscoveredService] = @[],
): Result[seq[byte], string] =
  if peerInfo.isNil():
    return err("signed record: node has no peer info")
  if peerInfo.addrs.len == 0:
    return err("signed record: node has no addresses to advertise")

  let record = ExtendedPeerRecord.init(
    peerInfo.peerId,
    peerInfo.addrs,
    services =
      @[ServiceInfo(id: serviceId, data: Opt.some(data))] &
      extraServices.mapIt(ServiceInfo(id: it.id, data: Opt.some(it.data))),
  )
  let signed = SignedExtendedPeerRecord.init(key, record).valueOr:
    return err("signed record: cannot sign: " & $error)
  ok(signed.encode())
