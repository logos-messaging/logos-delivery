{.push raises: [].}

import
  std/[options, net, math],
  results,
  chronicles,
  libp2p/crypto/crypto,
  libp2p/builders,
  libp2p/nameresolving/nameresolver,
  libp2p/transports/wstransport,
  libp2p/protocols/connectivity/relay/relay
import
  ../waku_enr,
  ../discovery/waku_discv5,
  ../waku_node,
  ../node/peer_manager,
  ../common/rate_limit/setting,
  ../common/utils/parse_size_units,
  ../common/broker/broker_context

type
  WakuNodeBuilder* = object # General
    nodeRng: Option[ref crypto.HmacDrbgContext]
    nodeKey: Option[crypto.PrivateKey]
    netConfig: Option[NetConfig]
    record: Option[enr.Record]

    # Peer storage and peer manager
    peerStorage: Option[PeerStorage]
    peerStorageCapacity: Option[int]

    # Peer manager config
    maxRelayPeers: int
    maxServicePeers: int
    colocationLimit: int
    shardAware: bool

    # Libp2p switch
    switchMaxConnections: Option[int]
    switchNameResolver: Option[NameResolver]
    switchAgentString: Option[string]
    switchSslSecureKey: Option[string]
    switchSslSecureCert: Option[string]
    switchSendSignedPeerRecord: Option[bool]
    circuitRelay: Relay

    # Rate limit configs for non-relay req-resp protocols
    rateLimitSettings: Option[ProtocolRateLimitSettings]

  WakuNodeBuilderResult* = Result[void, string]

## Init

proc init*(T: type WakuNodeBuilder): WakuNodeBuilder =
  WakuNodeBuilder()

## General

proc withRng*(builder: var WakuNodeBuilder, rng: ref crypto.HmacDrbgContext) =
  builder.nodeRng = some(rng)

proc withNodeKey*(builder: var WakuNodeBuilder, nodeKey: crypto.PrivateKey) =
  builder.nodeKey = some(nodeKey)

proc withRecord*(builder: var WakuNodeBuilder, record: enr.Record) =
  builder.record = some(record)

proc withNetworkConfiguration*(builder: var WakuNodeBuilder, config: NetConfig) =
  builder.netConfig = some(config)

proc withNetworkConfigurationDetails*(
    builder: var WakuNodeBuilder,
    bindIp: IpAddress,
    bindPort: Port,
    extIp = none(IpAddress),
    extPort = none(Port),
    extMultiAddrs = newSeq[MultiAddress](),
    wsBindPort: Port = Port(8000),
    wsEnabled: bool = false,
    wssEnabled: bool = false,
    wakuFlags = none(CapabilitiesBitfield),
    dns4DomainName = none(string),
    dnsNameServers = @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")],
): WakuNodeBuilderResult {.
    deprecated: "use 'builder.withNetworkConfiguration()' instead"
.} =
  let netConfig = ?NetConfig.init(
    bindIp = bindIp,
    bindPort = bindPort,
    extIp = extIp,
    extPort = extPort,
    extMultiAddrs = extMultiAddrs,
    wsBindPort = some(wsBindPort),
    wsEnabled = wsEnabled,
    wssEnabled = wssEnabled,
    wakuFlags = wakuFlags,
    dns4DomainName = dns4DomainName,
    dnsNameServers = dnsNameServers,
  )
  builder.withNetworkConfiguration(netConfig)
  ok()

## Peer storage and peer manager

proc withPeerStorage*(
    builder: var WakuNodeBuilder, peerStorage: PeerStorage, capacity = none(int)
) =
  if not peerStorage.isNil():
    builder.peerStorage = some(peerStorage)

  builder.peerStorageCapacity = capacity

proc withPeerManagerConfig*(
    builder: var WakuNodeBuilder,
    maxConnections: int,
    relayServiceRatio: string,
    shardAware = false,
) =
  let (relayRatio, serviceRatio) = parseRelayServiceRatio(relayServiceRatio).get()
  var relayPeers = int(ceil(float(maxConnections) * relayRatio))
  var servicePeers = int(floor(float(maxConnections) * serviceRatio))

  builder.maxServicePeers = servicePeers
  builder.maxRelayPeers = relayPeers
  builder.shardAware = shardAware

proc withColocationLimit*(builder: var WakuNodeBuilder, colocationLimit: int) =
  builder.colocationLimit = colocationLimit

proc withRateLimit*(builder: var WakuNodeBuilder, limits: ProtocolRateLimitSettings) =
  builder.rateLimitSettings = some(limits)

proc withCircuitRelay*(builder: var WakuNodeBuilder, circuitRelay: Relay) =
  builder.circuitRelay = circuitRelay

## Waku switch

proc withSwitchConfiguration*(
    builder: var WakuNodeBuilder,
    maxConnections = none(int),
    nameResolver: NameResolver = nil,
    sendSignedPeerRecord = false,
    secureKey = none(string),
    secureCert = none(string),
    agentString = none(string),
) =
  builder.switchMaxConnections = maxConnections
  builder.switchSendSignedPeerRecord = some(sendSignedPeerRecord)
  builder.switchSslSecureKey = secureKey
  builder.switchSslSecureCert = secureCert
  builder.switchAgentString = agentString

  if not nameResolver.isNil():
    builder.switchNameResolver = some(nameResolver)

## Build

proc build*(builder: WakuNodeBuilder): Result[WakuNode, string] =
  var rng: ref crypto.HmacDrbgContext
  if builder.nodeRng.isNone():
    rng = crypto.newRng()
  else:
    rng = builder.nodeRng.get()

  if builder.nodeKey.isNone():
    return err("node key is required")

  if builder.netConfig.isNone():
    return err("network configuration is required")

  let netConfig = builder.netConfig.get()
  if netConfig.dnsNameServers.len == 0:
    return err("DNS name servers are required for WakuNode")

  if builder.record.isNone():
    return err("node record is required")

  let circuitRelay =
    if builder.circuitRelay.isNil():
      Relay.new()
    else:
      builder.circuitRelay

  var switch: Switch
  try:
    switch = newWakuSwitch(
      privKey = builder.nodekey,
      address = builder.netConfig.get().hostAddress,
      wsAddress = builder.netConfig.get().wsHostAddress,
      transportFlags = {ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay},
      rng = rng,
      maxConnections = builder.switchMaxConnections.get(builders.MaxConnections),
      wssEnabled = builder.netConfig.get().wssEnabled,
      secureKeyPath = builder.switchSslSecureKey.get(""),
      secureCertPath = builder.switchSslSecureCert.get(""),
      nameResolver = builder.switchNameResolver.get(nil),
      sendSignedPeerRecord = builder.switchSendSignedPeerRecord.get(false),
      agentString = builder.switchAgentString,
      peerStoreCapacity = builder.peerStorageCapacity,
      circuitRelay = circuitRelay,
    )
  except CatchableError:
    return err("failed to create switch: " & getCurrentExceptionMsg())

  let peerManager = PeerManager.new(
    switch = switch,
    storage = builder.peerStorage.get(nil),
    maxRelayPeers = some(builder.maxRelayPeers),
    maxServicePeers = some(builder.maxServicePeers),
    colocationLimit = builder.colocationLimit,
    shardedPeerManagement = builder.shardAware,
    maxConnections = builder.switchMaxConnections.get(builders.MaxConnections),
  )

  var node: WakuNode
  try:
    node = WakuNode.new(
      netConfig = netConfig,
      enr = builder.record.get(),
      switch = switch,
      peerManager = peerManager,
      rng = rng,
      rateLimitSettings = builder.rateLimitSettings.get(DefaultProtocolRateLimit),
    )
  except Exception:
    return err("failed to build WakuNode instance: " & getCurrentExceptionMsg())

  ok(node)
