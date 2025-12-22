import
  libp2p/crypto/crypto,
  libp2p/multiaddress,
  std/[net, options, sequtils],
  stint,
  chronicles,
  chronos,
  results

import
  ../waku_conf,
  ../networks_config,
  ../../common/logging,
  ../../common/utils/parse_size_units,
  ../../waku_enr/capabilities

import
  ./filter_service_conf_builder,
  ./store_sync_conf_builder,
  ./store_service_conf_builder,
  ./rest_server_conf_builder,
  ./dns_discovery_conf_builder,
  ./discv5_conf_builder,
  ./web_socket_conf_builder,
  ./metrics_server_conf_builder,
  ./rate_limit_conf_builder,
  ./rln_relay_conf_builder,
  ./mix_conf_builder

logScope:
  topics = "waku conf builder"

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
  rlnRelayConf*: RlnRelayConfBuilder
  storeServiceConf*: StoreServiceConfBuilder
  mixConf*: MixConfBuilder
  webSocketConf*: WebSocketConfBuilder
  rateLimitConf*: RateLimitConfBuilder
  # End conf builders
  relay: Option[bool]
  lightPush: Option[bool]
  peerExchange: Option[bool]
  storeSync: Option[bool]
  relayPeerExchange: Option[bool]
  mix: Option[bool]

  # TODO: move within a relayConf
  rendezvous: Option[bool]

  networkConf: Option[NetworkConf]

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

proc init*(T: type WakuConfBuilder): WakuConfBuilder =
  WakuConfBuilder(
    dnsDiscoveryConf: DnsDiscoveryConfBuilder.init(),
    discv5Conf: Discv5ConfBuilder.init(),
    filterServiceConf: FilterServiceConfBuilder.init(),
    metricsServerConf: MetricsServerConfBuilder.init(),
    restServerConf: RestServerConfBuilder.init(),
    rlnRelayConf: RlnRelayConfBuilder.init(),
    storeServiceConf: StoreServiceConfBuilder.init(),
    webSocketConf: WebSocketConfBuilder.init(),
    rateLimitConf: RateLimitConfBuilder.init(),
  )

proc withNetworkConf*(b: var WakuConfBuilder, networkConf: NetworkConf) =
  b.networkConf = some(networkConf)

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

proc withMaxRelayPeers*(b: var WakuConfBuilder, maxRelayPeers: int) =
  b.maxRelayPeers = some(maxRelayPeers)

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
    builder: WakuConfBuilder, rng: ref HmacDrbgContext
): Result[crypto.PrivateKey, string] =
  if builder.nodeKey.isSome():
    return ok(builder.nodeKey.get())
  else:
    warn "missing node key, generating new set"
    let nodeKey = crypto.PrivateKey.random(Secp256k1, rng[]).valueOr:
      error "Failed to generate key", error = error
      return err("Failed to generate key: " & $error)
    return ok(nodeKey)

proc buildShardingConf(
    bShardingConfKind: Option[ShardingConfKind],
    bNumShardsInCluster: Option[uint16],
    bSubscribeShards: Option[seq[uint16]],
): (ShardingConf, seq[uint16]) =
  echo "bSubscribeShards: ", bSubscribeShards
  case bShardingConfKind.get(AutoSharding)
  of StaticSharding:
    (ShardingConf(kind: StaticSharding), bSubscribeShards.get(@[]))
  of AutoSharding:
    let numShardsInCluster = bNumShardsInCluster.get(1)
    let shardingConf =
      ShardingConf(kind: AutoSharding, numShardsInCluster: numShardsInCluster)
    let upperShard = uint16(numShardsInCluster - 1)
    (shardingConf, bSubscribeShards.get(toSeq(0.uint16 .. upperShard)))

proc applyNetworkConf(builder: var WakuConfBuilder) =
  # Apply network conf, overrides most values passed individually
  # If you want to tweak values, don't use networkConf
  # TODO: networkconf should be one field of the conf builder so that this function becomes unnecessary
  if builder.networkConf.isNone():
    return
  let networkConf = builder.networkConf.get()

  if builder.clusterId.isSome():
    warn "Cluster id was provided alongside a network conf",
      used = networkConf.clusterId, discarded = builder.clusterId.get()
  builder.clusterId = some(networkConf.clusterId)

  # Apply relay parameters
  if builder.relay.get(false) and networkConf.rlnRelay:
    if builder.rlnRelayConf.enabled.isSome():
      warn "RLN Relay was provided alongside a network conf",
        used = networkConf.rlnRelay, discarded = builder.rlnRelayConf.enabled
    builder.rlnRelayConf.withEnabled(true)

    if builder.rlnRelayConf.ethContractAddress.get("") != "":
      warn "RLN Relay ETH Contract Address was provided alongside a network conf",
        used = networkConf.rlnRelayEthContractAddress.string,
        discarded = builder.rlnRelayConf.ethContractAddress.get().string
    builder.rlnRelayConf.withEthContractAddress(networkConf.rlnRelayEthContractAddress)

    if builder.rlnRelayConf.chainId.isSome():
      warn "RLN Relay Chain Id was provided alongside a network conf",
        used = networkConf.rlnRelayChainId, discarded = builder.rlnRelayConf.chainId
    builder.rlnRelayConf.withChainId(networkConf.rlnRelayChainId)

    if builder.rlnRelayConf.dynamic.isSome():
      warn "RLN Relay Dynamic was provided alongside a network conf",
        used = networkConf.rlnRelayDynamic, discarded = builder.rlnRelayConf.dynamic
    builder.rlnRelayConf.withDynamic(networkConf.rlnRelayDynamic)

    if builder.rlnRelayConf.epochSizeSec.isSome():
      warn "RLN Epoch Size in Seconds was provided alongside a network conf",
        used = networkConf.rlnEpochSizeSec,
        discarded = builder.rlnRelayConf.epochSizeSec
    builder.rlnRelayConf.withEpochSizeSec(networkConf.rlnEpochSizeSec)

    if builder.rlnRelayConf.userMessageLimit.isSome():
      warn "RLN Relay Dynamic was provided alongside a network conf",
        used = networkConf.rlnRelayUserMessageLimit,
        discarded = builder.rlnRelayConf.userMessageLimit
    builder.rlnRelayConf.withUserMessageLimit(networkConf.rlnRelayUserMessageLimit)
  # End Apply relay parameters

  case builder.maxMessageSize.kind
  of mmskNone:
    discard
  of mmskStr, mmskInt:
    warn "Max Message Size was provided alongside a network conf",
      used = networkConf.maxMessageSize, discarded = $builder.maxMessageSize
  builder.withMaxMessageSize(parseCorrectMsgSize(networkConf.maxMessageSize))

  if builder.shardingConf.isSome():
    warn "Sharding Conf was provided alongside a network conf",
      used = networkConf.shardingConf.kind, discarded = builder.shardingConf

  if builder.numShardsInCluster.isSome():
    warn "Num Shards In Cluster was provided alongside a network conf",
      used = networkConf.shardingConf.numShardsInCluster,
      discarded = builder.numShardsInCluster

  case networkConf.shardingConf.kind
  of StaticSharding:
    builder.shardingConf = some(StaticSharding)
  of AutoSharding:
    builder.shardingConf = some(AutoSharding)
    builder.numShardsInCluster = some(networkConf.shardingConf.numShardsInCluster)

  if networkConf.discv5Discovery:
    if builder.discv5Conf.enabled.isNone:
      builder.discv5Conf.withEnabled(networkConf.discv5Discovery)

    if builder.discv5Conf.bootstrapNodes.len == 0 and
        networkConf.discv5BootstrapNodes.len > 0:
      warn "Discv5 Bootstrap nodes were provided alongside a network conf",
        used = networkConf.discv5BootstrapNodes,
        discarded = builder.discv5Conf.bootstrapNodes
    builder.discv5Conf.withBootstrapNodes(networkConf.discv5BootstrapNodes)

proc build*(
    builder: var WakuConfBuilder, rng: ref HmacDrbgContext = crypto.newRng()
): Result[WakuConf, string] =
  ## Return a WakuConf that contains all mandatory parameters
  ## Applies some sane defaults that are applicable across any usage
  ## of libwaku. It aims to be agnostic so it does not apply a
  ## default when it is opinionated.

  applyNetworkConf(builder)

  let relay =
    if builder.relay.isSome():
      builder.relay.get()
    else:
      warn "whether to mount relay is not specified, defaulting to not mounting"
      false

  let lightPush =
    if builder.lightPush.isSome():
      builder.lightPush.get()
    else:
      warn "whether to mount lightPush is not specified, defaulting to not mounting"
      false

  let peerExchange =
    if builder.peerExchange.isSome():
      builder.peerExchange.get()
    else:
      warn "whether to mount peerExchange is not specified, defaulting to not mounting"
      false

  let storeSync =
    if builder.storeSync.isSome():
      builder.storeSync.get()
    else:
      warn "whether to mount storeSync is not specified, defaulting to not mounting"
      false

  let rendezvous =
    if builder.rendezvous.isSome():
      builder.rendezvous.get()
    else:
      warn "whether to mount rendezvous is not specified, defaulting to not mounting"
      false

  let mix =
    if builder.mix.isSome():
      builder.mix.get()
    else:
      warn "whether to mount mix is not specified, defaulting to not mounting"
      false

  let relayPeerExchange = builder.relayPeerExchange.get(false)

  let nodeKey = ?nodeKey(builder, rng)

  let clusterId =
    if builder.clusterId.isNone():
      # TODO: ClusterId should never be defaulted, instead, presets
      # should be defined and used
      warn("Cluster Id was not specified, defaulting to 0")
      0.uint16
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
      warn "Max Message Size not specified, defaulting to 150KiB"
      parseCorrectMsgSize("150KiB")

  let contentTopics = builder.contentTopics.get(@[])

  # Build sub-configs
  let discv5Conf = builder.discv5Conf.build().valueOr:
    return err("Discv5 Conf building failed: " & $error)

  let dnsDiscoveryConf = builder.dnsDiscoveryConf.build().valueOr:
    return err("DNS Discovery Conf building failed: " & $error)

  let filterServiceConf = builder.filterServiceConf.build().valueOr:
    return err("Filter Service Conf building failed: " & $error)

  let metricsServerConf = builder.metricsServerConf.build().valueOr:
    return err("Metrics Server Conf building failed: " & $error)

  let restServerConf = builder.restServerConf.build().valueOr:
    return err("REST Server Conf building failed: " & $error)

  let rlnRelayConf = builder.rlnRelayConf.build().valueOr:
    return err("RLN Relay Conf building failed: " & $error)

  let storeServiceConf = builder.storeServiceConf.build().valueOr:
    return err("Store Conf building failed: " & $error)

  let mixConf = builder.mixConf.build().valueOr:
    return err("Mix Conf building failed: " & $error)

  let webSocketConf = builder.webSocketConf.build().valueOr:
    return err("WebSocket Conf building failed: " & $error)

  let rateLimit = builder.rateLimitConf.build().valueOr:
    return err("Rate limits Conf building failed: " & $error)

  # End - Build sub-configs

  let logLevel =
    if builder.logLevel.isSome():
      builder.logLevel.get()
    else:
      warn "Log Level not specified, defaulting to INFO"
      logging.LogLevel.INFO

  let logFormat =
    if builder.logFormat.isSome():
      builder.logFormat.get()
    else:
      warn "Log Format not specified, defaulting to TEXT"
      logging.LogFormat.TEXT

  let natStrategy =
    if builder.natStrategy.isSome():
      builder.natStrategy.get()
    else:
      warn "Nat Strategy is not specified, defaulting to none"
      "none"

  let p2pTcpPort =
    if builder.p2pTcpPort.isSome():
      builder.p2pTcpPort.get()
    else:
      warn "P2P Listening TCP Port is not specified, listening on 60000"
      60000.Port

  let p2pListenAddress =
    if builder.p2pListenAddress.isSome():
      builder.p2pListenAddress.get()
    else:
      warn "P2P listening address not specified, listening on 0.0.0.0"
      (static parseIpAddress("0.0.0.0"))

  let portsShift =
    if builder.portsShift.isSome():
      builder.portsShift.get()
    else:
      warn "Ports Shift is not specified, defaulting to 0"
      0.uint16

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
      false

  let dnsAddrsNameServers =
    if builder.dnsAddrsNameServers.len != 0:
      builder.dnsAddrsNameServers
    else:
      warn "DNS name servers IPs not provided, defaulting to Cloudflare's."
      @[static parseIpAddress("1.1.1.1"), static parseIpAddress("1.0.0.1")]

  let peerPersistence =
    if builder.peerPersistence.isSome():
      builder.peerPersistence.get()
    else:
      warn "Peer persistence not specified, defaulting to false"
      false

  let maxConnections =
    if builder.maxConnections.isSome():
      builder.maxConnections.get()
    else:
      warn "Max Connections was not specified, defaulting to 300"
      300

  # TODO: Do the git version thing here
  let agentString = builder.agentString.get("nwaku")

  # TODO: use `DefaultColocationLimit`. the user of this value should
  # probably be defining a config object
  let colocationLimit = builder.colocationLimit.get(5)

  # TODO: is there a strategy for experimental features? delete vs promote
  let relayShardedPeerManagement = builder.relayShardedPeerManagement.get(false)

  let wakuFlags = CapabilitiesBitfield.init(
    lightpush = lightPush and relay,
    filter = filterServiceConf.isSome,
    store = storeServiceConf.isSome,
    relay = relay,
    sync = storeServiceConf.isSome() and storeServiceConf.get().storeSyncConf.isSome,
    mix = mix,
  )

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
    portsShift: portsShift,
    webSocketConf: webSocketConf,
    dnsAddrsNameServers: dnsAddrsNameServers,
    peerPersistence: peerPersistence,
    peerStoreCapacity: builder.peerStoreCapacity,
    maxConnections: maxConnections,
    agentString: agentString,
    colocationLimit: colocationLimit,
    maxRelayPeers: builder.maxRelayPeers,
    relayServiceRatio: builder.relayServiceRatio.get("60:40"),
    rateLimit: rateLimit,
    circuitRelayClient: builder.circuitRelayClient.get(false),
    staticNodes: builder.staticNodes,
    relayShardedPeerManagement: relayShardedPeerManagement,
    p2pReliability: builder.p2pReliability.get(false),
    wakuFlags: wakuFlags,
  )

  ?wakuConf.validate()

  return ok(wakuConf)
