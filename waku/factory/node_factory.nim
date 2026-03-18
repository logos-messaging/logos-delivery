import
  std/[options, sequtils],
  chronicles,
  chronos,
  libp2p/peerid,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/connectivity/relay/relay,
  libp2p/nameresolving/dnsresolver,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519

import
  ./internal_config,
  ./networks_config,
  ./waku_conf,
  ./builder,
  ./validator_signed,
  ../waku_enr/sharding,
  ../waku_node,
  ../waku_core,
  ../waku_core/codecs,
  ../waku_rln_relay,
  ../discovery/waku_dnsdisc,
  ../waku_archive/retention_policy as policy,
  ../waku_archive/retention_policy/builder as policy_builder,
  ../waku_archive/driver as driver,
  ../waku_archive/driver/builder as driver_builder,
  ../waku_archive_legacy/driver as legacy_driver,
  ../waku_archive_legacy/driver/builder as legacy_driver_builder,
  ../waku_store,
  ../waku_store/common as store_common,
  ../waku_store_legacy,
  ../waku_store_legacy/common as legacy_common,
  ../waku_filter_v2,
  ../waku_peer_exchange,
  ../discovery/waku_kademlia,
  ../node/peer_manager,
  ../node/peer_manager/peer_store/waku_peer_storage,
  ../node/peer_manager/peer_store/migrations as peer_store_sqlite_migrations,
  ../waku_lightpush_legacy/common,
  ../common/rate_limit/setting,
  ../common/databases/dburl

## Peer persistence

const PeerPersistenceDbUrl = "peers.db"
proc setupPeerStorage(): Result[Option[WakuPeerStorage], string] =
  let db = ?SqliteDatabase.new(PeerPersistenceDbUrl)

  ?peer_store_sqlite_migrations.migrate(db)

  let res = WakuPeerStorage.new(db).valueOr:
    return err("failed to init peer store" & error)

  return ok(some(res))

## Init waku node instance

proc initNode(
    conf: WakuConf,
    netConfig: NetConfig,
    rng: ref HmacDrbgContext,
    record: enr.Record,
    peerStore: Option[WakuPeerStorage],
    relay: Relay,
    dynamicBootstrapNodes: openArray[RemotePeerInfo] = @[],
): Result[WakuNode, string] =
  ## Setup a basic Waku v2 node based on a supplied configuration
  ## file. Optionally include persistent peer storage.
  ## No protocols are mounted yet.

  let pStorage =
    if peerStore.isNone():
      nil
    else:
      peerStore.get()

  let (secureKey, secureCert) =
    if conf.webSocketConf.isSome() and conf.webSocketConf.get().secureConf.isSome():
      let wssConf = conf.webSocketConf.get().secureConf.get()
      (some(wssConf.keyPath), some(wssConf.certPath))
    else:
      (none(string), none(string))

  let nameResolver =
    DnsResolver.new(conf.dnsAddrsNameServers.mapIt(initTAddress(it, Port(53))))

  # Build waku node instance
  var builder = WakuNodeBuilder.init()
  builder.withRng(rng)
  builder.withNodeKey(conf.nodeKey)
  builder.withRecord(record)
  builder.withNetworkConfiguration(netConfig)
  builder.withPeerStorage(pStorage, capacity = conf.peerStoreCapacity)
  builder.withSwitchConfiguration(
    maxConnections = some(conf.maxConnections.int),
    secureKey = secureKey,
    secureCert = secureCert,
    nameResolver = nameResolver,
    sendSignedPeerRecord = conf.relayPeerExchange,
      # We send our own signed peer record when peer exchange enabled
    agentString = some(conf.agentString),
  )
  builder.withColocationLimit(conf.colocationLimit)

  if conf.maxRelayPeers.isSome():
    let
      maxRelayPeers = conf.maxRelayPeers.get()
      maxConnections = conf.maxConnections
      # Calculate the ratio as percentages
      relayRatio = (maxRelayPeers.float / maxConnections.float) * 100
      serviceRatio = 100 - relayRatio

    builder.withPeerManagerConfig(
      maxConnections = conf.maxConnections,
      relayServiceRatio = $relayRatio & ":" & $serviceRatio,
      shardAware = conf.relayShardedPeerManagement,
    )
    error "maxRelayPeers is deprecated. It is recommended to use relayServiceRatio instead. If relayServiceRatio is not set, it will be automatically calculated based on maxConnections and maxRelayPeers."
  else:
    builder.withPeerManagerConfig(
      maxConnections = conf.maxConnections,
      relayServiceRatio = conf.relayServiceRatio,
      shardAware = conf.relayShardedPeerManagement,
    )
  builder.withRateLimit(conf.rateLimit)
  builder.withCircuitRelay(relay)

  let node = ?builder.build().mapErr(
    proc(err: string): string =
      "failed to create waku node instance: " & err
  )

  ok(node)

## Mount protocols

proc getAutoshards*(
    node: WakuNode, contentTopics: seq[string]
): Result[seq[RelayShard], string] =
  if node.wakuAutoSharding.isNone():
    return err("Static sharding used, cannot get shards from content topics")
  var autoShards: seq[RelayShard]
  for contentTopic in contentTopics:
    let shard = node.wakuAutoSharding.get().getShard(contentTopic).valueOr:
        return err("Could not parse content topic: " & error)
    autoShards.add(shard)
  return ok(autoshards)

proc setupProtocols(
    node: WakuNode, conf: WakuConf
): Future[Result[void, string]] {.async.} =
  ## Setup configured protocols on an existing Waku v2 node.
  ## Optionally include persistent message storage.
  ## No protocols are started yet.

  var allShards = conf.subscribeShards
  node.mountMetadata(conf.clusterId, allShards).isOkOr:
    return err("failed to mount waku metadata protocol: " & error)

  var onFatalErrorAction = proc(msg: string) {.gcsafe, closure.} =
    ## Action to be taken when an internal error occurs during the node run.
    ## e.g. the connection with the database is lost and not recovered.
    error "Unrecoverable error occurred", error = msg
    quit(QuitFailure)

  #mount mix
  if conf.mixConf.isSome():
    let mixConf = conf.mixConf.get()
    (await node.mountMix(conf.clusterId, mixConf.mixKey, mixConf.mixnodes)).isOkOr:
      return err("failed to mount waku mix protocol: " & $error)

  # Setup extended kademlia discovery
  if conf.kademliaDiscoveryConf.isSome():
    let mixPubKey =
      if conf.mixConf.isSome():
        some(conf.mixConf.get().mixPubKey)
      else:
        none(Curve25519Key)

    node.wakuKademlia = WakuKademlia.new(
      node.switch,
      ExtendedKademliaDiscoveryParams(
        bootstrapNodes: conf.kademliaDiscoveryConf.get().bootstrapNodes,
        mixPubKey: mixPubKey,
        advertiseMix: conf.mixConf.isSome(),
      ),
      node.peerManager,
      getMixNodePoolSize = proc(): int {.gcsafe, raises: [].} =
        if node.wakuMix.isNil():
          0
        else:
          node.getMixNodePoolSize(),
      isNodeStarted = proc(): bool {.gcsafe, raises: [].} =
        node.started,
    ).valueOr:
      return err("failed to setup kademlia discovery: " & error)

  if conf.storeServiceConf.isSome():
    let storeServiceConf = conf.storeServiceConf.get()
    if storeServiceConf.supportV2:
      let archiveDriver = (
        await legacy_driver.ArchiveDriver.new(
          storeServiceConf.dbUrl, storeServiceConf.dbVacuum,
          storeServiceConf.dbMigration, storeServiceConf.maxNumDbConnections,
          onFatalErrorAction,
        )
      ).valueOr:
        return err("failed to setup legacy archive driver: " & error)

      node.mountLegacyArchive(archiveDriver).isOkOr:
        return err("failed to mount waku legacy archive protocol: " & error)

    ## For now we always mount the future archive driver but if the legacy one is mounted,
    ## then the legacy will be in charge of performing the archiving.
    ## Regarding storage, the only diff between the current/future archive driver and the legacy
    ## one, is that the legacy stores an extra field: the id (message digest.)

    ## TODO: remove this "migrate" variable once legacy store is removed
    ## It is now necessary because sqlite's legacy store has an extra field: storedAt
    ## This breaks compatibility between store's and legacy store's schemas in sqlite
    ## So for now, we need to make sure that when legacy store is enabled and we use sqlite
    ## that we migrate our db according to legacy store's schema to have the extra field

    let engine = dburl.getDbEngine(storeServiceConf.dbUrl).valueOr:
      return err("error getting db engine in setupProtocols: " & error)

    let migrate =
      if engine == "sqlite" and storeServiceConf.supportV2:
        false
      else:
        storeServiceConf.dbMigration

    let archiveDriver = (
      await driver.ArchiveDriver.new(
        storeServiceConf.dbUrl, storeServiceConf.dbVacuum, migrate,
        storeServiceConf.maxNumDbConnections, onFatalErrorAction,
      )
    ).valueOr:
      return err("failed to setup archive driver: " & error)

    let retPolicy = policy.RetentionPolicy.new(storeServiceConf.retentionPolicy).valueOr:
      return err("failed to create retention policy: " & error)

    node.mountArchive(archiveDriver, retPolicy).isOkOr:
      return err("failed to mount waku archive protocol: " & error)

    if storeServiceConf.supportV2:
      # Store legacy setup
      try:
        await mountLegacyStore(node, node.rateLimitSettings.getSetting(STOREV2))
      except CatchableError:
        return
          err("failed to mount waku legacy store protocol: " & getCurrentExceptionMsg())

    # Store setup
    try:
      await mountStore(node, node.rateLimitSettings.getSetting(STOREV3))
    except CatchableError:
      return err("failed to mount waku store protocol: " & getCurrentExceptionMsg())

    if storeServiceConf.storeSyncConf.isSome():
      let confStoreSync = storeServiceConf.storeSyncConf.get()

      (
        await node.mountStoreSync(
          conf.clusterId, conf.subscribeShards, conf.contentTopics,
          confStoreSync.rangeSec, confStoreSync.intervalSec,
          confStoreSync.relayJitterSec,
        )
      ).isOkOr:
        return err("failed to mount waku store sync protocol: " & $error)

      if conf.remoteStoreNode.isSome():
        let storeNode = parsePeerInfo(conf.remoteStoreNode.get()).valueOr:
          return err("failed to set node waku store-sync peer: " & error)

        node.peerManager.addServicePeer(storeNode, WakuReconciliationCodec)
        node.peerManager.addServicePeer(storeNode, WakuTransferCodec)

  mountStoreClient(node)
  if conf.remoteStoreNode.isSome():
    let storeNode = parsePeerInfo(conf.remoteStoreNode.get()).valueOr:
      return err("failed to set node waku store peer: " & error)
    node.peerManager.addServicePeer(storeNode, WakuStoreCodec)

  mountLegacyStoreClient(node)
  if conf.remoteStoreNode.isSome():
    let storeNode = parsePeerInfo(conf.remoteStoreNode.get()).valueOr:
      return err("failed to set node waku legacy store peer: " & error)
    node.peerManager.addServicePeer(storeNode, WakuLegacyStoreCodec)

  if conf.storeServiceConf.isSome and conf.storeServiceConf.get().resume:
    node.setupStoreResume()

  if conf.shardingConf.kind == AutoSharding:
    node.mountAutoSharding(conf.clusterId, conf.shardingConf.numShardsInCluster).isOkOr:
      return err("failed to mount waku auto sharding: " & error)
  else:
    warn("Auto sharding is disabled")

  # Mount relay on all nodes
  var peerExchangeHandler = none(RoutingRecordsHandler)
  if conf.relayPeerExchange:
    proc handlePeerExchange(
        peer: PeerId, topic: string, peers: seq[RoutingRecordsPair]
    ) {.gcsafe.} =
      ## Handle peers received via gossipsub peer exchange
      # TODO: Only consider peers on pubsub topics we subscribe to
      let exchangedPeers = peers.filterIt(it.record.isSome())
        # only peers with populated records
        .mapIt(toRemotePeerInfo(it.record.get()))

      info "adding exchanged peers",
        src = peer, topic = topic, numPeers = exchangedPeers.len

      for peer in exchangedPeers:
        # Peers added are filtered by the peer manager
        node.peerManager.addPeer(peer, PeerOrigin.PeerExchange)

    peerExchangeHandler = some(handlePeerExchange)

  # TODO: when using autosharding, the user should not be expected to pass any shards, but only content topics
  # Hence, this joint logic should be removed in favour of an either logic:
  # use passed shards (static) or deduce shards from content topics (auto)
  let autoShards =
    if node.wakuAutoSharding.isSome():
      node.getAutoshards(conf.contentTopics).valueOr:
        return err("Could not get autoshards: " & error)
    else:
      @[]

  info "Shards created from content topics",
    contentTopics = conf.contentTopics, shards = autoShards

  let confShards = conf.subscribeShards.mapIt(
    RelayShard(clusterId: conf.clusterId, shardId: uint16(it))
  )
  let shards = confShards & autoShards

  if conf.relay:
    info "Setting max message size", num_bytes = conf.maxMessageSizeBytes

    (
      await mountRelay(
        node, peerExchangeHandler = peerExchangeHandler, int(conf.maxMessageSizeBytes)
      )
    ).isOkOr:
      return err("failed to mount waku relay protocol: " & $error)

    # Add validation keys to protected topics
    var subscribedProtectedShards: seq[ProtectedShard]
    for shardKey in conf.protectedShards:
      if shardKey.shard notin conf.subscribeShards:
        warn "protected shard not in subscribed shards, skipping adding validator",
          protectedShard = shardKey.shard, subscribedShards = shards
        continue
      subscribedProtectedShards.add(shardKey)
      notice "routing only signed traffic",
        protectedShard = shardKey.shard, publicKey = shardKey.key
    node.wakuRelay.addSignedShardsValidator(subscribedProtectedShards, conf.clusterId)

  if conf.rendezvous:
    await node.mountRendezvous(conf.clusterId, shards)
    await node.mountRendezvousClient(conf.clusterId)

  # Keepalive mounted on all nodes
  try:
    await mountLibp2pPing(node)
  except CatchableError:
    return err("failed to mount libp2p ping protocol: " & getCurrentExceptionMsg())

  if conf.rlnRelayConf.isSome():
    let rlnRelayConf = conf.rlnRelayConf.get()
    let rlnConf = WakuRlnConfig(
      dynamic: rlnRelayConf.dynamic,
      credIndex: rlnRelayConf.credIndex,
      ethContractAddress: rlnRelayConf.ethContractAddress,
      chainId: rlnRelayConf.chainId,
      ethClientUrls: rlnRelayConf.ethClientUrls,
      creds: rlnRelayConf.creds,
      userMessageLimit: rlnRelayConf.userMessageLimit,
      epochSizeSec: rlnRelayConf.epochSizeSec,
      onFatalErrorAction: onFatalErrorAction,
    )

    try:
      await node.mountRlnRelay(rlnConf)
    except CatchableError:
      return err("failed to mount waku RLN relay protocol: " & getCurrentExceptionMsg())

  # NOTE Must be mounted after relay
  if conf.lightPush:
    try:
      (await mountLightPush(node, node.rateLimitSettings.getSetting(LIGHTPUSH))).isOkOr:
        return err("failed to mount waku lightpush protocol: " & $error)

      (await mountLegacyLightPush(node, node.rateLimitSettings.getSetting(LIGHTPUSH))).isOkOr:
        return err("failed to mount waku legacy lightpush protocol: " & $error)
    except CatchableError:
      return err("failed to mount waku lightpush protocol: " & getCurrentExceptionMsg())

  mountLightPushClient(node)
  mountLegacyLightPushClient(node)
  if conf.remoteLightPushNode.isSome():
    let lightPushNode = parsePeerInfo(conf.remoteLightPushNode.get()).valueOr:
      return err("failed to set node waku lightpush peer: " & error)
    node.peerManager.addServicePeer(lightPushNode, WakuLightPushCodec)
    node.peerManager.addServicePeer(lightPushNode, WakuLegacyLightPushCodec)

  # Filter setup. NOTE Must be mounted after relay
  if conf.filterServiceConf.isSome():
    let confFilter = conf.filterServiceConf.get()
    try:
      await mountFilter(
        node,
        subscriptionTimeout = chronos.seconds(confFilter.subscriptionTimeout),
        maxFilterPeers = confFilter.maxPeersToServe,
        maxFilterCriteriaPerPeer = confFilter.maxCriteria,
        rateLimitSetting = node.rateLimitSettings.getSetting(FILTER),
      )
    except CatchableError:
      return err("failed to mount waku filter protocol: " & getCurrentExceptionMsg())

  await node.mountFilterClient()
  if conf.remoteFilterNode.isSome():
    let filterNode = parsePeerInfo(conf.remoteFilterNode.get()).valueOr:
      return err("failed to set node waku filter peer: " & error)
    try:
      node.peerManager.addServicePeer(filterNode, WakuFilterSubscribeCodec)
    except CatchableError:
      return
        err("failed to mount waku filter client protocol: " & getCurrentExceptionMsg())

  # waku peer exchange setup
  if conf.peerExchangeService:
    try:
      await mountPeerExchange(
        node, some(conf.clusterId), node.rateLimitSettings.getSetting(PEEREXCHG)
      )
    except CatchableError:
      return
        err("failed to mount waku peer-exchange protocol: " & getCurrentExceptionMsg())

  if conf.remotePeerExchangeNode.isSome():
    let peerExchangeNode = parsePeerInfo(conf.remotePeerExchangeNode.get()).valueOr:
      return err("failed to set node waku peer-exchange peer: " & error)
    node.peerManager.addServicePeer(peerExchangeNode, WakuPeerExchangeCodec)

  if conf.peerExchangeDiscovery:
    await node.mountPeerExchangeClient()

  return ok()

## Start node

proc startNode*(
    node: WakuNode, conf: WakuConf, dynamicBootstrapNodes: seq[RemotePeerInfo] = @[]
): Future[Result[void, string]] {.async: (raises: []).} =
  ## Start a configured node and all mounted protocols.
  ## Connect to static nodes and start
  ## keep-alive, if configured.

  info "Running nwaku node", version = git_version
  try:
    await node.start()
  except CatchableError:
    return err("failed to start waku node: " & getCurrentExceptionMsg())

  # Connect to configured static nodes
  if conf.staticNodes.len > 0:
    try:
      await connectToNodes(node, conf.staticNodes, "static")
    except CatchableError:
      return err("failed to connect to static nodes: " & getCurrentExceptionMsg())

  if dynamicBootstrapNodes.len > 0:
    info "Connecting to dynamic bootstrap peers"
    try:
      await connectToNodes(node, dynamicBootstrapNodes, "dynamic bootstrap")
    except CatchableError:
      return
        err("failed to connect to dynamic bootstrap nodes: " & getCurrentExceptionMsg())

  # retrieve px peers and add the to the peer store
  if conf.remotePeerExchangeNode.isSome():
    var desiredOutDegree = DefaultPXNumPeersReq
    if not node.wakuRelay.isNil() and node.wakuRelay.parameters.d.uint64() > 0:
      desiredOutDegree = node.wakuRelay.parameters.d.uint64()
    (await node.fetchPeerExchangePeers(desiredOutDegree)).isOkOr:
      error "error while fetching peers from peer exchange", error = error

  # TODO: behavior described by comment is undesired. PX as client should be used in tandem with discv5.
  #
  # Use px to periodically get peers if discv5 is disabled, as discv5 nodes have their own
  # periodic loop to find peers and px returned peers actually come from discv5
  if conf.peerExchangeDiscovery and not conf.discv5Conf.isSome():
    node.startPeerExchangeLoop()

  # Maintain relay connections
  if conf.relay:
    node.peerManager.start()

  if not node.wakuKademlia.isNil():
    let minMixPeers = if conf.mixConf.isSome(): 4 else: 0
    (await node.wakuKademlia.start(minMixPeers = minMixPeers)).isOkOr:
      return err("failed to start kademlia discovery: " & error)

  return ok()

proc setupNode*(
    wakuConf: WakuConf, rng: ref HmacDrbgContext = crypto.newRng(), relay: Relay
): Future[Result[WakuNode, string]] {.async.} =
  let netConfig = (
    await networkConfiguration(
      wakuConf.clusterId, wakuConf.endpointConf, wakuConf.discv5Conf,
      wakuConf.webSocketConf, wakuConf.wakuFlags, wakuConf.dnsAddrsNameServers,
      wakuConf.portsShift, clientId,
    )
  ).valueOr:
    error "failed to create internal config", error = error
    return err("failed to create internal config: " & error)

  let record = enrConfiguration(wakuConf, netConfig).valueOr:
    error "failed to create record", error = error
    return err("failed to create record: " & error)

  if isClusterMismatched(record, wakuConf.clusterId):
    error "cluster id mismatch configured shards"
    return err("cluster id mismatch configured shards")

  info "Setting up storage"

  ## Peer persistence
  var peerStore: Option[WakuPeerStorage]
  if wakuConf.peerPersistence:
    peerStore = setupPeerStorage().valueOr:
      error "Setting up storage failed", error = "failed to setup peer store " & error
      return err("Setting up storage failed: " & error)

  info "Initializing node"

  let node = initNode(wakuConf, netConfig, rng, record, peerStore, relay).valueOr:
    error "Initializing node failed", error = error
    return err("Initializing node failed: " & error)

  info "Mounting protocols"

  try:
    (await node.setupProtocols(wakuConf)).isOkOr:
      error "Mounting protocols failed", error = error
      return err("Mounting protocols failed: " & error)
  except CatchableError:
    return err("Exception setting up protocols: " & getCurrentExceptionMsg())

  return ok(node)
