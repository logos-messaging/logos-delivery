{.push raises: [].}

import std/sequtils
import
  chronos,
  chronicles,
  results,
  stew/byteutils,
  libp2p/[peerid, multiaddress, switch],
  libp2p/extended_peer_record,
  libp2p/crypto/curve25519,
  libp2p/protocols/service_discovery,
  libp2p/protocols/service_discovery/types as sd_types,
  libp2p/protocols/mix/mix_protocol

import
  waku/waku_core,
  waku/node/peer_manager,
  waku/events/discovery_events,
  waku/factory/waku_conf

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
  servicesToDiscover: seq[string]
  servicesToAdvertise: seq[ServiceInfo]

proc extractMixPubKey(service: ServiceInfo): Opt[Curve25519Key] =
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

proc remotePeerInfoFrom(record: ExtendedPeerRecord): Opt[RemotePeerInfo] =
  if record.addresses.len == 0:
    error "missing addresses", peerId = record.peerId
    return none(RemotePeerInfo)

  let addrs = record.addresses.mapIt(it.address)
  if addrs.len == 0:
    error "no dialable addresses", peerId = record.peerId
    return none(RemotePeerInfo)

  var mixPubKey = none(Curve25519Key)
  for service in record.services:
    mixPubKey = extractMixPubKey(service).valueOr:
      continue

    trace "successfully extracted mix pub key",
      peerId = record.peerId, keyHex = byteutils.toHex(mixPubKey.get())

    break

  return some(
    RemotePeerInfo.init(
      record.peerId, addrs = addrs, origin = PeerOrigin.Kademlia, mixPubKey = mixPubKey
    )
  )

proc lookupServicePeers*(
    self: WakuKademlia, serviceId: string
): Future[Result[seq[RemotePeerInfo], string]] {.async: (raises: []).} =
  if self.protocol.isNil():
    return err("cannot lookup service peers: service discovery not mounted")

  let serviceInfo = ServiceInfo(id: serviceId, data: @[])

  let lookupCatch = catch:
    (await self.protocol.lookup(serviceInfo))

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
    discovered.add(peerInfo)

  debug "service lookup complete", serviceId, found = discovered.len
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
      discoveredPeers.add(peerInfo)

    if discoveredPeers.len > 0:
      PeersDiscoveredEvent.emit(peers = discoveredPeers)

    debug "random lookup complete", found = discoveredPeers.len

proc runServiceLookupLoop(self: WakuKademlia) {.async: (raises: [CancelledError]).} =
  debug "periodic service lookup started",
    interval = $self.serviceLookupInterval, services = self.servicesToDiscover

  while true:
    await sleepAsync(self.serviceLookupInterval)

    if self.servicesToDiscover.len == 0:
      continue

    for serviceId in self.servicesToDiscover:
      let discovered = (await self.lookupServicePeers(serviceId)).valueOr:
        error "service lookup failed", serviceId, error
        continue

      if discovered.len > 0:
        PeersDiscoveredEvent.emit(peers = discovered)

proc new*(
    T: type WakuKademlia,
    switch: Switch,
    peerManager: PeerManager,
    config: KademliaDiscoveryConf,
): Result[T, string] =
  if config.bootstrapNodes.len == 0:
    debug "creating service discovery as seed node (no bootstrap nodes)"

  let protocol = ServiceDiscovery.new(
    switch, bootstrapNodes = config.bootstrapNodes, services = config.servicesToDiscover
  )

  let self = WakuKademlia(
    protocol: protocol,
    peerManager: peerManager,
    randomLookupInterval: config.randomLookupInterval,
    serviceLookupInterval: config.serviceLookupInterval,
    servicesToDiscover: config.servicesToDiscover,
    servicesToAdvertise: config.servicesToAdvertise,
  )

  return ok(self)

proc start*(self: WakuKademlia) {.async: (raises: []).} =
  for serviceId in self.servicesToDiscover:
    discard self.protocol.startDiscovering(serviceId)

  for serviceInfo in self.servicesToAdvertise:
    self.protocol.addProvidedService(serviceInfo)

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
