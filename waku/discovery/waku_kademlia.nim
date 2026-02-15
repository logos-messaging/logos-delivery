{.push raises: [].}

import std/[options, sequtils]
import
  chronos,
  chronicles,
  results,
  stew/byteutils,
  libp2p/[peerid, multiaddress, switch],
  libp2p/extended_peer_record,
  libp2p/crypto/curve25519,
  libp2p/protocols/[kademlia, kad_disco],
  libp2p/protocols/kademlia_discovery/types as kad_types,
  libp2p/protocols/mix/mix_protocol

import waku/waku_core, waku/node/peer_manager

logScope:
  topics = "waku extended kademlia discovery"

const
  DefaultExtendedKademliaDiscoveryInterval* = chronos.seconds(5)
  ExtendedKademliaDiscoveryStartupDelay* = chronos.seconds(5)

type
  MixNodePoolSizeProvider* = proc(): int {.gcsafe, raises: [].}
  NodeStartedProvider* = proc(): bool {.gcsafe, raises: [].}

  ExtendedKademliaDiscoveryParams* = object
    bootstrapNodes*: seq[(PeerId, seq[MultiAddress])]
    mixPubKey*: Option[Curve25519Key]
    advertiseMix*: bool = false

  WakuKademlia* = ref object
    protocol*: KademliaDiscovery
    peerManager: PeerManager
    discoveryLoop: Future[void]
    running*: bool
    getMixNodePoolSize: MixNodePoolSizeProvider
    isNodeStarted: NodeStartedProvider

proc new*(
    T: type WakuKademlia,
    switch: Switch,
    params: ExtendedKademliaDiscoveryParams,
    peerManager: PeerManager,
    getMixNodePoolSize: MixNodePoolSizeProvider = nil,
    isNodeStarted: NodeStartedProvider = nil,
): Result[T, string] =
  if params.bootstrapNodes.len == 0:
    info "creating kademlia discovery as seed node (no bootstrap nodes)"

  let kademlia = KademliaDiscovery.new(
    switch,
    bootstrapNodes = params.bootstrapNodes,
    config = KadDHTConfig.new(
      validator = kad_types.ExtEntryValidator(), selector = kad_types.ExtEntrySelector()
    ),
    codec = ExtendedKademliaDiscoveryCodec,
  )

  try:
    switch.mount(kademlia)
  except CatchableError:
    return err("failed to mount kademlia discovery: " & getCurrentExceptionMsg())

  # Register services BEFORE starting kademlia so they are included in the
  # initial self-signed peer record published to the DHT
  if params.advertiseMix:
    if params.mixPubKey.isSome():
      let alreadyAdvertising = kademlia.startAdvertising(
        ServiceInfo(id: MixProtocolID, data: @(params.mixPubKey.get()))
      )
      if alreadyAdvertising:
        warn "mix service was already being advertised"
      debug "extended kademlia advertising mix service",
        keyHex = byteutils.toHex(params.mixPubKey.get()),
        bootstrapNodes = params.bootstrapNodes.len
    else:
      warn "mix advertising enabled but no key provided"

  info "kademlia discovery created",
    bootstrapNodes = params.bootstrapNodes.len, advertiseMix = params.advertiseMix

  return ok(
    WakuKademlia(
      protocol: kademlia,
      peerManager: peerManager,
      running: false,
      getMixNodePoolSize: getMixNodePoolSize,
      isNodeStarted: isNodeStarted,
    )
  )

proc extractMixPubKey(service: ServiceInfo): Option[Curve25519Key] =
  if service.id != MixProtocolID:
    trace "service is not mix protocol",
      serviceId = service.id, mixProtocolId = MixProtocolID
    return none(Curve25519Key)

  if service.data.len != Curve25519KeySize:
    warn "invalid mix pub key length from kademlia record",
      expected = Curve25519KeySize,
      actual = service.data.len,
      dataHex = byteutils.toHex(service.data)
    return none(Curve25519Key)

  debug "found mix protocol service",
    dataLen = service.data.len, expectedLen = Curve25519KeySize

  let key = intoCurve25519Key(service.data)
  debug "successfully extracted mix pub key", keyHex = byteutils.toHex(key)
  return some(key)

proc remotePeerInfoFrom(record: ExtendedPeerRecord): Option[RemotePeerInfo] =
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
    debug "checking service",
      peerId = record.peerId, serviceId = service.id, dataLen = service.data.len
    mixPubKey = extractMixPubKey(service)
    if mixPubKey.isSome():
      debug "extracted mix public key from service", peerId = record.peerId
      break

  if record.services.len > 0 and mixPubKey.isNone():
    debug "record has services but no valid mix key",
      peerId = record.peerId, services = record.services.mapIt(it.id)
    return none(RemotePeerInfo)
  return some(
    RemotePeerInfo.init(
      record.peerId,
      addrs = addrs,
      protocols = protocols,
      origin = PeerOrigin.Kademlia,
      mixPubKey = mixPubKey,
    )
  )

proc lookupMixPeers*(
    wk: WakuKademlia
): Future[Result[int, string]] {.async: (raises: []).} =
  ## Lookup mix peers via kademlia and add them to the peer store.
  ## Returns the number of mix peers found and added.
  if wk.protocol.isNil():
    return err("cannot lookup mix peers: kademlia not mounted")

  let mixService = ServiceInfo(id: MixProtocolID, data: @[])
  var records: seq[ExtendedPeerRecord]
  try:
    records = await wk.protocol.lookup(mixService)
  except CatchableError:
    return err("mix peer lookup failed: " & getCurrentExceptionMsg())

  debug "mix peer lookup returned records", numRecords = records.len

  var added = 0
  for record in records:
    let peerOpt = remotePeerInfoFrom(record)
    if peerOpt.isNone():
      continue

    let peerInfo = peerOpt.get()
    if peerInfo.mixPubKey.isNone():
      continue

    wk.peerManager.addPeer(peerInfo, PeerOrigin.Kademlia)
    info "mix peer added via kademlia lookup",
      peerId = $peerInfo.peerId, mixPubKey = byteutils.toHex(peerInfo.mixPubKey.get())
    added.inc()

  info "mix peer lookup complete", found = added
  return ok(added)

proc runDiscoveryLoop(
    wk: WakuKademlia, interval: Duration, minMixPeers: int
) {.async: (raises: []).} =
  info "extended kademlia discovery loop started", interval = interval

  try:
    while wk.running:
      # Wait for node to be started
      if not wk.isNodeStarted.isNil() and not wk.isNodeStarted():
        await sleepAsync(ExtendedKademliaDiscoveryStartupDelay)
        continue

      var records: seq[ExtendedPeerRecord]
      try:
        records = await wk.protocol.randomRecords()
      except CatchableError:
        warn "extended kademlia discovery failed", error = getCurrentExceptionMsg()
        await sleepAsync(interval)
        continue

      debug "received random records from kademlia", numRecords = records.len

      var added = 0
      for record in records:
        let peerOpt = remotePeerInfoFrom(record)
        if peerOpt.isNone():
          continue

        let peerInfo = peerOpt.get()
        wk.peerManager.addPeer(peerInfo, PeerOrigin.Kademlia)
        debug "peer added via extended kademlia discovery",
          peerId = $peerInfo.peerId,
          addresses = peerInfo.addrs.mapIt($it),
          protocols = peerInfo.protocols,
          hasMixPubKey = peerInfo.mixPubKey.isSome()
        added.inc()

      if added > 0:
        info "added peers from extended kademlia discovery", count = added

      # Targeted mix peer lookup when pool is low
      if minMixPeers > 0 and not wk.getMixNodePoolSize.isNil() and
          wk.getMixNodePoolSize() < minMixPeers:
        debug "mix node pool below threshold, performing targeted lookup",
          currentPoolSize = wk.getMixNodePoolSize(), threshold = minMixPeers
        let found = (await wk.lookupMixPeers()).valueOr:
          warn "targeted mix peer lookup failed", error = error
          0
        if found > 0:
          info "found mix peers via targeted kademlia lookup", count = found

      await sleepAsync(interval)
  except CancelledError as e:
    debug "extended kademlia discovery loop cancelled", error = e.msg
  except CatchableError as e:
    error "extended kademlia discovery loop failed", error = e.msg

proc start*(
    wk: WakuKademlia,
    interval: Duration = DefaultExtendedKademliaDiscoveryInterval,
    minMixPeers: int = 0,
): Future[Result[void, string]] {.async: (raises: []).} =
  if wk.running:
    return err("already running")

  try:
    await wk.protocol.start()
  except CatchableError as e:
    return err("failed to start kademlia discovery: " & e.msg)

  wk.running = true
  wk.discoveryLoop = wk.runDiscoveryLoop(interval, minMixPeers)

  info "kademlia discovery started"
  return ok()

proc stop*(wk: WakuKademlia) {.async: (raises: []).} =
  if not wk.running:
    return

  info "Stopping kademlia discovery"

  wk.running = false

  if not wk.discoveryLoop.isNil():
    await wk.discoveryLoop.cancelAndWait()
    wk.discoveryLoop = nil

  if not wk.protocol.isNil():
    await wk.protocol.stop()
  info "Successfully stopped kademlia discovery"
