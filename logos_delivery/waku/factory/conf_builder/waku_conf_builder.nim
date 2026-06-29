import logos_delivery/waku/compat/option_valueor
import
  libp2p/crypto/crypto,
  libp2p/multiaddress,
  std/[net, options, sequtils],
  stint,
  chronicles,
  chronos,
  results

import
  logos_delivery/waku/[
    factory/waku_conf,
    factory/networks_config,
    common/logging,
    common/utils/parse_size_units,
    node/peer_manager,
    waku_core/message/default_values,
    waku_core/topics/pubsub_topic,
    waku_enr/capabilities,
    persistency/persistency,
  ],
  tools/confutils/entry_nodes

import
  ./filter_service_conf_builder,
  ./store_sync_conf_builder,
  ./store_service_conf_builder,
  ./rest_server_conf_builder,
  ./dns_discovery_conf_builder,
  ./discv5_conf_builder,
  ./web_socket_conf_builder,
  ./quic_conf_builder,
  ./metrics_server_conf_builder,
  ./rate_limit_conf_builder,
  ./rln_relay_conf_builder,
  ./mix_conf_builder,
  ./kademlia_discovery_conf_builder

logScope:
  topics = "waku conf builder"

# Picks up the same -d:git_version=... build flag that cli_args.nim defines.
const git_version {.strdefine.} = "(unknown)"

const
  DefaultMaxConnections = 150
  DefaultRelay: bool = false
    # historical confbuilder default; wakunode2 CLI deviates (true)
  DefaultLightPush: bool = false
  DefaultPeerExchange: bool = false
    # historical confbuilder default; wakunode2 CLI deviates (true)
  DefaultStoreSyncMount: bool = false
  DefaultRendezvous: bool = false
    # historical confbuilder default; wakunode2 CLI deviates (true)
  DefaultMix*: bool = false
  DefaultRelayPeerExchange: bool = false
  DefaultLogLevel: logging.LogLevel = logging.LogLevel.INFO
  DefaultLogFormat: logging.LogFormat = logging.LogFormat.TEXT
  DefaultNatStrategy: string = "none"
  DefaultP2pTcpPort: Port = Port(60000)
  DefaultP2pListenAddress: IpAddress = static parseIpAddress("0.0.0.0")
  DefaultPortsShift: uint16 = 0
  DefaultExtMultiAddrsOnly: bool = false
  DefaultDnsAddrsNameServers: seq[IpAddress] =
    @[static parseIpAddress("1.1.1.1"), static parseIpAddress("1.0.0.1")]
  DefaultPeerPersistence: bool = false
  DefaultAgentString*: string = "logos-delivery-" & git_version
  DefaultRelayShardedPeerManagement: bool = false
  DefaultRelayServiceRatio: string = "50:50"
  DefaultCircuitRelayClient: bool = false
  DefaultP2pReliability*: bool = true
  DefaultNumShardsInCluster: uint16 = 1
  DefaultShardingConfKind: ShardingConfKind = AutoSharding

type MaxMessageSizeKind* = enum
  mmskNone
  mmskStr
  mmskInt

type MaxMessageSize* = object
  case kind*: MaxMessageSizeKind
  of mmskNone:
    discard
  of mmskStr:
    str*: string
  of mmskInt:
    bytes*: uint64

## `WakuConfBuilder` is a convenient tool to accumulate
## Config parameters to build a `WakuConfig`.
## It provides some type conversion, as well as applying
## defaults in an agnostic manner (for any usage of Waku node)
#
# TODO: Sub protocol builder (eg `StoreServiceConfBuilder`
# is be better defined in the protocol module (eg store)
# and apply good defaults from this protocol PoV and make the
# decision when the dev must specify a value vs when a default
# is fine to have.
#
# TODO: Add default to most values so that when a developer uses
# the builder, it works out-of-the-box
type WakuConfBuilder* = object
  nodeKey: Option[crypto.PrivateKey]

  clusterId: Option[uint16]
  shardingConf: Option[ShardingConfKind]
  numShardsInCluster: Option[uint16]
  subscribeShards: Option[seq[uint16]]
  protectedShards: Option[seq[ProtectedShard]]
  contentTopics: Option[seq[string]]

  # Conf builders
  dnsDiscoveryConf*: DnsDiscoveryConfBuilder
  discv5Conf*: Discv5ConfBuilder
  filterServiceConf*: FilterServiceConfBuilder
  metricsServerConf*: MetricsServerConfBuilder
  restServerConf*: RestServerConfBuilder
  rlnRelayConf*: RlnConfBuilder
  storeServiceConf*: StoreServiceConfBuilder
  mixConf*: MixConfBuilder
  webSocketConf*: WebSocketConfBuilder
  quicConf*: QuicConfBuilder
  rateLimitConf*: RateLimitConfBuilder
  kademliaDiscoveryConf*: KademliaDiscoveryConfBuilder
  # End conf builders
  relay: Option[bool]
  lightPush: Option[bool]
  peerExchange: Option[bool]
  storeSync: Option[bool]
  relayPeerExchange: Option[bool]
  mix: Option[bool]

  # TODO: move within a relayConf
  rendezvous: Option[bool]

  networkPresetConf: Option[NetworkPresetConf]

  staticNodes: seq[string]

  remoteStoreNode: Option[string]
  remoteLightPushNode: Option[string]
  remoteFilterNode: Option[string]
  remotePeerExchangeNode: Option[string]

  maxMessageSize: MaxMessageSize

  logLevel: Option[logging.LogLevel]
  logFormat: Option[logging.LogFormat]

  natStrategy: Option[string]

  p2pTcpPort: Option[Port]
  p2pListenAddress: Option[IpAddress]
  portsShift: Option[uint16]
  dns4DomainName: Option[string]
  extMultiAddrs: seq[string]
  extMultiAddrsOnly: Option[bool]

  dnsAddrsNameServers: seq[IpAddress]

  peerPersistence: Option[bool]
  peerStoreCapacity: Option[int]
  maxConnections: Option[int]
  colocationLimit: Option[int]

  agentString: Option[string]

  maxRelayPeers: Option[int]
  relayShardedPeerManagement: Option[bool]
  relayServiceRatio: Option[string]
  circuitRelayClient: Option[bool]
  p2pReliability: Option[bool]

  localStoragePath: Option[string]

proc init*(T: type WakuConfBuilder): WakuConfBuilder =
  WakuConfBuilder(
    dnsDiscoveryConf: DnsDiscoveryConfBuilder.init(),
    discv5Conf: Discv5ConfBuilder.init(),
    filterServiceConf: FilterServiceConfBuilder.init(),
    metricsServerConf: MetricsServerConfBuilder.init(),
    restServerConf: RestServerConfBuilder.init(),
    rlnRelayConf: RlnConfBuilder.init(),
    storeServiceConf: StoreServiceConfBuilder.init(),
    webSocketConf: WebSocketConfBuilder.init(),
    quicConf: QuicConfBuilder.init(),
    rateLimitConf: RateLimitConfBuilder.init(),
    kademliaDiscoveryConf: KademliaDiscoveryConfBuilder.init(),
  )

proc withNetworkPresetConf*(
    b: var WakuConfBuilder, networkPresetConf: NetworkPresetConf
) =
  b.networkPresetConf = some(networkPresetConf)

proc withNodeKey*(b: var WakuConfBuilder, nodeKey: crypto.PrivateKey) =
  b.nodeKey = some(nodeKey)

proc withClusterId*(b: var WakuConfBuilder, clusterId: uint16) =
  b.clusterId = some(clusterId)

proc withShardingConf*(b: var WakuConfBuilder, shardingConf: ShardingConfKind) =
  b.shardingConf = some(shardingConf)

proc withNumShardsInCluster*(b: var WakuConfBuilder, numShardsInCluster: uint16) =
  b.numShardsInCluster = some(numShardsInCluster)

proc withSubscribeShards*(b: var WakuConfBuilder, shards: seq[uint16]) =
  b.subscribeShards = some(shards)

proc withProtectedShards*(
    b: var WakuConfBuilder, protectedShards: seq[ProtectedShard]
) =
  b.protectedShards = some(protectedShards)

proc withContentTopics*(b: var WakuConfBuilder, contentTopics: seq[string]) =
  b.contentTopics = some(contentTopics)

proc withRelay*(b: var WakuConfBuilder, relay: bool) =
  b.relay = some(relay)

proc withLightPush*(b: var WakuConfBuilder, lightPush: bool) =
  b.lightPush = some(lightPush)

proc withStoreSync*(b: var WakuConfBuilder, storeSync: bool) =
  b.storeSync = some(storeSync)

proc withPeerExchange*(b: var WakuConfBuilder, peerExchange: bool) =
  b.peerExchange = some(peerExchange)

proc withRelayPeerExchange*(b: var WakuConfBuilder, relayPeerExchange: bool) =
  b.relayPeerExchange = some(relayPeerExchange)

proc withRendezvous*(b: var WakuConfBuilder, rendezvous: bool) =
  b.rendezvous = some(rendezvous)

proc withMix*(builder: var WakuConfBuilder, mix: bool) =
  builder.mix = some(mix)

proc withRemoteStoreNode*(b: var WakuConfBuilder, remoteStoreNode: string) =
  b.remoteStoreNode = some(remoteStoreNode)

proc withRemoteLightPushNode*(b: var WakuConfBuilder, remoteLightPushNode: string) =
  b.remoteLightPushNode = some(remoteLightPushNode)

proc withRemoteFilterNode*(b: var WakuConfBuilder, remoteFilterNode: string) =
  b.remoteFilterNode = some(remoteFilterNode)

proc withRemotePeerExchangeNode*(
    b: var WakuConfBuilder, remotePeerExchangeNode: string
) =
  b.remotePeerExchangeNode = some(remotePeerExchangeNode)

proc withPeerPersistence*(b: var WakuConfBuilder, peerPersistence: bool) =
  b.peerPersistence = some(peerPersistence)

proc withPeerStoreCapacity*(b: var WakuConfBuilder, peerStoreCapacity: int) =
  b.peerStoreCapacity = some(peerStoreCapacity)

proc withMaxConnections*(b: var WakuConfBuilder, maxConnections: int) =
  b.maxConnections = some(maxConnections)

proc withDnsAddrsNameServers*(
    b: var WakuConfBuilder, dnsAddrsNameServers: seq[IpAddress]
) =
  b.dnsAddrsNameServers.insert(dnsAddrsNameServers)

proc withLogLevel*(b: var WakuConfBuilder, logLevel: logging.LogLevel) =
  b.logLevel = some(logLevel)

proc withLogFormat*(b: var WakuConfBuilder, logFormat: logging.LogFormat) =
  b.logFormat = some(logFormat)

proc withP2pTcpPort*(b: var WakuConfBuilder, p2pTcpPort: Port) =
  b.p2pTcpPort = some(p2pTcpPort)

proc withP2pTcpPort*(b: var WakuConfBuilder, p2pTcpPort: uint16) =
  b.p2pTcpPort = some(Port(p2pTcpPort))

proc withPortsShift*(b: var WakuConfBuilder, portsShift: uint16) =
  b.portsShift = some(portsShift)

proc withP2pListenAddress*(b: var WakuConfBuilder, p2pListenAddress: IpAddress) =
  b.p2pListenAddress = some(p2pListenAddress)

proc withExtMultiAddrsOnly*(b: var WakuConfBuilder, extMultiAddrsOnly: bool) =
  b.extMultiAddrsOnly = some(extMultiAddrsOnly)

proc withDns4DomainName*(b: var WakuConfBuilder, dns4DomainName: string) =
  b.dns4DomainName = some(dns4DomainName)

proc withNatStrategy*(b: var WakuConfBuilder, natStrategy: string) =
  b.natStrategy = some(natStrategy)

proc withAgentString*(b: var WakuConfBuilder, agentString: string) =
  b.agentString = some(agentString)

proc withColocationLimit*(b: var WakuConfBuilder, colocationLimit: int) =
  b.colocationLimit = some(colocationLimit)

proc withRelayServiceRatio*(b: var WakuConfBuilder, relayServiceRatio: string) =
  b.relayServiceRatio = some(relayServiceRatio)

proc withCircuitRelayClient*(b: var WakuConfBuilder, circuitRelayClient: bool) =
  b.circuitRelayClient = some(circuitRelayClient)

proc withRelayShardedPeerManagement*(
    b: var WakuConfBuilder, relayShardedPeerManagement: bool
) =
  b.relayShardedPeerManagement = some(relayShardedPeerManagement)

proc withP2pReliability*(b: var WakuConfBuilder, p2pReliability: bool) =
  b.p2pReliability = some(p2pReliability)

proc withLocalStoragePath*(b: var WakuConfBuilder, localStoragePath: string) =
  b.localStoragePath = some(localStoragePath)

proc withExtMultiAddrs*(builder: var WakuConfBuilder, extMultiAddrs: seq[string]) =
  builder.extMultiAddrs = concat(builder.extMultiAddrs, extMultiAddrs)

proc withMaxMessageSize*(builder: var WakuConfBuilder, maxMessageSizeBytes: uint64) =
  builder.maxMessageSize = MaxMessageSize(kind: mmskInt, bytes: maxMessageSizeBytes)

proc withMaxMessageSize*(builder: var WakuConfBuilder, maxMessageSize: string) =
  builder.maxMessageSize = MaxMessageSize(kind: mmskStr, str: maxMessageSize)

proc withStaticNodes*(builder: var WakuConfBuilder, staticNodes: seq[string]) =
  builder.staticNodes = concat(builder.staticNodes, staticNodes)

## Building

proc nodeKey(
    builder: WakuConfBuilder, rng: crypto.Rng
): Result[crypto.PrivateKey, string] =
  if builder.nodeKey.isSome():
    return ok(builder.nodeKey.get())
  else:
    warn "missing node key, generating new set"
    let nodeKey = crypto.PrivateKey.random(Secp256k1, rng).valueOr:
      error "Failed to generate key", error = error
      return err("Failed to generate key: " & $error)
    return ok(nodeKey)

proc buildShardingConf(
    bShardingConfKind: Option[ShardingConfKind],
    bNumShardsInCluster: Option[uint16],
    bSubscribeShards: Option[seq[uint16]],
): (ShardingConf, seq[uint16]) =
  case bShardingConfKind.get(DefaultShardingConfKind)
  of StaticSharding:
    (ShardingConf(kind: StaticSharding), bSubscribeShards.get(@[]))
  of AutoSharding:
    let numShardsInCluster = bNumShardsInCluster.get(DefaultNumShardsInCluster)
    let shardingConf =
      ShardingConf(kind: AutoSharding, numShardsInCluster: numShardsInCluster)
    let upperShard = uint16(numShardsInCluster - 1)
    (shardingConf, bSubscribeShards.get(toSeq(0.uint16 .. upperShard)))

template checkSetPresetValueToField[T](
    field: var Option[T], presetVal: T, msg: static string
) =
  ## Set the field to the preset's value, unless the field is already set
  ## (explicit wins). Warn iff the field's existing value differs from the
  ## preset's. No-op if they agree.

  if field.isSome():
    if field.get() != presetVal:
      warn msg, used = field.get(), discarded = presetVal
  else:
    field = some(presetVal)

proc checkAddPresetValueToField[T](field: var seq[T], presetVals: seq[T]) =
  ## Append the preset's list values to the field's existing list. Lists
  ## concat rather than override; both the user's and the preset's entries
  ## end up in the final list.

  field = field & presetVals

proc applyNetworkPresetConf(builder: var WakuConfBuilder) =
  ## NetworkPresetConf = network presets.
  ## Cascade the chosen preset's values onto builder fields the user hasn't set.
  ## User-set fields stay; preset fills the gaps and warns on conflict (explicit wins).
  ## List fields concat (preset's nodes appended to user's).

  if builder.networkPresetConf.isNone():
    return # If there is no preset given, then nothing to do.

  let networkPresetConf = builder.networkPresetConf.get()

  checkSetPresetValueToField(
    builder.clusterId, networkPresetConf.clusterId,
    "Cluster id was provided alongside a network conf",
  )

  # Apply relay parameters
  if builder.relay.get(DefaultRelay) and networkPresetConf.rlnRelay:
    checkSetPresetValueToField(
      builder.rlnRelayConf.enabled,
      networkPresetConf.rlnRelay, # true
      "RLN Relay was provided alongside a network conf",
    )
    checkSetPresetValueToField(
      builder.rlnRelayConf.ethContractAddress,
      networkPresetConf.rlnRelayEthContractAddress,
      "RLN Relay ETH Contract Address was provided alongside a network conf",
    )
    checkSetPresetValueToField(
      builder.rlnRelayConf.chainId, networkPresetConf.rlnRelayChainId,
      "RLN Relay Chain Id was provided alongside a network conf",
    )
    checkSetPresetValueToField(
      builder.rlnRelayConf.dynamic, networkPresetConf.rlnRelayDynamic,
      "RLN Relay Dynamic was provided alongside a network conf",
    )
    checkSetPresetValueToField(
      builder.rlnRelayConf.epochSizeSec, networkPresetConf.rlnEpochSizeSec,
      "RLN Epoch Size in Seconds was provided alongside a network conf",
    )
    checkSetPresetValueToField(
      builder.rlnRelayConf.userMessageLimit, networkPresetConf.rlnRelayUserMessageLimit,
      "RLN Relay User Message Limit was provided alongside a network conf",
    )
  # End Apply relay parameters

  case builder.maxMessageSize.kind
  of mmskNone:
    builder.withMaxMessageSize(parseCorrectMsgSize(networkPresetConf.maxMessageSize))
  of mmskStr, mmskInt:
    warn "Max Message Size was provided alongside a network conf",
      used = $builder.maxMessageSize, discarded = networkPresetConf.maxMessageSize

  checkSetPresetValueToField(
    builder.shardingConf, networkPresetConf.shardingConf.kind,
    "Sharding Conf was provided alongside a network conf",
  )
  case networkPresetConf.shardingConf.kind
  of AutoSharding:
    checkSetPresetValueToField(
      builder.numShardsInCluster, networkPresetConf.shardingConf.numShardsInCluster,
      "Num Shards In Cluster overrides network conf preset",
    )
  of StaticSharding:
    discard

  checkSetPresetValueToField(
    builder.discv5Conf.enabled, networkPresetConf.discv5Discovery,
    "Discv5 Discovery was provided alongside a network conf",
  )
  checkAddPresetValueToField(
    builder.discv5Conf.bootstrapNodes, networkPresetConf.discv5BootstrapNodes
  )

  checkSetPresetValueToField(
    builder.kademliaDiscoveryConf.enabled, networkPresetConf.enableKadDiscovery,
    "Kademlia Discovery was provided alongside a network conf",
  )
  checkAddPresetValueToField(
    builder.kademliaDiscoveryConf.bootstrapNodes, networkPresetConf.kadBootstrapNodes
  )

  checkSetPresetValueToField(
    builder.mix, networkPresetConf.mix, "Mix was provided alongside a network conf"
  )
  checkSetPresetValueToField(
    builder.p2pReliability, networkPresetConf.p2pReliability,
    "P2P Reliability was provided alongside a network conf",
  )

  # Process entry nodes from network config - classify and distribute
  if networkPresetConf.entryNodes.len > 0:
    let processed = processEntryNodes(networkPresetConf.entryNodes)
    if processed.isOk():
      let (enrTreeUrls, bootstrapEnrs, staticNodesFromEntry) = processed.get()

      # Set ENRTree URLs for DNS discovery
      if enrTreeUrls.len > 0:
        for url in enrTreeUrls:
          builder.dnsDiscoveryConf.withEnrTreeUrl(url)

      # Set ENR records as bootstrap nodes for discv5
      if bootstrapEnrs.len > 0:
        builder.discv5Conf.withBootstrapNodes(bootstrapEnrs)

      # Add static nodes (multiaddrs and those extracted from ENR entries)
      if staticNodesFromEntry.len > 0:
        builder.withStaticNodes(staticNodesFromEntry)
    else:
      warn "Failed to process entry nodes from network conf", error = processed.error()

proc rejectOverride[T](
    field: Option[T], presetValue: T, msg: string
): Result[void, string] =
  ## Errors with `msg` if `field` is set to anything other than the preset's value.
  if field.isSome() and field.get() != presetValue:
    return err(msg)
  ok()

proc enforceSecurityConstraints(builder: WakuConfBuilder): Result[void, string] =
  ## Errors if the resolved config violates a security constraint.

  if builder.networkPresetConf.isSome():
    let preset = builder.networkPresetConf.get()
    let relayEnabled = builder.relay.get(DefaultRelay)
    let rlnRelayConf = builder.rlnRelayConf
    let rlnRelayEnabled = rlnRelayConf.enabled.get(DefaultRlnRelayEnabled)

    if relayEnabled and preset.rlnRelay:
      if not rlnRelayEnabled:
        return
          err("network preset mandates RLN relay: cannot relay with rln-relay disabled")

      ?rejectOverride(
        rlnRelayConf.ethContractAddress, preset.rlnRelayEthContractAddress,
        "network preset mandates its RLN contract: cannot relay with a different rln-relay-eth-contract-address",
      )
      ?rejectOverride(
        rlnRelayConf.chainId, preset.rlnRelayChainId,
        "network preset mandates its RLN chain id: cannot relay with a different rln-relay-chain-id",
      )
      ?rejectOverride(
        rlnRelayConf.dynamic, preset.rlnRelayDynamic,
        "network preset mandates its RLN membership mode: cannot relay with a different rln-relay-dynamic",
      )
      ?rejectOverride(
        rlnRelayConf.epochSizeSec, preset.rlnEpochSizeSec,
        "network preset mandates its RLN epoch size: cannot relay with a different rln-relay-epoch-sec",
      )

  ok()

func resolvePortsShift(configured: Port, portsShift: uint16): Port =
  ## Fold portsShift into a configured port. Port(0) (auto-assign) is left as-is.
  if configured == Port(0):
    configured
  else:
    Port(configured.uint16 + portsShift)

proc build*(
    builder: var WakuConfBuilder, rng: crypto.Rng = crypto.newRng()
): Result[WakuConf, string] =
  ## Return a WakuConf that contains all mandatory parameters
  ## Applies some sane defaults that are applicable across any usage
  ## of libwaku. It aims to be agnostic so it does not apply a
  ## default when it is opinionated.

  applyNetworkPresetConf(builder)

  # We should not ignore any user-supplied config parameter: the user is
  # allowed to override any preset parameter with any explicit config
  # parameter. However, we do gate config building with an error if any
  # one of these preset overrides is considered a security concern.
  # This eliminates ambiguous behavior such as warning of an override and
  # then ignoring it: either fail-fast or accept the override.
  ?enforceSecurityConstraints(builder)

  let relay =
    if builder.relay.isSome():
      builder.relay.get()
    else:
      warn "whether to mount relay is not specified, defaulting to not mounting"
      DefaultRelay

  let lightPush =
    if builder.lightPush.isSome():
      builder.lightPush.get()
    else:
      warn "whether to mount lightPush is not specified, defaulting to not mounting"
      DefaultLightPush

  let peerExchange =
    if builder.peerExchange.isSome():
      builder.peerExchange.get()
    else:
      warn "whether to mount peerExchange is not specified, defaulting to not mounting"
      DefaultPeerExchange

  let storeSync =
    if builder.storeSync.isSome():
      builder.storeSync.get()
    else:
      warn "whether to mount storeSync is not specified, defaulting to not mounting"
      DefaultStoreSyncMount

  let rendezvous =
    if builder.rendezvous.isSome():
      builder.rendezvous.get()
    else:
      warn "whether to mount rendezvous is not specified, defaulting to not mounting"
      DefaultRendezvous

  let mix =
    if builder.mix.isSome():
      builder.mix.get()
    else:
      warn "whether to mount mix is not specified, defaulting to not mounting"
      DefaultMix

  let relayPeerExchange = builder.relayPeerExchange.get(DefaultRelayPeerExchange)

  let nodeKey = ?nodeKey(builder, rng)

  let clusterId =
    if builder.clusterId.isNone():
      # TODO: ClusterId should never be defaulted, instead, presets
      # should be defined and used
      warn("Cluster Id was not specified, defaulting to 0")
      DefaultClusterId
    else:
      builder.clusterId.get().uint16

  let (shardingConf, subscribeShards) = buildShardingConf(
    builder.shardingConf, builder.numShardsInCluster, builder.subscribeShards
  )
  let protectedShards = builder.protectedShards.get(@[])

  info "Sharding configuration: ",
    shardingConf = $shardingConf, subscribeShards = $subscribeShards

  let maxMessageSizeBytes =
    case builder.maxMessageSize.kind
    of mmskInt:
      builder.maxMessageSize.bytes
    of mmskStr:
      ?parseMsgSize(builder.maxMessageSize.str)
    else:
      warn "Max Message Size not specified, defaulting to DefaultMaxWakuMessageSize",
        default = DefaultMaxWakuMessageSizeStr
      DefaultMaxWakuMessageSize

  let contentTopics = builder.contentTopics.get(@[])

  # Build sub-configs
  var discv5Conf = builder.discv5Conf.build().valueOr:
    return err("Discv5 Conf building failed: " & $error)

  let dnsDiscoveryConf = builder.dnsDiscoveryConf.build().valueOr:
    return err("DNS Discovery Conf building failed: " & $error)

  let filterServiceConf = builder.filterServiceConf.build().valueOr:
    return err("Filter Service Conf building failed: " & $error)

  var metricsServerConf = builder.metricsServerConf.build().valueOr:
    return err("Metrics Server Conf building failed: " & $error)

  var restServerConf = builder.restServerConf.build().valueOr:
    return err("REST Server Conf building failed: " & $error)

  let rlnRelayConf = builder.rlnRelayConf.build().valueOr:
    return err("RLN Relay Conf building failed: " & $error)

  let storeServiceConf = builder.storeServiceConf.build().valueOr:
    return err("Store Conf building failed: " & $error)

  let mixConf = builder.mixConf.build().valueOr:
    return err("Mix Conf building failed: " & $error)

  var webSocketConf = builder.webSocketConf.build().valueOr:
    return err("WebSocket Conf building failed: " & $error)

  var quicConf = builder.quicConf.build().valueOr:
    return err("QUIC Conf building failed: " & $error)

  let rateLimit = builder.rateLimitConf.build().valueOr:
    return err("Rate limits Conf building failed: " & $error)

  let kademliaDiscoveryConf = builder.kademliaDiscoveryConf.build().valueOr:
    return err("Kademlia Discovery Conf building failed: " & $error)

  # End - Build sub-configs

  let logLevel =
    if builder.logLevel.isSome():
      builder.logLevel.get()
    else:
      warn "Log Level not specified, defaulting to INFO"
      DefaultLogLevel

  let logFormat =
    if builder.logFormat.isSome():
      builder.logFormat.get()
    else:
      warn "Log Format not specified, defaulting to TEXT"
      DefaultLogFormat

  let natStrategy =
    if builder.natStrategy.isSome():
      builder.natStrategy.get()
    else:
      warn "Nat Strategy is not specified, defaulting to none"
      DefaultNatStrategy

  var p2pTcpPort = builder.p2pTcpPort.get(DefaultP2pTcpPort)

  let p2pListenAddress =
    if builder.p2pListenAddress.isSome():
      builder.p2pListenAddress.get()
    else:
      warn "P2P listening address not specified, listening on 0.0.0.0"
      DefaultP2pListenAddress

  let portsShift =
    if builder.portsShift.isSome():
      builder.portsShift.get()
    else:
      warn "Ports Shift is not specified, defaulting to 0"
      DefaultPortsShift

  let dns4DomainName =
    if builder.dns4DomainName.isSome():
      let d = builder.dns4DomainName.get()
      if d.string != "":
        some(d)
      else:
        none(string)
    else:
      none(string)

  var extMultiAddrs: seq[MultiAddress] = @[]
  for s in builder.extMultiAddrs:
    let m = MultiAddress.init(s).valueOr:
      return err("Invalid multiaddress provided: " & s)
    extMultiAddrs.add(m)

  let extMultiAddrsOnly =
    if builder.extMultiAddrsOnly.isSome():
      builder.extMultiAddrsOnly.get()
    else:
      warn "Whether to only announce external multiaddresses is not specified, defaulting to false"
      DefaultExtMultiAddrsOnly

  let dnsAddrsNameServers =
    if builder.dnsAddrsNameServers.len != 0:
      builder.dnsAddrsNameServers
    else:
      warn "DNS name servers IPs not provided, defaulting to Cloudflare's."
      DefaultDnsAddrsNameServers

  let peerPersistence =
    if builder.peerPersistence.isSome():
      builder.peerPersistence.get()
    else:
      warn "Peer persistence not specified, defaulting to false"
      DefaultPeerPersistence

  let maxConnections =
    if builder.maxConnections.isSome():
      builder.maxConnections.get()
    else:
      warn "Max connections not specified, defaulting to DefaultMaxConnections",
        default = DefaultMaxConnections
      DefaultMaxConnections

  if maxConnections < DefaultMaxConnections:
    warn "max-connections less than DefaultMaxConnections; we suggest using DefaultMaxConnections or more for better connectivity",
      provided = maxConnections, recommended = DefaultMaxConnections

  let agentString = builder.agentString.get(DefaultAgentString)

  let colocationLimit = builder.colocationLimit.get(DefaultColocationLimit)

  # TODO: is there a strategy for experimental features? delete vs promote
  let relayShardedPeerManagement =
    builder.relayShardedPeerManagement.get(DefaultRelayShardedPeerManagement)

  let wakuFlags = CapabilitiesBitfield.init(
    lightpush = lightPush and relay,
    filter = filterServiceConf.isSome,
    store = storeServiceConf.isSome,
    relay = relay,
    sync = storeServiceConf.isSome() and storeServiceConf.get().storeSyncConf.isSome,
    mix = mix,
  )

  # portsShift is consumed here, WakuConf carries final bind ports.
  p2pTcpPort = resolvePortsShift(p2pTcpPort, portsShift)
  if webSocketConf.isSome():
    webSocketConf.get().port = resolvePortsShift(webSocketConf.get().port, portsShift)
  if quicConf.isSome():
    quicConf.get().port = resolvePortsShift(quicConf.get().port, portsShift)
  if discv5Conf.isSome():
    discv5Conf.get().udpPort = resolvePortsShift(discv5Conf.get().udpPort, portsShift)
  if restServerConf.isSome():
    restServerConf.get().port = resolvePortsShift(restServerConf.get().port, portsShift)
  if metricsServerConf.isSome():
    metricsServerConf.get().httpPort =
      resolvePortsShift(metricsServerConf.get().httpPort, portsShift)

  let wakuConf = WakuConf(
    # confs
    storeServiceConf: storeServiceConf,
    filterServiceConf: filterServiceConf,
    discv5Conf: discv5Conf,
    rlnRelayConf: rlnRelayConf,
    metricsServerConf: metricsServerConf,
    restServerConf: restServerConf,
    dnsDiscoveryConf: dnsDiscoveryConf,
    mixConf: mixConf,
    kademliaDiscoveryConf: kademliaDiscoveryConf,
    # end confs
    nodeKey: nodeKey,
    clusterId: clusterId,
    shardingConf: shardingConf,
    contentTopics: contentTopics,
    subscribeShards: subscribeShards,
    protectedShards: protectedShards,
    relay: relay,
    lightPush: lightPush,
    peerExchangeService: peerExchange,
    rendezvous: rendezvous,
    peerExchangeDiscovery: true,
      # enabling peer exchange client by default for quicker bootstrapping
    remoteStoreNode: builder.remoteStoreNode,
    remoteLightPushNode: builder.remoteLightPushNode,
    remoteFilterNode: builder.remoteFilterNode,
    remotePeerExchangeNode: builder.remotePeerExchangeNode,
    relayPeerExchange: relayPeerExchange,
    maxMessageSizeBytes: maxMessageSizeBytes,
    logLevel: logLevel,
    logFormat: logFormat,
    # TODO: Separate builders
    endpointConf: EndpointConf(
      natStrategy: natStrategy,
      p2pTcpPort: p2pTcpPort,
      dns4DomainName: dns4DomainName,
      p2pListenAddress: p2pListenAddress,
      extMultiAddrs: extMultiAddrs,
      extMultiAddrsOnly: extMultiAddrsOnly,
    ),
    webSocketConf: webSocketConf,
    quicConf: quicConf,
    dnsAddrsNameServers: dnsAddrsNameServers,
    peerPersistence: peerPersistence,
    peerStoreCapacity: builder.peerStoreCapacity,
    maxConnections: maxConnections,
    agentString: agentString,
    colocationLimit: colocationLimit,
    maxRelayPeers: builder.maxRelayPeers,
    relayServiceRatio: builder.relayServiceRatio.get(DefaultRelayServiceRatio),
    rateLimit: rateLimit,
    circuitRelayClient: builder.circuitRelayClient.get(DefaultCircuitRelayClient),
    staticNodes: builder.staticNodes,
    relayShardedPeerManagement: relayShardedPeerManagement,
    p2pReliability: builder.p2pReliability.get(DefaultP2pReliability),
    wakuFlags: wakuFlags,
    localStoragePath: builder.localStoragePath.get(DefaultStoragePath),
  )

  ?wakuConf.validate()

  return ok(wakuConf)
