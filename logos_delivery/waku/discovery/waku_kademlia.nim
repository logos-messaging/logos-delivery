import logos_delivery/waku/compat/option_valueor
{.push raises: [].}

import std/[options, sequtils, sets]
import
  chronos,
  chronicles,
  results,
  stew/byteutils,
  libp2p/[peerid, multiaddress, switch, extended_peer_record],
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

type KademliaDiscoveryConf* = object
  bootstrapNodes*: seq[(PeerId, seq[MultiAddress])]
  servicesToAdvertise*: HashSet[ServiceInfo]
  servicesToDiscover*: HashSet[string]
  randomLookupInterval*: Duration
  serviceLookupInterval*: Duration
  kadDhtConfig*: KadDHTConfig
  discoConfig*: ServiceDiscoveryConfig
  clientMode*: bool
  xprPublishing*: bool

proc extractMixPubKey*(service: ServiceInfo): Option[Curve25519Key] =
  if service.id != MixProtocolID:
    return none(Curve25519Key)

  if service.data.len != Curve25519KeySize:
    trace "invalid mix pub key length",
      expected = Curve25519KeySize,
      actual = service.data.len,
      dataHex = byteutils.toHex(service.data)
    return none(Curve25519Key)

  let key = intoCurve25519Key(service.data)

  return some(key)

proc remotePeerInfoFrom*(record: ExtendedPeerRecord): Option[RemotePeerInfo] =
  if record.addresses.len == 0:
    trace "missing addresses", peerId = record.peerId
    return none(RemotePeerInfo)

  let addrs = record.addresses.mapIt(it.address)
  if addrs.len == 0:
    trace "no dialable addresses", peerId = record.peerId
    return none(RemotePeerInfo)

  let protocols = record.services.mapIt(it.id)

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
      record.peerId,
      addrs = addrs,
      protocols = protocols,
      origin = PeerOrigin.Kademlia,
      mixPubKey = mixPubKey,
    )
  )

proc processRecords(
    self: WakuKademlia, records: seq[ExtendedPeerRecord], source: string
): seq[RemotePeerInfo] =
  var discovered: seq[RemotePeerInfo]
  for record in records:
    let peerInfo = remotePeerInfoFrom(record).valueOr:
      continue

    self.peerManager.addPeer(peerInfo, PeerOrigin.Kademlia)

    debug "peer added via service discovery",
      source,
      peerId = $peerInfo.peerId,
      addresses = peerInfo.addrs.mapIt($it),
      protocols = peerInfo.protocols

    discovered.add(peerInfo)

  return discovered

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

  let records = advertisements.mapIt(it.data)

  let discovered = self.processRecords(records, "service lookup")

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

    let discovered = self.processRecords(records, "random walk")

    if discovered.len > 0:
      PeersDiscoveredEvent.emit(peers = discovered)

    debug "random lookup complete", found = discovered.len

proc runServiceLookupLoop(self: WakuKademlia) {.async: (raises: [CancelledError]).} =
  debug "periodic service lookup started",
    interval = $self.serviceLookupInterval, services = self.servicesToDiscover

  while true:
    await sleepAsync(self.serviceLookupInterval)

    let futs = self.servicesToDiscover.mapIt(self.lookupServicePeers(it))

    let finishedFuts = await allFinished(futs)

    var discovered: seq[RemotePeerInfo]
    for fut in finishedFuts:
      let catchRes = catch:
        fut.read()

      let res = catchRes.valueOr:
        error "service lookup failed", error
        continue

      let peerInfos = res.valueOr:
        error "service lookup failed", error
        continue

      for peerInfo in peerInfos:
        discovered.add(peerInfo)

    if discovered.len > 0:
      PeersDiscoveredEvent.emit(peers = discovered)

proc new*(
    T: type WakuKademlia,
    switch: Switch,
    peerManager: PeerManager,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])],
    servicesToAdvertise: HashSet[ServiceInfo],
    servicesToDiscover: HashSet[string],
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
    services = servicesToAdvertise.toSeq(),
    discoConfig = discoConfig,
    xprPublishing = xprPublishing,
  )

  let self = WakuKademlia(
    protocol: protocol,
    peerManager: peerManager,
    randomLookupInterval: randomLookupInterval,
    serviceLookupInterval: serviceLookupInterval,
    servicesToDiscover: servicesToDiscover,
    servicesToAdvertise: servicesToAdvertise,
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
