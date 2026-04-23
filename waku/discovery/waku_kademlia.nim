{.push raises: [].}

import std/[options, sequtils]
import
  chronos,
  chronicles,
  results,
  libp2p/crypto/curve25519,
  libp2p/crypto/crypto,
  libp2p/protocols/mix/mix_protocol,
  libp2p/[peerid, multiaddress, switch],
  libp2p/extended_peer_record,
  libp2p/protocols/[kademlia, service_discovery],
  libp2p/protocols/service_discovery/types

import waku/waku_core, waku/node/peer_manager

logScope:
  topics = "waku kademlia"

const DefaultKademliaDiscoveryInterval* = chronos.seconds(60)

type WakuKademlia* = ref object
  protocol*: ServiceDiscovery
  peerManager: PeerManager
  loopInterval: Duration
  #periodicWalkFut: Future[void]
  periodicLookupFut: Future[void]

proc toRemotePeerInfo(record: ExtendedPeerRecord): Option[RemotePeerInfo] =
  debug "processing kademlia record",
    peerId = record.peerId,
    numAddresses = record.addresses.len,
    numServices = record.services.len,
    serviceIds = record.services.mapIt(it.id)

  if record.addresses.len == 0:
    trace "kademlia record missing addresses", peerId = record.peerId
    return none(RemotePeerInfo)

  let addrs = record.addresses.mapIt(it.address)
  if addrs.len == 0:
    trace "kademlia record produced no dialable addresses", peerId = record.peerId
    return none(RemotePeerInfo)

  let protocols = record.services.mapIt(it.id)

  var mixPubKey = none(Curve25519Key)
  for service in record.services:
    if service.id != MixProtocolID:
      continue

    if service.data.len != Curve25519KeySize:
      continue

    mixPubKey = some(intoCurve25519Key(service.data))
    break

  return some(
    RemotePeerInfo.init(
      record.peerId,
      addrs = addrs,
      protocols = protocols,
      origin = PeerOrigin.Kademlia,
      mixPubKey = mixPubKey,
    )
  )

#[ proc randomWalk*(
    self: WakuKademlia
): Future[seq[RemotePeerInfo]] {.async: (raises: []).} =
  let res = catch:
    await self.protocol.randomRecords()
  let records = res.valueOr:
    error "kademlia discovery lookup failed", error = res.error.msg
    return

  var peerInfos = newSeqOfCap[RemotePeerInfo](records.len)
  for record in records:
    let peerInfo = toRemotePeerInfo(record).valueOr:
      continue

    self.peerManager.addPeer(peerInfo, PeerOrigin.Kademlia)

    debug "peer added via random walk",
      peerId = $peerInfo.peerId,
      addresses = peerInfo.addrs.mapIt($it),
      protocols = peerInfo.protocols

    peerInfos.add(peerInfo)

  return peerInfos ]#

proc lookup*(
    self: WakuKademlia, codec: string
): Future[seq[RemotePeerInfo]] {.async: (raises: []).} =
  let serviceId = hashServiceId(codec)

  let catchRes = catch:
    await self.protocol.lookup(serviceId)
  let lookupRes = catchRes.valueOr:
    error "kademlia discovery lookup failed", error = catchRes.error.msg
    return

  let ads = lookupRes.valueOr:
    error "kademlia discovery lookup failed", error
    return

  var peerInfos = newSeqOfCap[RemotePeerInfo](ads.len)
  for ad in ads:
    let peerInfo = toRemotePeerInfo(ad.data).valueOr:
      continue

    self.peerManager.addPeer(peerInfo, PeerOrigin.Kademlia)

    debug "peer added via service discovery",
      service = codec,
      peerId = $peerInfo.peerId,
      addresses = peerInfo.addrs.mapIt($it),
      protocols = peerInfo.protocols

    peerInfos.add(peerInfo)

  return peerInfos

#[ proc periodicRandomWalk(
    self: WakuKademlia, interval: Duration
) {.async: (raises: [CancelledError]).} =
  debug "periodic random walk started", interval = interval

  while true:
    await sleepAsync(interval)

    discard await self.randomWalk() ]#

proc periodicLookup(
    self: WakuKademlia, interval: Duration
) {.async: (raises: [CancelledError]).} =
  debug "periodic service lookup started", interval = interval

  while true:
    await sleepAsync(interval)

    # For testing lets use only one hard-coded service
    # Same as the advertised one
    let peers = await self.lookup("delivery")

    debug "lookup complete", peer_found = peers.len

proc new*(
    T: type WakuKademlia,
    switch: Switch,
    peerManager: PeerManager,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])],
    providedServices: var seq[ServiceInfo],
    loopInterval: Duration = DefaultKademliaDiscoveryInterval,
    xprPublishing: bool = false,
): T =
  if bootstrapNodes.len == 0:
    debug "creating kademlia discovery as seed node (no bootstrap nodes)"

  let kademlia = ServiceDiscovery.new(
    switch,
    bootstrapNodes = bootstrapNodes,
    config =
      KadDHTConfig.new(validator = ExtEntryValidator(), selector = ExtEntrySelector()),
    services = providedServices,
    xprPublishing = xprPublishing,
  )

  return WakuKademlia(
    protocol: kademlia, peerManager: peerManager, loopInterval: loopInterval
  )

proc start*(self: WakuKademlia) =
  #[ if self.periodicWalkFut.isNil():
    self.periodicWalkFut = self.periodicRandomWalk(self.loopInterval) ]#

  if self.periodicLookupFut.isNil():
    self.periodicLookupFut = self.periodicLookup(self.loopInterval)

proc stop*(self: WakuKademlia) =
  #[ if not self.periodicWalkFut.isNil():
    self.periodicWalkFut.cancelSoon()
    self.periodicWalkFut = nil ]#

  if not self.periodicLookupFut.isNil():
    self.periodicLookupFut.cancelSoon()
    self.periodicLookupFut = nil
