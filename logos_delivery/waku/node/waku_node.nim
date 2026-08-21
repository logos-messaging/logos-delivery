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
  logos_delivery/waku/discovery/waku_kademlia,
  logos_delivery/waku/net/[bound_ports, net_config],
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

# TODO: Move to application instance (e.g., `WakuNode2`)
# Git version in git describe format (defined compile time)
const git_version* {.strdefine.} = "n/a"

# Default clientId
const clientId* = "Nimbus Waku v2 node"

const WakuNodeVersionString* = "version / git commit hash: " & git_version

type
  # TODO: Move to application instance (e.g., `WakuNode2`)
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
    rln*: Rln
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
    onCommittedAddresses*: proc() {.gcsafe, raises: [].}
      ## Runs after every copy of the committed addresses.
      ## waku.nim uses it to refresh the ENR.
    extMultiAddrsOnly: bool
      ## Announce only the configured addresses. Set at construction.
    started*: bool # Indicates that node has started listening
    topicSubscriptionQueue*: AsyncEventQueue[SubscriptionEvent]
    rateLimitSettings*: ProtocolRateLimitSettings
    legacyAppHandlers*: Table[PubsubTopic, WakuRelayHandler]
      ## Kernel API Relay appHandlers (if any)
    subscriptionManager*: SubscriptionManager
    wakuMix*: WakuMix
    wakuKademlia*: WakuKademlia
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

proc getShardsGetter(node: WakuNode, configuredShards: seq[uint16]): GetShards =
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

proc copyCommittedAddresses*(node: WakuNode) =
  ## Copy the committed peerInfo addresses into announcedAddresses
  ## and run the ENR refresh callback, once start has resolved the addresses.
  if node.baseAnnounced.isNone():
    return
  node.announcedAddresses = node.switch.peerInfo.addrs
  if not node.onCommittedAddresses.isNil():
    node.onCommittedAddresses()

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

  let queue = newAsyncEventQueue[SubscriptionEvent](0)
  let node = WakuNode(
    peerManager: peerManager,
    switch: switch,
    rng: rng,
    brokerCtx: brokerCtx,
    enr: enr,
    announcedAddresses: netConfig.announcedAddresses,
    configuredAnnounced: netConfig.announcedAddresses,
    extMultiAddrsOnly: netConfig.extMultiAddrsOnly,
    topicSubscriptionQueue: queue,
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

# TODO: Move to application instance (e.g., `WakuNode2`)
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
  return node.wakuMix.poolSize()

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

  node.wakuMix = WakuMix.new(
    localaddrStr, node.peerManager, clusterId, mixPrivKey, mixnodes
  ).valueOr:
    error "Waku Mix protocol initialization failed", err = error
    return
  #TODO: should we do the below only for exit node? Also, what if multiple protocols use mix?
  node.wakuMix.registerDestReadBehavior(WakuLightPushCodec, readLp(int(-1)))
  let catchRes = catch:
    node.switch.mount(node.wakuMix)
  catchRes.isOkOr:
    return err(error.msg)
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

func replacePort(ma: MultiAddress, port: Port): Opt[MultiAddress] =
  ## Rebuild `ma` with its tcp or udp component set to `port`.
  let
    tcp = multiCodec("tcp")
    udp = multiCodec("udp")
  var res = MultiAddress.init()
  for item in ma.items:
    let part = item.valueOr:
      return Opt.none(MultiAddress)
    let code = part.protoCode.valueOr:
      return Opt.none(MultiAddress)
    if code == tcp or code == udp:
      let portMa = MultiAddress.init(code, int(port)).valueOr:
        return Opt.none(MultiAddress)
      res.append(portMa).isOkOr:
        return Opt.none(MultiAddress)
    else:
      res.append(part).isOkOr:
        return Opt.none(MultiAddress)
  Opt.some(res)

proc substituteBoundPorts(
    addrs: seq[MultiAddress], listenAddrs: seq[MultiAddress]
): seq[MultiAddress] =
  ## Replace port 0 with the port the entry's transport bound.
  ## Drop a port-0 entry whose transport did not bind.
  ## Entries with concrete ports pass through unchanged.
  if not addrs.anyIt(it.hasZeroPort()):
    return addrs

  let bound = getPorts(listenAddrs).valueOr:
    ## If getPorts fails, drop the zero-port entries.
    error "failed to read bound ports; dropping zero-port entries", error = error
    return addrs.filterIt(not it.hasZeroPort())

  var resolved: seq[MultiAddress]
  for ma in addrs:
    if not ma.hasZeroPort():
      resolved.add(ma)
      continue
    let port = (
      if ma.isWsAddress():
        bound.websocketPort
      elif ma.isQuicAddress():
        bound.quicPort
      else:
        bound.tcpPort
    ).valueOr:
      continue
    let substituted = ma.replacePort(port).valueOr:
      continue
    resolved.add(substituted)
  resolved

proc resolveAnnouncedBaseAddresses(node: WakuNode) =
  ## Runs once per start, after the sockets bind.
  ## Here the configured addresses become real: port 0 becomes
  ## the bound port, and a wildcard host becomes the primary IP.
  ## Everything the node announces builds on this set.
  if node.extMultiAddrsOnly:
    ## announcedAddrs bypasses the mappers. The configured set is final.
    node.baseAnnounced = Opt.some(node.configuredAnnounced)
    node.announcedAddresses = node.configuredAnnounced
    return

  let substituted =
    substituteBoundPorts(node.configuredAnnounced, node.switch.peerInfo.listenAddrs)

  const LoopbackIp = parseIpAddress("127.0.0.1")
  const RewrittenHosts =
    [static(parseIpAddress("0.0.0.0")), static(parseIpAddress("::"))]
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
    if ip notin RewrittenHosts:
      resolved.add(address)
      continue
    let rewritten = address.replaceIp(primaryIp).valueOr:
      resolved.add(address)
      continue
    resolved.add(rewritten)

  let base = resolved.filterIt(not it.hasZeroPort())
  node.baseAnnounced = Opt.some(base)
  node.announcedAddresses = base
  info "Announced base resolved", addrs = $base

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

  node.started = true

  if not node.wakuKademlia.isNil():
    await node.wakuKademlia.start()

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

  await node.subscriptionManager.stop()

  node.stopProvidersAndListeners()

  if not node.wakuKademlia.isNil():
    await node.wakuKademlia.stop()

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

proc isReady*(node: WakuNode): Future[bool] {.async: (raises: [Exception]).} =
  if node.rln == nil:
    return true
  return await node.rln.isReady()
  ## TODO: add other protocol `isReady` checks
