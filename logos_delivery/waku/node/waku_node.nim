{.push raises: [].}

import
  std/[tables, strutils, sequtils, os, net, random, sets],
  chronos,
  chronicles,
  metrics,
  results,
  eth/keys,
  nimcrypto,
  bearssl/rand,
  stew/byteutils,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p/[multiaddress, multicodec, peerinfo, wire],
  libp2p/nameresolving/nameresolver,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/transport,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport,
  libp2p/utils/offsettedseq,
  libp2p_mix,
  libp2p_mix/mix_protocol,
  brokers/broker_context,
  brokers/request_broker

import
  logos_delivery/waku/[
    waku_core,
    waku_core/topics/sharding,
    waku_relay,
    waku_archive,
    waku_store/protocol as store,
    waku_store/client as store_client,
    waku_store/common as store_common,
    waku_store/resume,
    waku_store_sync,
    waku_filter_v2,
    waku_filter_v2/client as filter_client,
    waku_metadata,
    waku_rendezvous/protocol,
    waku_rendezvous/client as rendezvous_client,
    waku_rendezvous/waku_peer_record,
    waku_lightpush_legacy/client as legacy_ligntpuhs_client,
    waku_lightpush_legacy as legacy_lightpush_protocol,
    waku_lightpush/client as ligntpuhs_client,
    waku_lightpush as lightpush_protocol,
    waku_enr,
    waku_peer_exchange,
    rln,
    rln/rln_lez/rln_lez,
    common/rate_limit/setting,
    common/callbacks,
    common/nimchronos,
    waku_mix,
    requests/node_requests,
    requests/health_requests,
    api/events/health_events,
    api/events/peer_events,
  ],
  logos_delivery/api/events/kernel_events, # MessageSeenEvent
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/discovery/waku_kademlia,
  logos_delivery/waku/net/[bound_ports, net_config],
  ./enr_addresses,
  ./peer_manager,
  ./health_monitor/health_status,
  ./health_monitor/topic_health,
  ./node_telemetry,
  ./shard_subscription,
  ./edge_filter_sub_state

export shard_subscription, edge_filter_sub_state

logScope:
  topics = "waku node"

# randomize initializes sdt/random's random number generator
# if not called, the outcome of randomization procedures will be the same in every run
randomize()

# TODO: Move to application instance (e.g., the node app)
# Git version in git describe format (defined compile time)
const git_version* {.strdefine.} = "n/a"

# Default clientId
const clientId* = "Nimbus Waku v2 node"

const WakuNodeVersionString* = "version / git commit hash: " & git_version

const MixNodeResolveTimeout = chronos.seconds(10)
  ## The time the background lookup may spend on all mix node names at once.
  ## `DnsResolver` gives each query 5 s per name server, and a node has two by
  ## default, so one name can take 10 s.

type
  MixNodeName = tuple[entry: MixNodePubInfo, address: MultiAddress]

  # TODO: Move to application instance (e.g., the node app)
  WakuInfo* = object # NOTE One for simplicity, can extend later as needed
    listenAddresses*: seq[string]
    enrUri*: string #multiaddrStrings*: seq[string]
    mixPubKey*: Opt[string]

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object
    peerManager*: PeerManager
    switch*: Switch
    wakuRelay*: WakuRelay
    wakuArchive*: waku_archive.WakuArchive
    wakuStore*: store.WakuStore
    wakuStoreClient*: store_client.WakuStoreClient
    wakuStoreResume*: StoreResume
    wakuStoreReconciliation*: SyncReconciliation
    wakuStoreTransfer*: SyncTransfer
    wakuFilter*: waku_filter_v2.WakuFilter
    wakuFilterClient*: filter_client.WakuFilterClient
    rln*: RlnEvm
    rlnLez*: RlnLez
    wakuLegacyLightPush*: WakuLegacyLightPush
    wakuLegacyLightpushClient*: WakuLegacyLightPushClient
    wakuLightPush*: WakuLightPush
    wakuLightpushClient*: WakuLightPushClient
    wakuPeerExchange*: WakuPeerExchange
    wakuPeerExchangeClient*: WakuPeerExchangeClient
    wakuMetadata*: WakuMetadata
    wakuAutoSharding*: Opt[Sharding]
    enr*: enr.Record
    libp2pPing*: Ping
    rng*: crypto.Rng
    brokerCtx*: BrokerContext
    wakuRendezvous*: WakuRendezVous
    wakuRendezvousClient*: rendezvous_client.WakuRendezVousClient
    announcedAddresses*: seq[MultiAddress]
      ## Copy of the committed peerInfo addresses once start resolves them.
    configuredAnnounced: seq[MultiAddress]
      ## Operator-configured addresses, set at construction.
      ## Every recomputation of the announced addresses starts from this field.
    baseAnnounced: Opt[seq[MultiAddress]]
      ## The configured addresses made concrete at start: bound ports
      ## substituted, wildcard hosts rewritten to the primary IP.
      ## The first mapper in the chain answers with this set.
    explicitAnnounced: seq[MultiAddress]
      ## The configured addresses with a host the operator chose. A base
      ## entry that is not here stands in for a wildcard bind host.
    enrHost: Opt[IpAddress]
    enrPort: Opt[Port]
      ## What the configuration gives the ENR scalars. None for a wildcard
      ## host or a port the kernel picks.
    enrLearnedEndpoint*: Opt[DiscoveryEndpoint]
      ## The endpoint discv5 last learned from its peers. Only a discv5 write
      ## sets it: the record's own host is not evidence of anything, and
      ## reading it back would pin the first host the node ever advertised.
    onCommittedAddresses*: proc() {.gcsafe, raises: [].}
      ## Runs after every copy of the committed addresses.
      ## waku.nim uses it to refresh the ENR.
    extMultiAddrsOnly: bool
      ## Announce only the configured addresses. Set at construction.
    started*: bool # Indicates that node has started listening
    rateLimitSettings*: ProtocolRateLimitSettings
    legacyAppHandlers*: Table[PubsubTopic, WakuRelayHandler]
      ## Kernel API Relay appHandlers (if any)
    subscriptionManager*: SubscriptionManager
    wakuMix*: WakuMix
    mixNodeResolution*: Future[void].Raising([CancelledError])
      ## The background lookup of the `dns4` mix node names; `nil` when none.
    mixNodeNames: seq[MixNodeName]
      ## The names without an answer yet; `start` resumes them after a stop.
    wakuKademlia*: WakuKademlia
    discoveries*: seq[IPeerDiscovery]
      ## Attached IPeerDiscovery backends; started after the node is up,
      ## stopped on node teardown.
    ports*: BoundPorts
    relayReconnectFut*: Future[void]

  SubscriptionManager* = ref object of RootObj
    node*: WakuNode
    shards*: Table[PubsubTopic, ShardSubscription]
    edgeFilterSubStates*: Table[PubsubTopic, EdgeFilterSubState]
    edgeFilterWakeup*: AsyncEvent
    edgeFilterSubLoopFut*: Future[void]
    edgeFilterConnectionLoopFut*: Future[void]
    peerEventListener*: WakuPeerEventListener
    ownsEdgeShardHealthProvider*: bool
    ownsEdgeFilterPeerCountProvider*: bool

import ./subscription_manager
import ../waku_mix/protocol_metrics

proc deduceRelayShard(
    node: WakuNode,
    contentTopic: ContentTopic,
    pubsubTopicOp: Opt[PubsubTopic] = Opt.none(PubsubTopic),
): Result[RelayShard, string] =
  let pubsubTopic = pubsubTopicOp.valueOr:
    if node.wakuAutoSharding.isNone():
      return err("Pubsub topic must be specified when static sharding is enabled.")
    let shard = node.wakuAutoSharding.get().getShard(contentTopic).valueOr:
        let msg = "Deducing shard failed: " & error
        return err(msg)
    return ok(shard)

  let shard = RelayShard.parse(pubsubTopic).valueOr:
    return err("Invalid topic:" & pubsubTopic & " " & $error)
  return ok(shard)

proc getShardsGetter*(node: WakuNode, configuredShards: seq[uint16]): GetShards =
  return proc(): seq[uint16] {.closure, gcsafe, raises: [].} =
    # fetch pubsubTopics subscribed to relay and convert them to shards
    if node.wakuRelay.isNil():
      # If relay is not mounted, return configured shards
      return configuredShards

    let subscribedTopics = node.wakuRelay.subscribedTopics()

    # If relay hasn't subscribed to any topics yet, return configured shards
    if subscribedTopics.len == 0:
      return configuredShards

    let relayShards = topicsToRelayShards(subscribedTopics).valueOr:
      debug "could not convert relay topics to shards",
        error = $error, topics = subscribedTopics
      # Fall back to configured shards on error
      return configuredShards
    if relayShards.isSome():
      let shards = relayShards.get().shardIds
      return shards
    return configuredShards

proc getCapabilitiesGetter(node: WakuNode): GetCapabilities =
  return proc(): seq[Capabilities] {.closure, gcsafe, raises: [].} =
    if node.wakuRelay.isNil():
      return @[]
    return node.enr.getCapabilities()

proc getWakuPeerRecordGetter(node: WakuNode): GetWakuPeerRecord =
  return proc(): WakuPeerRecord {.closure, gcsafe, raises: [].} =
    var mixKey: string
    if not node.wakuMix.isNil():
      mixKey = node.wakuMix.pubKey.to0xHex()
    return WakuPeerRecord.init(
      peerId = node.switch.peerInfo.peerId,
      addresses = node.announcedAddresses,
      mixKey = mixKey,
    )

proc onLearnedHost(node: WakuNode, ma: MultiAddress): Opt[MultiAddress] =
  ## A stand-in for the wildcard bind host, moved onto the host discv5
  ## confirmed from outside. Each entry keeps its own transport port: the
  ## port discv5 learned is discv5's own, and the scalars already pair that
  ## host with the bound TCP port on the same assumption.
  let learned = node.enrLearnedEndpoint.valueOr:
    return Opt.none(MultiAddress)
  if not ma.isConcreteEndpoint():
    return Opt.none(MultiAddress)
  return ma.replaceIp(learned.ip).optValue()

proc enrAddresses*(node: WakuNode): seq[MultiAddress] =
  ## The announced addresses known from outside: what the operator
  ## configured, what a mapper added (a NAT grant, a relay route), and, once
  ## discv5 confirms a host, the bound endpoints moved onto it. The primary
  ## interface on its own is not carried: the node knows it only from the
  ## inside.
  let base = node.baseAnnounced.valueOr:
    return node.announcedAddresses
  var addrs = newSeq[MultiAddress](0)
  for ma in node.announcedAddresses:
    if ma in node.explicitAnnounced or ma notin base:
      addrs.add(ma)
      continue
    node.onLearnedHost(ma).withValue(moved):
      if moved notin addrs:
        addrs.add(moved)
  return addrs

proc enrBaseline*(node: WakuNode): EnrBaseline =
  ## What the scalars say when nothing else decides them. A configured
  ## external port stays beside its host when the local port differs.
  if node.enrPort.isSome():
    return (ip: node.enrHost, tcp: node.enrPort)
  let ports = getPorts(node.switch.peerInfo.listenAddrs).valueOr:
    return (ip: node.enrHost, tcp: Opt.none(Port))
  let bound =
    if ports.tcpPort.isSome() and ports.tcpPort.get() != Port(0):
      ports.tcpPort
    else:
      Opt.none(Port)
  return (ip: node.enrHost, tcp: bound)

proc updateMixSelfHop(node: WakuNode) =
  ## Sets mix's own hop, which closes every reply path, to the first address mix
  ## can encode, in this order: a direct address known from outside, the ENR
  ## endpoint, a relay route known from outside, then the announced set.
  if node.wakuMix.isNil():
    return
  let before = node.wakuMix.localMixPubInfo().multiAddr
  let wasMissing = node.wakuMix.selfHopMissing()
  let outside = node.enrAddresses()
  var preferred = outside.filterIt(not it.isCircuitRelayMA())
  let baseline = node.enrBaseline()
  if baseline.ip.isSome() and baseline.tcp.isSome():
    let endpoint =
      MultiAddress.init(initTAddress(baseline.ip.get(), baseline.tcp.get()))
    if endpoint.isOk() and endpoint.get() notin outside:
      preferred.add(endpoint.get())
  preferred.add(outside.filterIt(it.isCircuitRelayMA()))
  let chosen = node.wakuMix.updateSelfHop(preferred, node.announcedAddresses)
  if chosen.isNone():
    # Warn once, when the hop goes missing; later commits log at debug.
    if wasMissing:
      debug "Still no announced address can carry mix replies",
        announced = $node.announcedAddresses
    else:
      warn "No announced address can carry mix replies, so this node's mixed sends fail. " &
        "Announce an IPv4 TCP or QUIC-v1 address that peers can reach",
        announced = $node.announcedAddresses
    return
  if chosen.get() != before or wasMissing:
    info "Mix self hop set", hop = $chosen.get(), before = $before

proc updateEnrConfiguredEndpoint*(node: WakuNode, netConfig: NetConfig) =
  ## A dns4 name can answer differently at start, so the scalars follow that
  ## resolution rather than the one from construction.
  node.enrHost = netConfig.enrIp
  node.enrPort = netConfig.enrPort
  # The hop follows the scalars once start has resolved the addresses.
  if node.baseAnnounced.isSome():
    node.updateMixSelfHop()

proc copyCommittedAddresses*(node: WakuNode) =
  ## Copy the committed peerInfo addresses into announcedAddresses, update mix's
  ## own hop, and refresh the ENR, once start has resolved the addresses.
  ## A `Waku` installs its own refresh, which also keeps the live discv5 record.
  if node.baseAnnounced.isNone():
    return
  node.announcedAddresses = node.switch.peerInfo.addrs
  node.updateMixSelfHop()
  if not node.onCommittedAddresses.isNil():
    node.onCommittedAddresses()
  else:
    node.enr.updateEnrAddresses(
      node.switch.peerInfo.privateKey, node.enrAddresses(), node.enrBaseline()
    ).isOkOr:
      error "failed to refresh the ENR addresses", error = error

proc new*(
    T: type WakuNode,
    netConfig: NetConfig,
    enr: enr.Record,
    switch: Switch,
    peerManager: PeerManager,
    rateLimitSettings: ProtocolRateLimitSettings = DefaultProtocolRateLimit,
    # TODO: make this argument required after tests are updated
    rng: crypto.Rng = crypto.newRng(),
): T {.raises: [Defect, LPError, IOError, TLSStreamProtocolError].} =
  ## Creates a Waku Node instance.

  info "Initializing networking", addrs = $netConfig.announcedAddresses

  let brokerCtx = globalBrokerContext()

  let node = WakuNode(
    peerManager: peerManager,
    switch: switch,
    rng: rng,
    brokerCtx: brokerCtx,
    enr: enr,
    announcedAddresses: netConfig.announcedAddresses,
    configuredAnnounced: netConfig.announcedAddresses,
    extMultiAddrsOnly: netConfig.extMultiAddrsOnly,
    enrHost: netConfig.enrIp,
    enrPort: netConfig.enrPort,
    rateLimitSettings: rateLimitSettings,
    ports: BoundPorts.init(),
  )

  if node.extMultiAddrsOnly:
    ## Set before start. libp2p skips the mapper chain when this is non-empty.
    ## NetConfig.init guarantees non-empty entries with concrete ports.
    switch.peerInfo.announcedAddrs = netConfig.announcedAddresses

  ## The base mapper answers with the resolved addresses.
  ## NAT and relay mappers run after it. Until then it drops zero-port entries.
  let baseMapper = proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.gcsafe, async: (raises: [CancelledError]).} =
    let base = node.baseAnnounced.valueOr:
      return listenAddrs.filterIt(not it.hasZeroPort())
    return base
  switch.peerInfo.addressMappers.add(baseMapper)
  switch.peerInfo.addObserver(
    proc(p: PeerInfo) {.gcsafe, raises: [].} =
      node.copyCommittedAddresses()
  )

  peerManager.setShardGetter(node.getShardsGetter(@[]))

  node.subscriptionManager = SubscriptionManager.new(node)

  return node

proc peerInfo*(node: WakuNode): PeerInfo =
  node.switch.peerInfo

proc peerId*(node: WakuNode): PeerId =
  node.peerInfo.peerId

# TODO: Move to application instance (e.g., the node app)
# TODO: Extend with more relevant info: topics, peers, memory usage, online time, etc
proc info*(node: WakuNode): WakuInfo =
  ## Returns information about the Node, such as what multiaddress it can be reached at.

  let peerInfo = node.switch.peerInfo

  var listenStr: seq[string]
  for address in node.announcedAddresses:
    var fulladdr = $address & "/p2p/" & $peerInfo.peerId
    listenStr &= fulladdr
  let enrUri = node.enr.toUri()
  var wakuInfo = WakuInfo(listenAddresses: listenStr, enrUri: enrUri)
  if not node.wakuMix.isNil():
    let keyStr = node.wakuMix.pubKey.to0xHex()
    wakuInfo.mixPubKey = Opt.some(keyStr)
  info "node info", wakuInfo
  return wakuInfo

proc connectToNodes*(
    node: WakuNode, nodes: seq[RemotePeerInfo] | seq[string], source = "api"
) {.async.} =
  ## `source` indicates source of node addrs (static config, api call, discovery, etc)
  # NOTE Connects to the node without a give protocol, which automatically creates streams for relay
  await peer_manager.connectToNodes(node.peerManager, nodes, source = source)

proc disconnectNode*(node: WakuNode, remotePeer: RemotePeerInfo) {.async.} =
  await peer_manager.disconnectNode(node.peerManager, remotePeer)

proc mountMetadata*(
    node: WakuNode, clusterId: uint32, shards: seq[uint16]
): Result[void, string] =
  if not node.wakuMetadata.isNil():
    return err("Waku metadata already mounted, skipping")

  let metadata = WakuMetadata.new(clusterId, node.getShardsGetter(shards))

  node.wakuMetadata = metadata
  node.peerManager.wakuMetadata = metadata

  let catchRes = catch:
    node.switch.mount(node.wakuMetadata, protocolMatcher(WakuMetadataCodec))
  catchRes.isOkOr:
    return err(error.msg)

  return ok()

## Waku AutoSharding
proc mountAutoSharding*(
    node: WakuNode, clusterId: uint16, shardCount: uint32
): Result[void, string] =
  info "Mounting auto sharding", clusterId = clusterId, shardCount = shardCount
  node.wakuAutoSharding =
    Opt.some(Sharding(clusterId: clusterId, shardCountGenZero: shardCount))

  return ok()

proc getMixNodePoolSize*(node: WakuNode): int =
  ## The number of mix pool members a path can use; zero when mix is not mounted.
  if node.wakuMix.isNil():
    return 0
  return node.wakuMix.poolSize()

proc splitMixNodes(
    node: WakuNode, mixnodes: seq[MixNodePubInfo]
): tuple[literals: seq[MixNodePubInfo], names: seq[MixNodeName], dropped: int] =
  ## Splits a mix node list into literal entries, which the pool takes as they
  ## are, and `dns4` names to resolve. Drops a bad multiaddress, and a name when
  ## the node has no resolver.
  var
    literals: seq[MixNodePubInfo]
    names: seq[MixNodeName]
    dropped = 0
  for mixnode in mixnodes:
    let address = MultiAddress.init(mixnode.multiAddr).valueOr:
      debug "Skipping a mix node with an invalid multiaddress",
        multiAddr = mixnode.multiAddr, error = error
      logos_delivery_mix_bootnode_resolve_failures.inc()
      dropped.inc()
      continue
    if not DNS.matchPartial(address):
      literals.add(mixnode)
    elif node.switch.nameResolver.isNil():
      debug "Skipping a mix node given by name: the node has no name resolver",
        multiAddr = mixnode.multiAddr
      logos_delivery_mix_bootnode_resolve_failures.inc()
      dropped.inc()
    else:
      names.add((entry: mixnode, address: address))
  return (literals, names, dropped)

proc literalMixNodes(
    mixnode: MixNodePubInfo, addresses: seq[MultiAddress]
): seq[MixNodePubInfo] =
  ## The pool entries for the addresses one name resolved to. They belong to one
  ## peer and make one member. An answer that is still a name, as a `dnsaddr`
  ## record can return, is skipped: the pool holds literals only.
  var entries: seq[MixNodePubInfo]
  for address in addresses:
    if DNS.matchPartial(address):
      debug "A mix node name resolved to another name, skipping that address",
        multiAddr = mixnode.multiAddr, resolved = $address
      continue
    entries.add(MixNodePubInfo(multiAddr: $address, pubKey: mixnode.pubKey))
  return entries

proc resolveMixNodeName(
    node: WakuNode, name: MixNodeName
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Resolves one mix node name and adds the node to the pool as soon as it
  ## answers. `false` when the lookup failed or gave no literal address.
  let addresses =
    try:
      await node.switch.nameResolver.resolveMAddress(name.address)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "Failed to resolve a mix node name, skipping it",
        multiAddr = name.entry.multiAddr, error = exc.msg
      return false
  let entries = literalMixNodes(name.entry, addresses)
  if entries.len == 0:
    debug "A mix node name resolved to no literal address, skipping it",
      multiAddr = name.entry.multiAddr
    return false
  if not node.wakuMix.isNil():
    node.wakuMix.addBootNodes(entries)
  return true

proc resolveMixNodeNames(node: WakuNode) {.async: (raises: [CancelledError]).} =
  ## Resolves `mixNodeNames` in the background. Each node joins the pool when its
  ## own name answers, and all lookups share one `MixNodeResolveTimeout`.
  let names = node.mixNodeNames
  let lookups = names.mapIt(node.resolveMixNodeName(it))
  var timedOut = false

  # `allFutures(...).withTimeout` does not cancel its children, so cancel every
  # pending lookup here, also when node stop cancels this task. Keep the names
  # still pending first, so `start` can resume them.
  try:
    timedOut = not (
      await allFutures(lookups.mapIt(FutureBase(it))).withTimeout(MixNodeResolveTimeout)
    )
  finally:
    var pending: seq[MixNodeName]
    for i, lookup in lookups:
      if not lookup.finished():
        pending.add(names[i])
    node.mixNodeNames = pending
    for lookup in lookups:
      if not lookup.finished():
        await lookup.cancelAndWait()

  var resolved = 0
  for i, lookup in lookups:
    if lookup.completed() and lookup.value():
      resolved.inc()
    elif lookup.cancelled():
      debug "Gave up resolving a mix node name, skipping it",
        multiAddr = names[i].entry.multiAddr
  let dropped = names.len - resolved
  if dropped > 0:
    logos_delivery_mix_bootnode_resolve_failures.inc(dropped.int64)
    warn "Dropped mix node names that could not be resolved",
      dropped = dropped,
      resolved = resolved,
      timedOut = timedOut,
      timeout = MixNodeResolveTimeout

proc mixNodesResolved*(node: WakuNode) {.async: (raises: [CancelledError]).} =
  ## Waits until the background lookup of the mix node names has finished.
  if not node.mixNodeResolution.isNil():
    await node.mixNodeResolution.join()

proc mountMix*(
    node: WakuNode,
    clusterId: uint16,
    mixPrivKey: Curve25519Key,
    mixnodes: seq[MixNodePubInfo],
): Future[Result[void, string]] {.async.} =
  info "Mounting mix protocol", nodeId = node.info #TODO log the config used

  if node.announcedAddresses.len == 0:
    return err("Trying to mount mix without having announced addresses")

  let localaddrStr = node.announcedAddresses[0].toString().valueOr:
    return err("Failed to convert multiaddress to string.")
  info "local addr", localaddr = localaddrStr

  let (literals, names, dropped) = node.splitMixNodes(mixnodes)

  node.wakuMix = WakuMix.new(
    localaddrStr, node.peerManager, clusterId, mixPrivKey, literals
  ).valueOr:
    error "Waku Mix protocol initialization failed", err = error
    return
  #TODO: should we do the below only for exit node? Also, what if multiple protocols use mix?
  node.wakuMix.registerDestReadBehavior(WakuLightPushCodec, readLp(int(-1)))
  let catchRes = catch:
    node.switch.mount(node.wakuMix)
  catchRes.isOkOr:
    return err(error.msg)

  if dropped > 0:
    warn "Dropped mix nodes that cannot be resolved", dropped = dropped

  # In the background, so a slow or dead DNS server does not hold the start.
  if names.len > 0:
    node.mixNodeNames = names
    node.mixNodeResolution = node.resolveMixNodeNames()
  return ok()

proc mountKademlia*(
    node: WakuNode, config: KademliaDiscoveryConf
): Result[void, string] =
  if not node.wakuKademlia.isNil():
    return err("WakuKademlia already mounted, skipping")

  let wk = WakuKademlia.new(
    node.switch, node.peerManager, config.bootstrapNodes, config.servicesToAdvertise,
    config.servicesToDiscover, config.randomLookupInterval,
    config.serviceLookupInterval, node.rng, config.kadDhtConfig, config.discoConfig,
    config.clientMode, config.xprPublishing,
  ).valueOr:
    return err("failed to create service discovery: " & error)

  node.wakuKademlia = wk

  let mountRes = catch:
    node.switch.mount(wk.protocol)
  mountRes.isOkOr:
    return err("failed to mount service discovery: " & error.msg)

  return ok()

proc attachDiscovery*(node: WakuNode, discovery: IPeerDiscovery) =
  ## Attach an IPeerDiscovery backend: started after the node is up
  ## (node.start or explicitly by the owner), stopped in node.stop.
  node.discoveries.add(discovery)

## Waku Sync

proc mountStoreSync*(
    node: WakuNode,
    cluster: uint16,
    shards: seq[uint16],
    contentTopics: seq[string],
    storeSyncRange: uint32,
    storeSyncInterval: uint32,
    storeSyncRelayJitter: uint32,
): Future[Result[void, string]] {.async.} =
  let idsChannel = newAsyncQueue[(SyncID, PubsubTopic, ContentTopic)](0)
  let wantsChannel = newAsyncQueue[(PeerId)](0)
  let needsChannel = newAsyncQueue[(PeerId, WakuMessageHash)](0)

  let pubsubTopics = shards.mapIt($RelayShard(clusterId: cluster, shardId: it))

  let recon = ?await SyncReconciliation.new(
    pubsubTopics, contentTopics, node.peerManager, node.wakuArchive,
    storeSyncRange.seconds, storeSyncInterval.seconds, storeSyncRelayJitter.seconds,
    idsChannel, wantsChannel, needsChannel,
  )

  node.wakuStoreReconciliation = recon

  let reconMountRes = catch:
    node.switch.mount(
      node.wakuStoreReconciliation, protocolMatcher(WakuReconciliationCodec)
    )
  reconMountRes.isOkOr:
    return err(error.msg)

  let transfer = SyncTransfer.new(
    node.peerManager, node.wakuArchive, idsChannel, wantsChannel, needsChannel
  )

  node.wakuStoreTransfer = transfer

  let transMountRes = catch:
    node.switch.mount(node.wakuStoreTransfer, protocolMatcher(WakuTransferCodec))
  transMountRes.isOkOr:
    return err(error.msg)

  return ok()

proc reconnectRelayPeers*(node: WakuNode) {.async.} =
  ## Reconnect to previously-seen WakuRelay peers.
  if node.wakuRelay.isNil():
    return
  if not node.peerManager.switch.peerStore.hasPeers(protocolMatcher(WakuRelayCodec)):
    return
  info "Found previous WakuRelay peers. Reconnecting."
  let backoffPeriod =
    node.wakuRelay.parameters.pruneBackoff + chronos.seconds(BackoffSlackTime)
  await node.peerManager.reconnectPeers(WakuRelayCodec, backoffPeriod)

proc selectRandomPeers*(peers: seq[PeerId], numRandomPeers: int): seq[PeerId] =
  var randomPeers = peers
  shuffle(randomPeers)
  return randomPeers[0 ..< min(len(randomPeers), numRandomPeers)]

proc mountRendezvousClient*(node: WakuNode, clusterId: uint16) {.async: (raises: []).} =
  info "Mounting rendezvous client"

  node.wakuRendezvousClient = rendezvous_client.WakuRendezVousClient.new(
    node.switch, node.peerManager, clusterId
  ).valueOr:
    error "Initializing waku rendezvous client failed", error = error
    return

  if node.started:
    await node.wakuRendezvousClient.start()

proc mountRendezvous*(
    node: WakuNode, clusterId: uint16, shards: seq[RelayShard] = @[]
) {.async: (raises: []).} =
  info "Mounting rendezvous discovery protocol"

  let configuredShards = shards.mapIt(it.shardId)

  node.wakuRendezvous = WakuRendezVous.new(
    node.switch,
    node.peerManager,
    clusterId,
    node.getShardsGetter(configuredShards),
    node.getCapabilitiesGetter(),
    node.getWakuPeerRecordGetter(),
  ).valueOr:
    error "Initializing waku rendezvous failed", error = error
    return

  if node.started:
    try:
      await node.wakuRendezvous.start()
    except CancelledError as exc:
      error "Failed to start wakuRendezvous", error = exc.msg

  try:
    node.switch.mount(node.wakuRendezvous, protocolMatcher(WakuRendezVousCodec))
  except LPError:
    error "Failed to mount wakuRendezvous", error = getCurrentExceptionMsg()

proc resolveAnnouncedBaseAddresses(node: WakuNode) =
  ## Runs once per start, after the sockets bind.
  ## Here the configured addresses become real: port 0 becomes
  ## the bound port, and a wildcard host becomes the primary IP.
  ## Everything the node announces builds on this set.
  if node.extMultiAddrsOnly:
    ## announcedAddrs bypasses the mappers. The configured set is final.
    node.baseAnnounced = Opt.some(node.configuredAnnounced)
    node.announcedAddresses = node.configuredAnnounced
    node.explicitAnnounced = node.configuredAnnounced
    return

  let substituted =
    substituteBoundPorts(node.configuredAnnounced, node.switch.peerInfo.listenAddrs)
  ## A wildcard host and an unresolved port are what libp2p calls undialable.
  node.explicitAnnounced = substituted.filterIt(it.isConcreteEndpoint())

  const LoopbackIp = parseIpAddress("127.0.0.1")
  var primaryIp = LoopbackIp
  try:
    primaryIp = getPrimaryIPAddr()
  except Exception as e:
    ## getPrimaryIPAddr declares a bare Exception effect on Windows, so
    ## a narrower catch fails the raises check there.
    debug "Could not retrieve the primary IP address", msg = e.msg

  var resolved = newSeq[MultiAddress](0)
  for address in substituted:
    let ip = address.getIp().valueOr:
      resolved.add(address)
      continue
    if not ip.isWildcard():
      resolved.add(address)
      continue
    let rewritten = address.replaceIp(primaryIp).valueOr:
      resolved.add(address)
      continue
    resolved.add(rewritten)

  let base = resolved.filterIt(not it.hasZeroPort())
  node.baseAnnounced = Opt.some(base)
  node.announcedAddresses = base
  info "Announced base resolved", addrs = $base, explicit = $node.explicitAnnounced

proc startProvidersAndListeners*(node: WakuNode) =
  RequestRelayShard.setProvider(
    node.brokerCtx,
    proc(
        pubsubTopic: Opt[PubsubTopic], contentTopic: ContentTopic
    ): Result[RequestRelayShard, string] =
      let shard = node.deduceRelayShard(contentTopic, pubsubTopic).valueOr:
        return err($error)
      return ok(RequestRelayShard(relayShard: shard)),
  ).isOkOr:
    error "Can't set provider for RequestRelayShard", error = error

  RequestShardTopicsHealth.setProvider(
    node.brokerCtx,
    proc(topics: seq[PubsubTopic]): Result[RequestShardTopicsHealth, string] =
      var response: RequestShardTopicsHealth

      for shard in topics:
        # Health resolution order:
        # 1. Relay topicsHealth (computed from gossipsub mesh state)
        # 2. If relay is active but topicsHealth hasn't computed yet, UNHEALTHY
        # 3. Otherwise, ask edge filter (via broker; no-op if no provider set)
        var healthStatus = TopicHealth.NOT_SUBSCRIBED

        if not node.wakuRelay.isNil:
          healthStatus =
            node.wakuRelay.topicsHealth.getOrDefault(shard, TopicHealth.NOT_SUBSCRIBED)

        if healthStatus == TopicHealth.NOT_SUBSCRIBED:
          if not node.wakuRelay.isNil and node.wakuRelay.isSubscribed(shard):
            healthStatus = TopicHealth.UNHEALTHY
          else:
            let edgeRes = RequestEdgeShardHealth.request(node.brokerCtx, shard)
            if edgeRes.isOk():
              healthStatus = edgeRes.get().health

        response.topicHealth.add((shard, healthStatus))

      return ok(response),
  ).isOkOr:
    error "Can't set provider for RequestShardTopicsHealth", error = error

  RequestContentTopicsHealth.setProvider(
    node.brokerCtx,
    proc(topics: seq[ContentTopic]): Result[RequestContentTopicsHealth, string] =
      var response: RequestContentTopicsHealth

      for contentTopic in topics:
        var topicHealth = TopicHealth.NOT_SUBSCRIBED

        let shardResult = node.deduceRelayShard(contentTopic, Opt.none(PubsubTopic))

        if shardResult.isOk():
          let shardObj = shardResult.get()
          let pubsubTopic = $shardObj
          if not isNil(node.wakuRelay):
            topicHealth = node.wakuRelay.topicsHealth.getOrDefault(
              pubsubTopic, TopicHealth.NOT_SUBSCRIBED
            )

          if topicHealth == TopicHealth.NOT_SUBSCRIBED:
            let edgeRes = RequestEdgeShardHealth.request(node.brokerCtx, pubsubTopic)
            if edgeRes.isOk():
              topicHealth = edgeRes.get().health

        response.contentTopicHealth.add((topic: contentTopic, health: topicHealth))

      return ok(response),
  ).isOkOr:
    error "Can't set provider for RequestContentTopicsHealth", error = error

proc stopProvidersAndListeners*(node: WakuNode) =
  RequestRelayShard.clearProvider(node.brokerCtx)
  RequestContentTopicsHealth.clearProvider(node.brokerCtx)
  RequestShardTopicsHealth.clearProvider(node.brokerCtx)

proc start*(node: WakuNode) {.async.} =
  ## Starts a created Waku Node and
  ## all its mounted protocols.

  logos_delivery_version.set(1, labelValues = [git_version])
  info "Starting Waku node", version = git_version

  if not node.wakuStoreResume.isNil():
    await node.wakuStoreResume.start()

  if not node.wakuRendezvousClient.isNil():
    await node.wakuRendezvousClient.start()

  ## NOTE: This will dispatch gossipsub start to the WakuRelay.start method override
  await node.switch.start()

  ## The sockets are bound now. Resolve the announced addresses, commit
  ## them, and copy once. The observer fires only on a changed commit.
  resolveAnnouncedBaseAddresses(node)
  await node.switch.peerInfo.update()
  node.copyCommittedAddresses()

  # Reconnect to known relay peers in the background; it waits a prune backoff
  # and must not block startup.
  node.relayReconnectFut = node.reconnectRelayPeers()

  # Resume the mix node names that a stop left without an answer.
  if not node.mixNodeResolution.isNil() and node.mixNodeResolution.cancelled():
    node.mixNodeResolution = node.resolveMixNodeNames()

  node.started = true

  for discovery in node.discoveries:
    (await discovery.startDiscovery()).isOkOr:
      error "failed to start discovery backend", error = error

  if not node.wakuFilterClient.isNil():
    node.wakuFilterClient.registerPushHandler(
      proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
        MessageSeenEvent.emit(node.brokerCtx, pubsubTopic, msg)
    )

  node.startProvidersAndListeners()

  node.subscriptionManager.start().isOkOr:
    error "failed to start subscription manager", error = error

  info "Node started successfully"

proc stop*(node: WakuNode) {.async.} =
  ## By stopping the switch we are stopping all the underlying mounted protocols

  # Cancel the background relay reconnection (may still be in its backoff wait).
  if not node.relayReconnectFut.isNil():
    await node.relayReconnectFut.cancelAndWait()

  # Cancel a mix node name lookup that is still pending.
  if not node.mixNodeResolution.isNil():
    await node.mixNodeResolution.cancelAndWait()

  await node.subscriptionManager.stop()

  node.stopProvidersAndListeners()

  for discovery in node.discoveries:
    (await discovery.stopDiscovery()).isOkOr:
      error "failed to stop discovery backend", error = error

  ## NOTE: This will dispatch gossipsub stop to the WakuRelay.stop method override
  await node.switch.stop()

  node.peerManager.stop()

  if not node.rln.isNil():
    try:
      await node.rln.stop() ## this can raise an exception
    except Exception:
      error "exception stopping the node", error = getCurrentExceptionMsg()

  if not node.wakuArchive.isNil():
    await node.wakuArchive.stopWait()

  if not node.wakuStoreResume.isNil():
    await node.wakuStoreResume.stopWait()

  if not node.wakuPeerExchangeClient.isNil() and
      not node.wakuPeerExchangeClient.pxLoopHandle.isNil():
    await node.wakuPeerExchangeClient.pxLoopHandle.cancelAndWait()

  if not node.wakuRendezvousClient.isNil():
    await node.wakuRendezvousClient.stopWait()

  node.started = false
  node.baseAnnounced = Opt.none(seq[MultiAddress])
  node.explicitAnnounced = @[]
  node.enrLearnedEndpoint = Opt.none(DiscoveryEndpoint)

proc isReady*(node: WakuNode): Future[bool] {.async: (raises: [Exception]).} =
  if node.rln == nil:
    return true
  return await node.rln.isReady()
  ## TODO: add other protocol `isReady` checks
