import logos_delivery/waku/compat/option_valueor
{.push raises: [].}

import std/[sequtils, sets]
import
  chronos,
  chronicles,
  results,
  stew/byteutils,
  libp2p/[peerid, multiaddress, switch],
  libp2p/extended_peer_record,
  libp2p/crypto/crypto,
  libp2p/crypto/rng,
  libp2p/crypto/curve25519,
  libp2p/protocols/service_discovery,
  libp2p/protocols/service_discovery/types,
  libp2p/protocols/kademlia/types,
  libp2p_mix/mix_protocol,
  libp2p_mix/curve25519

import
  logos_delivery/waku/waku_core,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/events/discovery_events

logScope:
  topics = "waku service discovery"

const
  DefaultServiceDiscoveryInterval* = chronos.seconds(60)
  DefaultRandomDiscoveryInterval* = chronos.seconds(60)

type WakuKademlia* = ref object
  protocol*: ServiceDiscovery
  peerManager: PeerManager
  randomLookupLoop: Future[void]
  serviceLookupLoop: Future[void]
  randomLookupInterval: Duration
  serviceLookupInterval: Duration
  servicesToDiscover: HashSet[string]
  servicesToAdvertise: HashSet[ServiceInfo]

proc extractMixPubKey(service: ServiceInfo): Option[Curve25519Key] =
  if service.id != MixProtocolID:
    return none(Curve25519Key)

  if service.data.len != Curve25519KeySize:
    error "invalid mix pub key length",
      expected = Curve25519KeySize,
      actual = service.data.len,
      dataHex = byteutils.toHex(service.data)
    return none(Curve25519Key)

  let key = intoCurve25519Key(service.data)

  return some(key)

proc remotePeerInfoFrom(record: ExtendedPeerRecord): Option[RemotePeerInfo] =
  if record.addresses.len == 0:
    error "missing addresses", peerId = record.peerId
    return none(RemotePeerInfo)

  let addrs = record.addresses.mapIt(it.address)
  if addrs.len == 0:
    error "no dialable addresses", peerId = record.peerId
    return none(RemotePeerInfo)

  var mixPubKey: Option[Curve25519Key] = none(Curve25519Key)
  for service in record.services:
    let key = extractMixPubKey(service).valueOr:
      continue
    mixPubKey = some(key)

    trace "successfully extracted mix pub key",
      peerId = record.peerId, keyHex = byteutils.toHex(mixPubKey.get())

    break

  return some(
    RemotePeerInfo.init(
      record.peerId, addrs = addrs, origin = PeerOrigin.Kademlia, mixPubKey = mixPubKey
    )
  )

proc lookupServicePeers*(
    self: WakuKademlia, service: string
): Future[Result[seq[RemotePeerInfo], string]] {.async: (raises: []).} =
  if self.protocol.isNil():
    return err("cannot lookup service peers: service discovery not mounted")

  let serviceId = service.hashServiceId()

  let lookupCatch = catch:
    (await self.protocol.lookup(serviceId))

  let lookupResult = lookupCatch.valueOr:
    return err("service peer lookup failed: " & error.msg)

  let advertisements = lookupResult.valueOr:
    return err("service peer lookup failed: " & lookupResult.error)

  var discovered: seq[RemotePeerInfo]
  for ad in advertisements:
    let record = ad.data
    let peerInfo = remotePeerInfoFrom(record).valueOr:
      continue

    self.peerManager.addPeer(peerInfo, PeerOrigin.Kademlia)

    debug "peer added via service discovery",
      service,
      peerId = $peerInfo.peerId,
      addresses = peerInfo.addrs.mapIt($it),
      protocols = peerInfo.protocols

    discovered.add(peerInfo)

  debug "service lookup complete", service, found = discovered.len

  return ok(discovered)

proc runRandomLookupLoop(self: WakuKademlia) {.async: (raises: [CancelledError]).} =
  debug "periodic random lookup started", interval = $self.randomLookupInterval

  while true:
    await sleepAsync(self.randomLookupInterval)

    let recordsRes = catch:
      (await self.protocol.lookupRandom())

    let records = recordsRes.valueOr:
      error "random lookup failed", error
      continue

    var discoveredPeers: seq[RemotePeerInfo]
    for record in records:
      let peerInfo = remotePeerInfoFrom(record).valueOr:
        continue

      self.peerManager.addPeer(peerInfo, PeerOrigin.Kademlia)

      debug "peer added via random walk",
        peerId = $peerInfo.peerId,
        addresses = peerInfo.addrs.mapIt($it),
        protocols = peerInfo.protocols

      discoveredPeers.add(peerInfo)

    if discoveredPeers.len > 0:
      PeersDiscoveredEvent.emit(peers = discoveredPeers)

    debug "random lookup complete", found = discoveredPeers.len

proc runServiceLookupLoop(self: WakuKademlia) {.async: (raises: [CancelledError]).} =
  debug "periodic service lookup started",
    interval = $self.serviceLookupInterval, services = self.servicesToDiscover

  while true:
    await sleepAsync(self.serviceLookupInterval)

    for service in self.servicesToDiscover:
      let discovered = (await self.lookupServicePeers(service)).valueOr:
        error "service lookup failed", service, error
        continue

      if discovered.len > 0:
        PeersDiscoveredEvent.emit(peers = discovered)

proc new*(
    T: type WakuKademlia,
    switch: Switch,
    peerManager: PeerManager,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])],
    servicesToAdvertise: seq[ServiceInfo],
    servicesToDiscover: seq[string],
    randomLookupInterval: Duration = DefaultRandomDiscoveryInterval,
    serviceLookupInterval: Duration = DefaultServiceDiscoveryInterval,
    rng: Rng,
    kadDhtConfig: KadDHTConfig = KadDHTConfig.new(),
    discoConfig: ServiceDiscoveryConfig = ServiceDiscoveryConfig.new(),
    clientMode: bool = false,
    xprPublishing: bool = true,
): Result[T, string] =
  if bootstrapNodes.len == 0:
    debug "creating service discovery as seed node (no bootstrap nodes)"

  let protocol = ServiceDiscovery.new(
    switch,
    bootstrapNodes = bootstrapNodes,
    config = kadDhtConfig,
    rng = rng,
    client = clientMode,
    services = servicesToAdvertise,
    discoConfig = discoConfig,
    xprPublishing = xprPublishing,
  )

  let self = WakuKademlia(
    protocol: protocol,
    peerManager: peerManager,
    randomLookupInterval: randomLookupInterval,
    serviceLookupInterval: serviceLookupInterval,
    servicesToDiscover: servicesToDiscover.toHashSet(),
    servicesToAdvertise: servicesToAdvertise.toHashSet(),
  )

  return ok(self)

proc start*(self: WakuKademlia) {.async: (raises: []).} =
  for serviceId in self.servicesToDiscover:
    discard self.protocol.registerInterest(serviceId)

  if self.randomLookupLoop.isNil():
    self.randomLookupLoop = self.runRandomLookupLoop()

  if self.serviceLookupLoop.isNil():
    self.serviceLookupLoop = self.runServiceLookupLoop()

  info "kademlia discovery started"

proc stop*(self: WakuKademlia) {.async: (raises: []).} =
  if not self.serviceLookupLoop.isNil():
    await self.serviceLookupLoop.cancelAndWait()
    self.serviceLookupLoop = nil

  if not self.randomLookupLoop.isNil():
    await self.randomLookupLoop.cancelAndWait()
    self.randomLookupLoop = nil

  info "kademlia discovery stopped"

proc addServiceToDiscover*(self: WakuKademlia, service: string) =
  if not self.servicesToDiscover.containsOrIncl(service):
    discard self.protocol.registerInterest(service)
    debug "added service to discover", service

proc addServiceToAdvertise*(self: WakuKademlia, service: ServiceInfo) =
  if not self.servicesToAdvertise.containsOrIncl(service):
    self.protocol.startAdvertising(service)
    debug "added service to advertise", service = service.id

proc removeServiceToDiscover*(self: WakuKademlia, service: string) =
  if not self.servicesToDiscover.missingOrExcl(service):
    self.protocol.unregisterInterest(service)
    debug "removed service to discover", service

proc removeServiceToAdvertise*(
    self: WakuKademlia, service: ServiceInfo
) {.async: (raises: [CancelledError]).} =
  if not self.servicesToAdvertise.missingOrExcl(service):
    await self.protocol.stopAdvertising(service.id)
    debug "removed service to advertise", service = service.id
