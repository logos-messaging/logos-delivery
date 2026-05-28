import
  std/[options, os, sequtils, json, strutils, sets],
  eth/common/[addresses, keys],
  chronicles,
  chronos,
  libp2p/peerid,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/connectivity/relay/relay,
  libp2p/nameresolving/dnsresolver,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p/crypto/rng as libp2p_rng,
  bearssl/rand

import
  ./internal_config,
  ./networks_config,
  ./waku_conf,
  ./builder,
  ./validator_signed,
  ../waku_enr/sharding,
  ../waku_node,
  ../net/net_config,
  ../waku_core,
  ../waku_core/codecs,
  ../waku_rln_relay,
  ../waku_mix/logos_core_client as mix_lez_client,
  ../waku_mix/protocol as mix_protocol,
  mix_rln_spam_protection/onchain_group_manager,
  mix_rln_spam_protection/rln_interface as mix_rln_interface,
  ../waku_rln_relay/rln_gifter/protocol as rln_gifter_protocol,
  ../waku_rln_relay/rln_gifter/client as rln_gifter_client,
  ../discovery/waku_dnsdisc,
  ../waku_archive/retention_policy as policy,
  ../waku_archive/retention_policy/builder as policy_builder,
  ../waku_archive/driver as driver,
  ../waku_archive/driver/builder as driver_builder,
  ../waku_store,
  ../waku_store/common as store_common,
  ../waku_filter_v2,
  ../waku_peer_exchange,
  ../discovery/waku_kademlia,
  ../node/peer_manager,
  ../node/peer_manager/peer_store/waku_peer_storage,
  ../node/peer_manager/peer_store/migrations as peer_store_sqlite_migrations,
  ../waku_lightpush_legacy/common,
  ../common/rate_limit/setting

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
    (
      await node.mountMix(
        conf.clusterId, mixConf.mixKey, mixConf.mixnodes, mixConf.userMessageLimit,
        mixConf.disableSpamProtection,
        useOnchainLEZ = mixConf.useOnchainLEZ,
      )
    ).isOkOr:
      return err("failed to mount waku mix protocol: " & $error)

    # Wire OnchainLEZGroupManager to the LEZ RLN module via the fetcher
    # callback bridge (setRlnConfig is called later by the C++ plugin).
    if mixConf.useOnchainLEZ and not node.wakuMix.isNil:
      let gm = node.wakuMix.mixRlnSpamProtection.groupManager
      if gm of OnchainLEZGroupManager:
        let lezGm = OnchainLEZGroupManager(gm)
        # Adapt logos_core_client callbacks to OnchainLEZGroupManager types
        let clientFetchRoots = mix_lez_client.makeFetchLatestRoots()
        let clientFetchProof = mix_lez_client.makeFetchMerkleProof()

        let fetchRoots: onchain_group_manager.FetchRootsCallback = clientFetchRoots
        let fetchProof: onchain_group_manager.FetchProofCallback = clientFetchProof
        lezGm.setFetchCallbacks(fetchRoots, fetchProof)
        mix_lez_client.setGroupManagerRef(lezGm)
        info "Wired LEZ callbacks for mix RLN spam protection"

        # Mount RLN gifter server if configured
        if mixConf.gifterService:
          let walletAccount = mixConf.gifterWalletAccount

          # All gifter-initiated registrations funnel through a single
          # serialization worker so the gifter's wallet never has two
          # unconfirmed txns outstanding from the same signer — concurrent
          # submissions otherwise silently fail at the sequencer with
          # "Nonce mismatch" because the wallet refetches the chain nonce
          # per call and several submissions read the same value before
          # any commits. See cleanup/MODE_A_GIFTER_SLOT_BUG.md.
          #
          # The libp2p handler enqueues a job with an optimistic
          # leaf_index taken from a local counter, returns immediately
          # (so the stream doesn't time out), and the worker drains the
          # queue one tx at a time. Clients reconcile the authoritative
          # leaf via the existing status RPC + watcher.
          type GifterJob = ref object
            identityCommitment: seq[byte]
            rateLimit: uint64
            assigned: uint64

          let gifterQueue = newAsyncQueue[GifterJob]()
          var gifterNextLeaf: uint64 = 0

          proc gifterSubmitOnce(
              idc: seq[byte], rateLimit: uint64
          ): Result[uint64, string] {.gcsafe.} =
            let (configAccount, _) = mix_lez_client.getRlnConfig()
            if configAccount.len == 0:
              return err("RLN config not set on gifter node")
            let holdingAccount =
              if walletAccount.len > 0: walletAccount else: configAccount
            let idCommitmentHex = mix_lez_client.bytesToHexUpper(idc)
            let params =
              "{\"configAccountId\":\"" & configAccount &
              "\",\"userHoldingAccountId\":\"" & holdingAccount &
              "\",\"idCommitment\":\"" & idCommitmentHex &
              "\",\"rateLimit\":" & $rateLimit & "}"
            let regResult =
              mix_lez_client.callRlnFetcher("register_member", params)
            if regResult.isErr:
              return err(regResult.error)
            try:
              let parsed = parseJson(regResult.get())
              if parsed.hasKey("error"):
                return err(parsed["error"].getStr("register_member failed"))
              return ok(parsed["leaf_index"].getInt().uint64)
            except CatchableError as e:
              return err("failed to parse register_member result: " & e.msg)

          proc waitForChainCommit(
              idc: seq[byte], deadlineMs: int
          ): Future[Result[uint64, string]] {.async, gcsafe.} =
            ## Poll is_member_registered until the just-submitted tx
            ## commits. Without this gate, the worker's next iteration
            ## would race the wallet nonce-refetch against the previous
            ## tx's block inclusion and submit two txns with the same
            ## nonce.
            const pollMs = 2_000
            let (configAccount, _) = mix_lez_client.getRlnConfig()
            if configAccount.len == 0:
              return err("RLN config not set")
            let idHex = mix_lez_client.bytesToHexUpper(idc)
            let params =
              "{\"configAccountId\":\"" & configAccount &
              "\",\"idCommitment\":\"" & idHex & "\"}"
            let deadline = Moment.now() + chronos.milliseconds(deadlineMs)
            while Moment.now() < deadline:
              await sleepAsync(chronos.milliseconds(pollMs))
              let raw = mix_lez_client.callRlnFetcher(
                "is_member_registered", params)
              if raw.isErr: continue
              try:
                let parsed = parseJson(raw.get())
                if parsed.hasKey("registered") and
                    parsed["registered"].getBool() and
                    parsed.hasKey("leaf_index"):
                  return ok(parsed["leaf_index"].getInt().uint64)
              except JsonParsingError as e:
                warn "waitForChainCommit: bad JSON from is_member_registered",
                  error = e.msg
                continue
              except JsonKindError as e:
                warn "waitForChainCommit: unexpected JSON shape",
                  error = e.msg
                continue
            return err("confirmation timeout")

          proc gifterWorker() {.async, gcsafe.} =
            # Confirmation deadline must cover one block-include cycle plus
            # propagation lag on the slowest chain we ship against. Testnet
            # blocks ~60-90s + finality lag → 5min headroom.
            const confirmDeadlineMs = 300_000
            while true:
              let job = await gifterQueue.popFirst()
              let res = gifterSubmitOnce(job.identityCommitment, job.rateLimit)
              if res.isErr:
                error "Gifter worker: submission failed",
                  optimistic = job.assigned, err = res.error
                continue
              # Wait until the tx commits before processing the next job
              # so the wallet's next nonce fetch sees the advanced value.
              let confRes =
                await waitForChainCommit(job.identityCommitment, confirmDeadlineMs)
              if confRes.isErr:
                warn "Gifter worker: tx did not confirm within deadline",
                  optimistic = job.assigned, err = confRes.error
                continue
              let actual = confRes.get()
              if actual >= gifterNextLeaf:
                gifterNextLeaf = actual + 1
              if actual != job.assigned:
                info "Gifter worker: chain leaf differs from optimistic ack",
                  optimistic = job.assigned, actual = actual
              else:
                debug "Gifter worker: submission accepted at expected leaf",
                  leaf = actual

          let registerHandler: rln_gifter_protocol.RegisterMemberHandler =
            proc(
                identityCommitment: seq[byte], rateLimit: uint64
            ): Future[Result[rln_gifter_protocol.MembershipAllocationSuccess, string]] {.async, gcsafe.} =
              let (configAccount, _) = mix_lez_client.getRlnConfig()
              if configAccount.len == 0:
                return err("RLN config not set on gifter node")
              let assigned = gifterNextLeaf
              gifterNextLeaf += 1
              let job = GifterJob(
                identityCommitment: identityCommitment,
                rateLimit: rateLimit,
                assigned: assigned,
              )
              try:
                await gifterQueue.addLast(job)
              except CatchableError as e:
                return err("failed to enqueue gifter job: " & e.msg)
              return ok(rln_gifter_protocol.MembershipAllocationSuccess(
                leafIndex: assigned,
                merkleRoot: @[],
                blockNumber: 0'u64,
                transactionHash: @[],
                configAccountId: some(configAccount),
              ))

          var auth = none(rln_gifter_protocol.EthAllowlistAuth)
          if mixConf.gifterAllowlist.len > 0:
            var addrs: HashSet[Address]
            for piece in mixConf.gifterAllowlist.split(','):
              let s = piece.strip()
              if s.len == 0:
                continue
              let parsedAddr =
                try:
                  Address.fromHex(s)
                except ValueError as e:
                  return err("invalid gifter allowlist address '" & s & "': " & e.msg)
              addrs.incl(parsedAddr)
            if addrs.len > 0:
              auth = some(rln_gifter_protocol.EthAllowlistAuth(
                addresses: addrs, consumed: initHashSet[Address]()
              ))
              info "RLN gifter allowlist auth enabled", count = addrs.len

          let statusHandler: rln_gifter_protocol.MembershipStatusHandler =
            proc(
                configAccountId: string, identityCommitment: seq[byte]
            ): Future[Result[rln_gifter_protocol.MembershipStatusResponse, string]]
                {.async, gcsafe.} =
              let idHex = mix_lez_client.bytesToHexUpper(identityCommitment)
              let params =
                "{\"configAccountId\":\"" & configAccountId &
                "\",\"idCommitment\":\"" & idHex & "\"}"
              let raw = mix_lez_client.callRlnFetcher(
                "is_member_registered", params)
              if raw.isErr:
                return err(raw.error)
              try:
                let parsed = parseJson(raw.get())
                var resp = rln_gifter_protocol.MembershipStatusResponse(
                  registered: false)
                if parsed.hasKey("registered") and
                    parsed["registered"].getBool():
                  resp.registered = true
                  if parsed.hasKey("leaf_index"):
                    resp.leafIndex = some(parsed["leaf_index"].getInt().uint64)
                return ok(resp)
              except CatchableError as e:
                return err("failed to parse is_member_registered: " & e.msg)

          let gifter = rln_gifter_protocol.WakuRlnGifter.new(
            node.peerManager, node.rng, registerHandler, auth, statusHandler
          )
          node.switch.mount(gifter, protocolMatcher(WakuRlnGifterCodec))
          node.wakuRlnGifter = gifter
          let gifterStatus = rln_gifter_protocol.WakuRlnGifterStatus.new(
            statusHandler
          )
          node.switch.mount(
            gifterStatus, protocolMatcher(WakuRlnGifterStatusCodec))
          asyncSpawn gifterWorker()
          info "RLN gifter service mounted for mix",
            statusCodec = WakuRlnGifterStatusCodec

        # Defer client registration to startNode (needs running switch).
        if mixConf.gifterNode.len > 0:
          info "Gifter client mode: registration deferred to startNode()"

  # Setup extended kademlia discovery
  if conf.kademliaDiscoveryConf.isSome():
    let mixPubKey =
      if conf.mixConf.isSome():
        some(conf.mixConf.get().mixPubKey)
      else:
        none(Curve25519Key)

    node.wakuKademlia = WakuKademlia.new(
      node.switch,
      ExtendedServiceDiscoveryParams(
        bootstrapNodes: conf.kademliaDiscoveryConf.get().bootstrapNodes,
        mixPubKey: mixPubKey,
        advertiseMix: conf.mixConf.isSome(),
      ),
      node.peerManager,
      rng = libp2p_rng.newBearSslRng(node.rng),
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

    let archiveDriver = (
      await driver.ArchiveDriver.new(
        storeServiceConf.dbUrl, storeServiceConf.dbVacuum, storeServiceConf.dbMigration,
        storeServiceConf.maxNumDbConnections, onFatalErrorAction,
      )
    ).valueOr:
      return err("failed to setup archive driver: " & error)

    let retPolicies = policy.RetentionPolicy.new(storeServiceConf.retentionPolicies).valueOr:
      return err("failed to create retention policy: " & error)

    node.mountArchive(archiveDriver, retPolicies).isOkOr:
      return err("failed to mount waku archive protocol: " & error)

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

  # Start deferred OnchainLEZ poll loop now that the switch is fully started.
  if conf.mixConf.isSome() and conf.mixConf.get().useOnchainLEZ and
      not node.wakuMix.isNil():
    let gm = node.wakuMix.mixRlnSpamProtection.groupManager
    if gm of OnchainLEZGroupManager:
      OnchainLEZGroupManager(gm).startPolling()

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

  # The gifter is also a mix relay and needs its own membership to forward.
  # Deferred to startNode so the wallet RPC subprocess is wired first.
  if conf.mixConf.isSome() and conf.mixConf.get().useOnchainLEZ and
      conf.mixConf.get().gifterService and not node.wakuMix.isNil() and
      not node.wakuRlnGifter.isNil():
    let gm = node.wakuMix.mixRlnSpamProtection.groupManager
    if gm of OnchainLEZGroupManager:
      let lezGm = OnchainLEZGroupManager(gm)
      if lezGm.membershipIndex.isNone:
        let selfCred =
          if lezGm.credentials.isSome:
            lezGm.credentials.get()
          else:
            mix_rln_interface.membershipKeyGen().valueOr:
              return err("failed to generate gifter RLN identity: " & $error)
        let gifter = node.wakuRlnGifter
        asyncSpawn (proc(): Future[void] {.async.} =
          # Handler reads configAccount, which is set by setRlnConfig.
          while true:
            let (cfg, _) = mix_lez_client.getRlnConfig()
            if cfg.len > 0: break
            await sleepAsync(500.milliseconds)
          info "Self-registering gifter as mix relay",
            identityCommitmentLen = selfCred.idCommitment.len
          try:
            let selfRes = await gifter.registerHandler(
              @(selfCred.idCommitment), uint64(lezGm.userMessageLimit)
            )
            if selfRes.isErr:
              warn "Gifter self-registration failed", error = selfRes.error
              return
            let success = selfRes.get()
            if success.configAccountId.isNone:
              warn "Gifter self-registration response missing configAccountId"
              return
            let configAccount = success.configAccountId.get()
            lezGm.credentials = some(selfCred)
            lezGm.membershipIndex =
              some(onchain_group_manager.MembershipIndex(success.leafIndex))
            mix_lez_client.setRlnConfig(configAccount, success.leafIndex.int)
            info "Gifter self-registered as mix relay",
              leafIndex = success.leafIndex,
              configAccount = configAccount
            # The gifter's own handler now returns an optimistic leaf
            # (queued submission); poll the status RPC in-process to
            # reconcile if the chain assigned a different leaf.
            let watcherLezGm = lezGm
            let watcherConfigAccount = configAccount
            let watcherIdc = @(selfCred.idCommitment)
            let optimisticLeaf = success.leafIndex
            asyncSpawn (proc(): Future[void] {.async.} =
              const selfPollMs = 5_000
              const selfDeadlineMs = 1_800_000
              let deadline = Moment.now() +
                chronos.milliseconds(selfDeadlineMs)
              while Moment.now() < deadline:
                try:
                  await sleepAsync(chronos.milliseconds(selfPollMs))
                except CancelledError:
                  return
                let qr =
                  try:
                    await gifter.statusHandler(
                      watcherConfigAccount, watcherIdc)
                  except CancelledError:
                    return
                  except CatchableError as e:
                    debug "Gifter self-reg watcher: statusHandler raised",
                      error = e.msg
                    continue
                if qr.isErr: continue
                let resp = qr.get()
                if not resp.registered: continue
                if resp.leafIndex.isNone: continue
                let authLeaf = resp.leafIndex.get()
                if some(onchain_group_manager.MembershipIndex(authLeaf)) !=
                    watcherLezGm.membershipIndex:
                  info "Gifter self-reg leaf corrected from optimistic",
                    optimistic = optimisticLeaf, authoritative = authLeaf
                  watcherLezGm.membershipIndex =
                    some(onchain_group_manager.MembershipIndex(authLeaf))
                  mix_lez_client.setRlnConfig(
                    watcherConfigAccount, authLeaf.int)
                else:
                  info "Gifter self-reg confirmed on-chain",
                    leafIndex = authLeaf
                watcherLezGm.markMembershipConfirmed()
                return
              warn "Gifter self-reg confirmation timed out",
                optimisticLeaf = optimisticLeaf
            )()
          except CatchableError as e:
            warn "Gifter self-registration exception", error = e.msg
        )()

  # RLN gifter client registration — runs after switch start so the gifter peer is reachable.
  if conf.mixConf.isSome() and conf.mixConf.get().useOnchainLEZ and
      conf.mixConf.get().gifterNode.len > 0 and not node.wakuMix.isNil():
    let mixConf = conf.mixConf.get()
    let gm = node.wakuMix.mixRlnSpamProtection.groupManager
    if gm of OnchainLEZGroupManager:
      let lezGm = OnchainLEZGroupManager(gm)
      let gifterClient = rln_gifter_client.WakuRlnGifterClient.new(
        node.peerManager, node.rng
      )
      let gifterPeer = parsePeerInfo(mixConf.gifterNode).valueOr:
        return err("failed to parse gifter peer: " & error)
      node.peerManager.addServicePeer(gifterPeer, WakuRlnGifterCodec)

      # Use keystore credentials if available, otherwise generate new ones
      let idCred =
        if lezGm.credentials.isSome:
          lezGm.credentials.get()
        else:
          mix_rln_interface.membershipKeyGen().valueOr:
            return err("failed to generate RLN identity: " & $error)
      let idCommitmentBytes = @(idCred.idCommitment)

      info "Registering via RLN gifter",
        gifterPeer = mixConf.gifterNode,
        identityCommitmentLen = idCommitmentBytes.len,
        fromKeystore = lezGm.credentials.isSome

      var authType: seq[byte]
      var authPayload: seq[byte]
      if mixConf.gifterAuthKey.len > 0:
        let seckey = PrivateKey.fromHex(mixConf.gifterAuthKey).valueOr:
          return err("invalid mix-gifter-auth-key: " & $error)
        let sig = seckey.sign(rln_gifter_protocol.eip191Message(idCommitmentBytes))
        authPayload = @(sig.toRaw())
        for c in rln_gifter_protocol.EthAllowlistAuthType:
          authType.add(byte(c))
        info "Signing gifter request with EIP-191 auth key",
          signer = seckey.toPublicKey().to(Address).to0xHex()

      var success: rln_gifter_protocol.MembershipAllocationSuccess
      try:
        let res = await gifterClient.requestMembership(
          idCommitmentBytes,
          some(uint64(lezGm.userMessageLimit)),
          gifterPeer,
          authType,
          authPayload,
        )
        if res.isErr:
          return err("failed to register via gifter: " & res.error)
        success = res.get()
      except CatchableError:
        return err("gifter registration exception: " & getCurrentExceptionMsg())

      let configAccountId = success.configAccountId.valueOr:
        return err("gifter response missing configAccountId extension")

      lezGm.credentials = some(idCred)
      lezGm.membershipIndex = some(onchain_group_manager.MembershipIndex(success.leafIndex))
      mix_lez_client.setRlnConfig(configAccountId, success.leafIndex.int)

      info "Registered via RLN gifter",
        leafIndex = success.leafIndex,
        configAccount = configAccountId

      # Correct the optimistic leaf via the status codec if a concurrent
      # registration tx beat ours to the slot. Self-verify drops bad proofs
      # until the poll loop picks up the corrected witness.
      let watcherLezGm = lezGm
      let watcherConfigAccount = configAccountId
      asyncSpawn gifterClient.watchMembershipConfirmation(
        gifterPeer, configAccountId, idCommitmentBytes, success.leafIndex,
        "Mix-node",
        proc(authLeaf: uint64) {.gcsafe, raises: [].} =
          if some(onchain_group_manager.MembershipIndex(authLeaf)) !=
              watcherLezGm.membershipIndex:
            watcherLezGm.membershipIndex =
              some(onchain_group_manager.MembershipIndex(authLeaf))
            mix_lez_client.setRlnConfig(watcherConfigAccount, authLeaf.int)
          watcherLezGm.markMembershipConfirmed(),
      )

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

  # Re-publish gossipsub trigger after switch + kademlia are up. The dummy
  # publish in WakuMix.start() fires too early in LEZ mode (0 peers on topic),
  # so SUBSCRIBE messages never propagate without this second publish.
  if conf.mixConf.isSome() and conf.mixConf.get().useOnchainLEZ and
      not node.wakuMix.isNil():
    try:
      await node.wakuMix.publishGossipsubTrigger()
    except CatchableError:
      warn "gossipsub trigger publish failed", error = getCurrentExceptionMsg()

  return ok()

proc setupNode*(
    wakuConf: WakuConf, rng: ref HmacDrbgContext = HmacDrbgContext.new(), relay: Relay
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
