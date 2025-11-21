import std/[net, options]

import results

import
  waku/common/utils/parse_size_units,
  waku/factory/waku_conf,
  waku/factory/conf_builder/conf_builder,
  waku/factory/networks_config,
  ./entry_nodes

type AutoShardingConfig* {.requiresInit.} = object
  numShardsInCluster*: uint16

type RlnConfig* {.requiresInit.} = object
  contractAddress*: string
  chainId*: uint
  epochSizeSec*: uint64

type NetworkingConfig* {.requiresInit.} = object
  listenIpv4*: string
  p2pTcpPort*: uint16
  discv5UdpPort*: uint16

type MessageValidation* {.requiresInit.} = object
  maxMessageSize*: string # Accepts formats like "150 KiB", "1500 B"
  rlnConfig*: Option[RlnConfig]

type ProtocolsConfig* {.requiresInit.} = object
  entryNodes: seq[string]
  staticStoreNodes: seq[string]
  clusterId: uint16
  autoShardingConfig: AutoShardingConfig
  messageValidation: MessageValidation

const DefaultNetworkingConfig* =
  NetworkingConfig(listenIpv4: "0.0.0.0", p2pTcpPort: 60000, discv5UdpPort: 9000)

const DefaultAutoShardingConfig* = AutoShardingConfig(numShardsInCluster: 1)

const DefaultMessageValidation* =
  MessageValidation(maxMessageSize: "150 KiB", rlnConfig: none(RlnConfig))

proc init*(
    T: typedesc[ProtocolsConfig],
    entryNodes: seq[string],
    staticStoreNodes: seq[string] = @[],
    clusterId: uint16,
    autoShardingConfig: AutoShardingConfig = DefaultAutoShardingConfig,
    messageValidation: MessageValidation = DefaultMessageValidation,
): T =
  return T(
    entryNodes: entryNodes,
    staticStoreNodes: staticStoreNodes,
    clusterId: clusterId,
    autoShardingConfig: autoShardingConfig,
    messageValidation: messageValidation,
  )

const TheWakuNetworkPreset* = ProtocolsConfig(
  entryNodes:
    @[
      "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
    ],
  staticStoreNodes: @[],
  clusterId: 1,
  autoShardingConfig: AutoShardingConfig(numShardsInCluster: 8),
  messageValidation: MessageValidation(
    maxMessageSize: "150 KiB",
    rlnConfig: some(
      RlnConfig(
        contractAddress: "0xB9cd878C90E49F797B4431fBF4fb333108CB90e6",
        chainId: 59141,
        epochSizeSec: 600, # 10 minutes
      )
    ),
  ),
)

type WakuMode* {.pure.} = enum
  Edge
  Core

type NodeConfig* {.requiresInit.} = object
  mode: WakuMode
  protocolsConfig: ProtocolsConfig
  networkingConfig: NetworkingConfig
  ethRpcEndpoints: seq[string]

proc init*(
    T: typedesc[NodeConfig],
    mode: WakuMode = WakuMode.Core,
    protocolsConfig: ProtocolsConfig = TheWakuNetworkPreset,
    networkingConfig: NetworkingConfig = DefaultNetworkingConfig,
    ethRpcEndpoints: seq[string] = @[],
): T =
  return T(
    mode: mode,
    protocolsConfig: protocolsConfig,
    networkingConfig: networkingConfig,
    ethRpcEndpoints: ethRpcEndpoints,
  )

proc toWakuConf*(nodeConfig: NodeConfig): Result[WakuConf, string] =
  var b = WakuConfBuilder.init()

  # Apply networking configuration
  let networkingConfig = nodeConfig.networkingConfig
  let ip = parseIpAddress(networkingConfig.listenIpv4)

  b.withP2pListenAddress(ip)
  b.withP2pTcpPort(networkingConfig.p2pTcpPort)
  b.discv5Conf.withUdpPort(networkingConfig.discv5UdpPort)

  case nodeConfig.mode
  of Core:
    b.withRelay(true)

    # Metadata is always mounted

    b.filterServiceConf.withEnabled(true)
    b.filterServiceConf.withMaxPeersToServe(20)

    b.withLightPush(true)

    b.discv5Conf.withEnabled(true)
    b.withPeerExchange(true)
    b.withRendezvous(true)

    # TODO: fix store as client usage

    b.rateLimitConf.withRateLimits(@["filter:100/1s", "lightpush:5/1s", "px:5/1s"])
  of Edge:
    # All client side protocols are mounted by default
    # Peer exchange client is always enabled and start_node will start the px loop
    discard
  ## Network Conf
  let protocolsConfig = nodeConfig.protocolsConfig

  # Set cluster ID
  b.withClusterId(protocolsConfig.clusterId)

  # Set sharding configuration
  b.withShardingConf(ShardingConfKind.AutoSharding)
  let autoShardingConfig = protocolsConfig.autoShardingConfig
  b.withNumShardsInCluster(autoShardingConfig.numShardsInCluster)

  # Process entry nodes - supports enrtree:, enr:, and multiaddress formats
  if protocolsConfig.entryNodes.len > 0:
    let (enrTreeUrls, bootstrapEnrs, staticNodesFromEntry) = processEntryNodes(
      protocolsConfig.entryNodes
    ).valueOr:
      return err("Failed to process entry nodes: " & error)

    # Set ENRTree URLs for DNS discovery
    if enrTreeUrls.len > 0:
      for url in enrTreeUrls:
        b.dnsDiscoveryConf.withEnrTreeUrl(url)
        b.dnsDiscoveryconf.withNameServers(
          @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")]
        )

    # Set ENR records as bootstrap nodes for discv5
    if bootstrapEnrs.len > 0:
      b.discv5Conf.withBootstrapNodes(bootstrapEnrs)

    # Add static nodes (multiaddrs and those extracted from ENR entries)
    if staticNodesFromEntry.len > 0:
      b.withStaticNodes(staticNodesFromEntry)

  # TODO: verify behaviour
  # Set static store nodes
  if protocolsConfig.staticStoreNodes.len > 0:
    b.withStaticNodes(protocolsConfig.staticStoreNodes)

  # Set message validation
  let msgValidation = protocolsConfig.messageValidation
  let maxSizeBytes = parseMsgSize(msgValidation.maxMessageSize).valueOr:
    return err("Failed to parse max message size: " & error)
  b.withMaxMessageSize(maxSizeBytes)

  # Set RLN config if provided
  if msgValidation.rlnConfig.isSome():
    let rlnConfig = msgValidation.rlnConfig.get()
    b.rlnRelayConf.withEnabled(true)
    b.rlnRelayConf.withEthContractAddress(rlnConfig.contractAddress)
    b.rlnRelayConf.withChainId(rlnConfig.chainId)
    b.rlnRelayConf.withEpochSizeSec(rlnConfig.epochSizeSec)
    b.rlnRelayConf.withDynamic(true)
    b.rlnRelayConf.withEthClientUrls(nodeConfig.ethRpcEndpoints)

    # TODO: we should get rid of those two
    b.rlnRelayconf.withUserMessageLimit(100)

  ## Various configurations
  b.withNatStrategy("any")

  let wakuConf = b.build().valueOr:
    return err("Failed to build configuration: " & error)

  wakuConf.validate().isOkOr:
    return err("Failed to validate configuration: " & error)

  return ok(wakuConf)
