import std/[net, options]

import results
import json_serialization, json_serialization/std/options as json_options

import
  waku/common/utils/parse_size_units,
  waku/common/logging,
  waku/factory/waku_conf,
  waku/factory/conf_builder/conf_builder,
  waku/factory/networks_config,
  ./entry_nodes

export json_serialization, json_options

type AutoShardingConfig* = object
  numShardsInCluster*: uint16

type RlnConfig* = object
  contractAddress*: string
  chainId*: uint
  epochSizeSec*: uint64

type NetworkingConfig* = object
  listenIpv4*: string
  p2pTcpPort*: uint16
  discv5UdpPort*: uint16

type MessageValidation* = object
  maxMessageSize*: string # Accepts formats like "150 KiB", "1500 B"
  rlnConfig*: Option[RlnConfig]

type ProtocolsConfig* = object
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
  entryNodes: @[
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
  p2pReliability: bool
  logLevel: LogLevel
  logFormat: LogFormat

proc init*(
    T: typedesc[NodeConfig],
    mode: WakuMode = WakuMode.Core,
    protocolsConfig: ProtocolsConfig = TheWakuNetworkPreset,
    networkingConfig: NetworkingConfig = DefaultNetworkingConfig,
    ethRpcEndpoints: seq[string] = @[],
    p2pReliability: bool = false,
    logLevel: LogLevel = LogLevel.INFO,
    logFormat: LogFormat = LogFormat.TEXT,
): T =
  return T(
    mode: mode,
    protocolsConfig: protocolsConfig,
    networkingConfig: networkingConfig,
    ethRpcEndpoints: ethRpcEndpoints,
    p2pReliability: p2pReliability,
    logLevel: logLevel,
    logFormat: logFormat,
  )

# -- Getters for ProtocolsConfig (private fields) - used for testing --

proc entryNodes*(c: ProtocolsConfig): seq[string] =
  c.entryNodes

proc staticStoreNodes*(c: ProtocolsConfig): seq[string] =
  c.staticStoreNodes

proc clusterId*(c: ProtocolsConfig): uint16 =
  c.clusterId

proc autoShardingConfig*(c: ProtocolsConfig): AutoShardingConfig =
  c.autoShardingConfig

proc messageValidation*(c: ProtocolsConfig): MessageValidation =
  c.messageValidation

# -- Getters for NodeConfig (private fields) - used for testing --

proc mode*(c: NodeConfig): WakuMode =
  c.mode

proc protocolsConfig*(c: NodeConfig): ProtocolsConfig =
  c.protocolsConfig

proc networkingConfig*(c: NodeConfig): NetworkingConfig =
  c.networkingConfig

proc ethRpcEndpoints*(c: NodeConfig): seq[string] =
  c.ethRpcEndpoints

proc p2pReliability*(c: NodeConfig): bool =
  c.p2pReliability

proc logLevel*(c: NodeConfig): LogLevel =
  c.logLevel

proc logFormat*(c: NodeConfig): LogFormat =
  c.logFormat

proc toWakuConf*(nodeConfig: NodeConfig): Result[WakuConf, string] =
  var b = WakuConfBuilder.init()

  # Apply log configuration
  b.withLogLevel(nodeConfig.logLevel)
  b.withLogFormat(nodeConfig.logFormat)

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
    # Metadata is always mounted
    b.withPeerExchange(true)
    # switch off all service side protocols and relay
    b.withRelay(false)
    b.filterServiceConf.withEnabled(false)
    b.withLightPush(false)
    b.storeServiceConf.withEnabled(false)
    # Leave discv5 and rendezvous for user choice

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
  b.withP2PReliability(nodeConfig.p2pReliability)

  let wakuConf = b.build().valueOr:
    return err("Failed to build configuration: " & error)

  wakuConf.validate().isOkOr:
    return err("Failed to validate configuration: " & error)

  return ok(wakuConf)

# ---- JSON serialization (writeValue / readValue) ----
# ---------- AutoShardingConfig ----------

proc writeValue*(w: var JsonWriter, val: AutoShardingConfig) {.raises: [IOError].} =
  w.beginRecord()
  w.writeField("numShardsInCluster", val.numShardsInCluster)
  w.endRecord()

proc readValue*(
    r: var JsonReader, val: var AutoShardingConfig
) {.raises: [SerializationError, IOError].} =
  var numShardsInCluster: Option[uint16]

  for fieldName in readObjectFields(r):
    case fieldName
    of "numShardsInCluster":
      numShardsInCluster = some(r.readValue(uint16))
    else:
      r.raiseUnexpectedField(fieldName, "AutoShardingConfig")

  if numShardsInCluster.isNone():
    r.raiseUnexpectedValue("Missing required field 'numShardsInCluster'")

  val = AutoShardingConfig(numShardsInCluster: numShardsInCluster.get())

# ---------- RlnConfig ----------

proc writeValue*(w: var JsonWriter, val: RlnConfig) {.raises: [IOError].} =
  w.beginRecord()
  w.writeField("contractAddress", val.contractAddress)
  w.writeField("chainId", val.chainId)
  w.writeField("epochSizeSec", val.epochSizeSec)
  w.endRecord()

proc readValue*(
    r: var JsonReader, val: var RlnConfig
) {.raises: [SerializationError, IOError].} =
  var
    contractAddress: Option[string]
    chainId: Option[uint]
    epochSizeSec: Option[uint64]

  for fieldName in readObjectFields(r):
    case fieldName
    of "contractAddress":
      contractAddress = some(r.readValue(string))
    of "chainId":
      chainId = some(r.readValue(uint))
    of "epochSizeSec":
      epochSizeSec = some(r.readValue(uint64))
    else:
      r.raiseUnexpectedField(fieldName, "RlnConfig")

  if contractAddress.isNone():
    r.raiseUnexpectedValue("Missing required field 'contractAddress'")
  if chainId.isNone():
    r.raiseUnexpectedValue("Missing required field 'chainId'")
  if epochSizeSec.isNone():
    r.raiseUnexpectedValue("Missing required field 'epochSizeSec'")

  val = RlnConfig(
    contractAddress: contractAddress.get(),
    chainId: chainId.get(),
    epochSizeSec: epochSizeSec.get(),
  )

# ---------- NetworkingConfig ----------

proc writeValue*(w: var JsonWriter, val: NetworkingConfig) {.raises: [IOError].} =
  w.beginRecord()
  w.writeField("listenIpv4", val.listenIpv4)
  w.writeField("p2pTcpPort", val.p2pTcpPort)
  w.writeField("discv5UdpPort", val.discv5UdpPort)
  w.endRecord()

proc readValue*(
    r: var JsonReader, val: var NetworkingConfig
) {.raises: [SerializationError, IOError].} =
  var
    listenIpv4: Option[string]
    p2pTcpPort: Option[uint16]
    discv5UdpPort: Option[uint16]

  for fieldName in readObjectFields(r):
    case fieldName
    of "listenIpv4":
      listenIpv4 = some(r.readValue(string))
    of "p2pTcpPort":
      p2pTcpPort = some(r.readValue(uint16))
    of "discv5UdpPort":
      discv5UdpPort = some(r.readValue(uint16))
    else:
      r.raiseUnexpectedField(fieldName, "NetworkingConfig")

  if listenIpv4.isNone():
    r.raiseUnexpectedValue("Missing required field 'listenIpv4'")
  if p2pTcpPort.isNone():
    r.raiseUnexpectedValue("Missing required field 'p2pTcpPort'")
  if discv5UdpPort.isNone():
    r.raiseUnexpectedValue("Missing required field 'discv5UdpPort'")

  val = NetworkingConfig(
    listenIpv4: listenIpv4.get(),
    p2pTcpPort: p2pTcpPort.get(),
    discv5UdpPort: discv5UdpPort.get(),
  )

# ---------- MessageValidation ----------

proc writeValue*(w: var JsonWriter, val: MessageValidation) {.raises: [IOError].} =
  w.beginRecord()
  w.writeField("maxMessageSize", val.maxMessageSize)
  w.writeField("rlnConfig", val.rlnConfig)
  w.endRecord()

proc readValue*(
    r: var JsonReader, val: var MessageValidation
) {.raises: [SerializationError, IOError].} =
  var
    maxMessageSize: Option[string]
    rlnConfig: Option[Option[RlnConfig]]

  for fieldName in readObjectFields(r):
    case fieldName
    of "maxMessageSize":
      maxMessageSize = some(r.readValue(string))
    of "rlnConfig":
      rlnConfig = some(r.readValue(Option[RlnConfig]))
    else:
      r.raiseUnexpectedField(fieldName, "MessageValidation")

  if maxMessageSize.isNone():
    r.raiseUnexpectedValue("Missing required field 'maxMessageSize'")

  val = MessageValidation(
    maxMessageSize: maxMessageSize.get(), rlnConfig: rlnConfig.get(none(RlnConfig))
  )

# ---------- ProtocolsConfig ----------

proc writeValue*(w: var JsonWriter, val: ProtocolsConfig) {.raises: [IOError].} =
  w.beginRecord()
  w.writeField("entryNodes", val.entryNodes)
  w.writeField("staticStoreNodes", val.staticStoreNodes)
  w.writeField("clusterId", val.clusterId)
  w.writeField("autoShardingConfig", val.autoShardingConfig)
  w.writeField("messageValidation", val.messageValidation)
  w.endRecord()

proc readValue*(
    r: var JsonReader, val: var ProtocolsConfig
) {.raises: [SerializationError, IOError].} =
  var
    entryNodes: Option[seq[string]]
    staticStoreNodes: Option[seq[string]]
    clusterId: Option[uint16]
    autoShardingConfig: Option[AutoShardingConfig]
    messageValidation: Option[MessageValidation]

  for fieldName in readObjectFields(r):
    case fieldName
    of "entryNodes":
      entryNodes = some(r.readValue(seq[string]))
    of "staticStoreNodes":
      staticStoreNodes = some(r.readValue(seq[string]))
    of "clusterId":
      clusterId = some(r.readValue(uint16))
    of "autoShardingConfig":
      autoShardingConfig = some(r.readValue(AutoShardingConfig))
    of "messageValidation":
      messageValidation = some(r.readValue(MessageValidation))
    else:
      r.raiseUnexpectedField(fieldName, "ProtocolsConfig")

  if entryNodes.isNone():
    r.raiseUnexpectedValue("Missing required field 'entryNodes'")
  if clusterId.isNone():
    r.raiseUnexpectedValue("Missing required field 'clusterId'")

  val = ProtocolsConfig.init(
    entryNodes = entryNodes.get(),
    staticStoreNodes = staticStoreNodes.get(@[]),
    clusterId = clusterId.get(),
    autoShardingConfig = autoShardingConfig.get(DefaultAutoShardingConfig),
    messageValidation = messageValidation.get(DefaultMessageValidation),
  )

# ---------- NodeConfig ----------

proc writeValue*(w: var JsonWriter, val: NodeConfig) {.raises: [IOError].} =
  w.beginRecord()
  w.writeField("mode", val.mode)
  w.writeField("protocolsConfig", val.protocolsConfig)
  w.writeField("networkingConfig", val.networkingConfig)
  w.writeField("ethRpcEndpoints", val.ethRpcEndpoints)
  w.writeField("p2pReliability", val.p2pReliability)
  w.writeField("logLevel", val.logLevel)
  w.writeField("logFormat", val.logFormat)
  w.endRecord()

proc readValue*(
    r: var JsonReader, val: var NodeConfig
) {.raises: [SerializationError, IOError].} =
  var
    mode: Option[WakuMode]
    protocolsConfig: Option[ProtocolsConfig]
    networkingConfig: Option[NetworkingConfig]
    ethRpcEndpoints: Option[seq[string]]
    p2pReliability: Option[bool]
    logLevel: Option[LogLevel]
    logFormat: Option[LogFormat]

  for fieldName in readObjectFields(r):
    case fieldName
    of "mode":
      mode = some(r.readValue(WakuMode))
    of "protocolsConfig":
      protocolsConfig = some(r.readValue(ProtocolsConfig))
    of "networkingConfig":
      networkingConfig = some(r.readValue(NetworkingConfig))
    of "ethRpcEndpoints":
      ethRpcEndpoints = some(r.readValue(seq[string]))
    of "p2pReliability":
      p2pReliability = some(r.readValue(bool))
    of "logLevel":
      logLevel = some(r.readValue(LogLevel))
    of "logFormat":
      logFormat = some(r.readValue(LogFormat))
    else:
      r.raiseUnexpectedField(fieldName, "NodeConfig")

  val = NodeConfig.init(
    mode = mode.get(WakuMode.Core),
    protocolsConfig = protocolsConfig.get(TheWakuNetworkPreset),
    networkingConfig = networkingConfig.get(DefaultNetworkingConfig),
    ethRpcEndpoints = ethRpcEndpoints.get(@[]),
    p2pReliability = p2pReliability.get(false),
    logLevel = logLevel.get(LogLevel.INFO),
    logFormat = logFormat.get(LogFormat.TEXT),
  )

# ---------- Decode helper ----------
# Json.decode returns T via `result`, which conflicts with {.requiresInit.}
# on Nim 2.x. This helper avoids the issue by using readValue into a var.

proc decodeNodeConfigFromJson*(
    jsonStr: string
): NodeConfig {.raises: [SerializationError].} =
  var val = NodeConfig.init() # default-initialized
  try:
    var stream = unsafeMemoryInput(jsonStr)
    var reader = (JsonReader[DefaultFlavor].init(stream))
    reader.readValue(val)
  except IOError as err:
    raise (ref SerializationError)(msg: err.msg)
  return val
