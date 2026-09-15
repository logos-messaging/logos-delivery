{.push raises: [].}

import std/[sequtils, sets]
import
  chronos,
  chronicles,
  results,
  stew/byteutils,
  libp2p/[peerid, multiaddress, switch, extended_peer_record],
  libp2p/crypto/crypto,
  libp2p/crypto/rng,
  libp2p/crypto/curve25519,
  libp2p/protocols/service_discovery,
  libp2p/protocols/service_discovery/types,
  libp2p/protocols/kademlia/types,
  libp2p/protocols/kademlia/key_value,
  libp2p_mix/mix_protocol

import
  logos_delivery/waku/waku_core,
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/api/events/discovery_events

# `WakuKademlia.new` is generic, so `ServiceDiscovery.new` instantiates in the
# caller, which needs `hash`/`==` of the distinct kademlia `Key` in scope.
export key_value.hash, key_value.`==`

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
    ## Configured services. `start` advertises them, `stop` stops advertising them.

# Upstream ServiceDiscovery has one set for configured and advertised services:
# its start asserts when a first advertisement fails, and its stop keeps the
# advertised status. So the protocol gets no services at construction, `start`
# advertises the configured set, and `stop` stops advertising it. Remove when
# upstream fixes both.

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

proc extractMixPubKey*(service: ServiceInfo): Opt[Curve25519Key] =
  if service.id != MixProtocolID:
    return Opt.none(Curve25519Key)

  let data = service.data.get(@[])
  if data.len != Curve25519KeySize:
    trace "Invalid mix pub key length",
      expected = Curve25519KeySize, actual = data.len, dataHex = byteutils.toHex(data)
    return Opt.none(Curve25519Key)

  let key = intoCurve25519Key(data)

  return Opt.some(key)

proc remotePeerInfoFrom*(record: ExtendedPeerRecord): Opt[RemotePeerInfo] =
  if record.addresses.len == 0:
    trace "Missing addresses", peerId = record.peerId
    return Opt.none(RemotePeerInfo)

  let addrs = record.addresses.mapIt(it.address)
  if addrs.len == 0:
    trace "No dialable addresses", peerId = record.peerId
    return Opt.none(RemotePeerInfo)

  let protocols = record.services.mapIt(it.id)

  var mixPubKey: Opt[Curve25519Key] = Opt.none(Curve25519Key)
  for service in record.services:
    let key = extractMixPubKey(service).valueOr:
      continue
    mixPubKey = Opt.some(key)

    trace "Successfully extracted mix pub key",
      peerId = record.peerId, keyHex = byteutils.toHex(mixPubKey.get())

    break

  return Opt.some(
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

    debug "Peer added via service discovery",
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

  debug "Service lookup complete", service, found = discovered.len

  return ok(discovered)

proc runRandomLookupLoop(self: WakuKademlia) {.async: (raises: [CancelledError]).} =
  debug "Periodic random lookup started", interval = $self.randomLookupInterval

  while true:
    await sleepAsync(self.randomLookupInterval)

    let recordsRes = catch:
      (await self.protocol.lookupRandom())

    let records = recordsRes.valueOr:
      debug "Random lookup failed", error
      continue

    let discovered = self.processRecords(records, "random walk")

    if discovered.len > 0:
      PeersDiscoveredEvent.emit(peers = discovered)

    debug "Random lookup complete", found = discovered.len

proc runServiceLookupLoop(self: WakuKademlia) {.async: (raises: [CancelledError]).} =
  debug "Periodic service lookup started",
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
        debug "Service lookup failed", error
        continue

      let peerInfos = res.valueOr:
        debug "Service lookup failed", error
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
    debug "Creating service discovery as seed node (no bootstrap nodes)"

  ## `start` advertises the configured set, see above.
  let protocol = ServiceDiscovery.new(
    switch,
    bootstrapNodes = bootstrapNodes,
    config = kadDhtConfig,
    rng = rng,
    client = clientMode,
    services = @[],
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

proc advertiseConfiguredServices(self: WakuKademlia) =
  ## Advertises the configured services not advertised yet. Failures stay configured.
  var added = false
  for service in self.servicesToAdvertise:
    if service in self.protocol.services:
      continue
    self.protocol.startAdvertising(service).isOkOr:
      warn "Failed to advertise configured service", service = service.id, error = error
      continue
    added = true

  ## Republish the self record: it listed no services at protocol start.
  if added:
    self.protocol.addressChanged.fire()

proc start*(self: WakuKademlia) {.async: (raises: []).} =
  for serviceId in self.servicesToDiscover:
    discard self.protocol.registerInterest(serviceId)

  ## Runs after switch.start, so the record has the announced addresses.
  self.advertiseConfiguredServices()

  if self.randomLookupLoop.isNil():
    self.randomLookupLoop = self.runRandomLookupLoop()

  if self.serviceLookupLoop.isNil():
    self.serviceLookupLoop = self.runServiceLookupLoop()

  info "Kademlia discovery started"

proc stop*(self: WakuKademlia) {.async: (raises: []).} =
  if not self.serviceLookupLoop.isNil():
    await self.serviceLookupLoop.cancelAndWait()
    self.serviceLookupLoop = nil

  if not self.randomLookupLoop.isNil():
    await self.randomLookupLoop.cancelAndWait()
    self.randomLookupLoop = nil

  ## Stopped services stay marked as provided upstream and a restart rejects
  ## them, so stop advertising them here. noCancel: a cancelled stop must finish.
  for service in self.servicesToAdvertise.toSeq():
    await noCancel self.protocol.stopAdvertising(service.id)

  info "Kademlia discovery stopped"

proc addServiceToDiscover*(self: WakuKademlia, service: string) =
  if not self.servicesToDiscover.containsOrIncl(service):
    discard self.protocol.registerInterest(service)
    debug "Added service to discover", service

proc addServiceToAdvertise*(self: WakuKademlia, service: ServiceInfo) =
  if service notin self.servicesToAdvertise:
    self.protocol.startAdvertising(service).isOkOr:
      warn "Failed to advertise service", service = service.id, error = error
      return
    self.servicesToAdvertise.incl(service)
    debug "Added service to advertise", service = service.id

proc removeServiceToDiscover*(self: WakuKademlia, service: string) =
  if not self.servicesToDiscover.missingOrExcl(service):
    self.protocol.unregisterInterest(service)
    debug "Removed service to discover", service

proc removeServiceToAdvertise*(
    self: WakuKademlia, service: ServiceInfo
) {.async: (raises: [CancelledError]).} =
  if not self.servicesToAdvertise.missingOrExcl(service):
    await self.protocol.stopAdvertising(service.id)
    debug "Removed service to advertise", service = service.id
