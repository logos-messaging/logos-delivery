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
  libp2p/protocols/[kademlia, kad_disco],
  libp2p/protocols/kademlia_discovery/types as kad_types,
  libp2p/protocols/service_discovery/types

import waku/waku_core, waku/node/peer_manager

logScope:
  topics = "waku kademlia discovery"

const DefaultKademliaDiscoveryInterval* = chronos.seconds(10)

type WakuKademlia* = ref object
  protocol*: KademliaDiscovery
  peerManager: PeerManager
  intervalFut: Future[void]

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

proc runDiscoveryLoop(
    wk: WakuKademlia, interval: Duration
) {.async: (raises: [CancelledError]).} =
  info "kademlia discovery loop started", interval = interval

  while true:
    await sleepAsync(interval)

    let res = catch:
      await wk.protocol.randomRecords()
    let records = res.valueOr:
      error "kademlia discovery lookup failed", error = res.error.msg
      continue

    for record in records:
      let peerInfo = toRemotePeerInfo(record).valueOr:
        continue

      wk.peerManager.addPeer(peerInfo, PeerOrigin.Kademlia)

      debug "peer added via kademlia discovery",
        peerId = $peerInfo.peerId,
        addresses = peerInfo.addrs.mapIt($it),
        protocols = peerInfo.protocols

      #TODO peer added metric

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

    debug "peer added via kademlia discovery",
      peerId = $peerInfo.peerId,
      addresses = peerInfo.addrs.mapIt($it),
      protocols = peerInfo.protocols

    #TODO peer added metric

    peerInfos.add(peerInfo)

  return peerInfos

proc new*(
    T: type WakuKademlia,
    switch: Switch,
    peerManager: PeerManager,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])],
    providedServices: var seq[ServiceInfo],
): T =
  if bootstrapNodes.len == 0:
    info "creating kademlia discovery as seed node (no bootstrap nodes)"

  let kademlia = KademliaDiscovery.new(
    switch,
    bootstrapNodes = bootstrapNodes,
    config = KadDHTConfig.new(
      validator = kad_types.ExtEntryValidator(), selector = kad_types.ExtEntrySelector()
    ),
    services = providedServices,
  )

  info "kademlia service discovery created", bootstrapNodes = bootstrapNodes.len

  return WakuKademlia(protocol: kademlia, peerManager: peerManager)

proc start*(
    self: WakuKademlia, interval: Duration = DefaultKademliaDiscoveryInterval
) {.async: (raises: [CancelledError]).} =
  if self.protocol.started:
    warn "Starting kad-disco twice"
    return

  await self.protocol.start()

  self.intervalFut = self.runDiscoveryLoop(interval)

  info "kademlia discovery started"

proc stop*(self: WakuKademlia) {.async: (raises: []).} =
  if not self.protocol.started:
    return

  info "Stopping kademlia discovery"

  if not self.intervalFut.isNil():
    self.intervalFut.cancelSoon()
    self.intervalFut = nil

  if not self.protocol.isNil():
    await self.protocol.stop()

  info "Successfully stopped kademlia discovery"
