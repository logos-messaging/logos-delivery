{.push raises: [].}

import
  std/[net, math],
  results,
  chronicles,
  libp2p/crypto/crypto,
  libp2p/builders,
  libp2p/nameresolving/nameresolver,
  libp2p/transports/wstransport,
  libp2p/protocols/connectivity/relay/relay,
  brokers/broker_context

import
  ../waku_enr,
  ../discovery/waku_discv5,
  ../waku_node,
  ../node/waku_switch,
  ../net/net_config,
  ../node/peer_manager,
  ../common/rate_limit/setting,
  ../common/utils/parse_size_units

type
  WakuNodeBuilder* = object # General
    nodeRng: Opt[crypto.Rng]
    nodeKey: Opt[crypto.PrivateKey]
    netConfig: Opt[NetConfig]
    record: Opt[enr.Record]

    # Peer storage and peer manager
    peerStorage: Opt[PeerStorage]
    peerStorageCapacity: Opt[int]

    # Peer manager config
    maxRelayPeers: int
    maxServicePeers: int
    colocationLimit: int
    shardAware: bool

    # Libp2p switch
    switchMaxConnections: Opt[int]
    switchNameResolver: Opt[NameResolver]
    switchAgentString: Opt[string]
    switchSslSecureKey: Opt[string]
    switchSslSecureCert: Opt[string]
    switchSendSignedPeerRecord: Opt[bool]
    switchNatConfig: Opt[NATConfig]
    switchNatPortMapperFactory: PortMapperFactory
    circuitRelay: Relay

    # Rate limit configs for non-relay req-resp protocols
    rateLimitSettings: Opt[ProtocolRateLimitSettings]

  WakuNodeBuilderResult* = Result[void, string]

## Init

proc init*(T: type WakuNodeBuilder): WakuNodeBuilder =
  WakuNodeBuilder()

## General

proc withRng*(builder: var WakuNodeBuilder, rng: crypto.Rng) =
  builder.nodeRng = Opt.some(rng)

proc withNodeKey*(builder: var WakuNodeBuilder, nodeKey: crypto.PrivateKey) =
  builder.nodeKey = Opt.some(nodeKey)

proc withRecord*(builder: var WakuNodeBuilder, record: enr.Record) =
  builder.record = Opt.some(record)

proc withNetworkConfiguration*(builder: var WakuNodeBuilder, config: NetConfig) =
  builder.netConfig = Opt.some(config)

proc withNetworkConfigurationDetails*(
    builder: var WakuNodeBuilder,
    bindIp: IpAddress,
    bindPort: Port,
    extIp = Opt.none(IpAddress),
    extPort = Opt.none(Port),
    extMultiAddrs = newSeq[MultiAddress](),
    wsBindPort: Port = Port(8000),
    wsEnabled: bool = false,
    wssEnabled: bool = false,
    wakuFlags = Opt.none(CapabilitiesBitfield),
    dns4DomainName = Opt.none(string),
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
    wsBindPort = Opt.some(wsBindPort),
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
    builder: var WakuNodeBuilder, peerStorage: PeerStorage, capacity = Opt.none(int)
) =
  if not peerStorage.isNil():
    builder.peerStorage = Opt.some(peerStorage)

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
  builder.rateLimitSettings = Opt.some(limits)

proc withCircuitRelay*(builder: var WakuNodeBuilder, circuitRelay: Relay) =
  builder.circuitRelay = circuitRelay

## Waku switch

proc withSwitchConfiguration*(
    builder: var WakuNodeBuilder,
    maxConnections = Opt.none(int),
    nameResolver: NameResolver = nil,
    sendSignedPeerRecord = false,
    secureKey = Opt.none(string),
    secureCert = Opt.none(string),
    agentString = Opt.none(string),
) =
  builder.switchMaxConnections = maxConnections
  builder.switchSendSignedPeerRecord = Opt.some(sendSignedPeerRecord)
  builder.switchSslSecureKey = secureKey
  builder.switchSslSecureCert = secureCert
  builder.switchAgentString = agentString

  if not nameResolver.isNil():
    builder.switchNameResolver = Opt.some(nameResolver)

proc withNatConfig*(
    builder: var WakuNodeBuilder,
    natConfig: Opt[NATConfig],
    portMapperFactory: PortMapperFactory = nil,
) =
  builder.switchNatConfig = natConfig
  builder.switchNatPortMapperFactory = portMapperFactory

## Build

proc build*(builder: WakuNodeBuilder): Result[WakuNode, string] =
  var rng: crypto.Rng
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
      quicAddress = builder.netConfig.get().quicHostAddress,
      transportFlags = {ServerFlags.ReuseAddr, ServerFlags.TcpNoDelay},
      rng = rng,
      maxConnections = builder.switchMaxConnections.get(MaxConnections),
      wssEnabled = builder.netConfig.get().wssEnabled,
      secureKeyPath = builder.switchSslSecureKey.get(""),
      secureCertPath = builder.switchSslSecureCert.get(""),
      nameResolver = builder.switchNameResolver.get(nil),
      sendSignedPeerRecord = builder.switchSendSignedPeerRecord.get(false),
      agentString = builder.switchAgentString,
      peerStoreCapacity = builder.peerStorageCapacity,
      circuitRelay = circuitRelay,
      natConfig = builder.switchNatConfig,
      natPortMapperFactory = builder.switchNatPortMapperFactory,
    )
  except CatchableError:
    return err("failed to create switch: " & getCurrentExceptionMsg())

  let peerManager = PeerManager.new(
    switch = switch,
    storage = builder.peerStorage.get(nil),
    maxRelayPeers = Opt.some(builder.maxRelayPeers),
    maxServicePeers = Opt.some(builder.maxServicePeers),
    colocationLimit = builder.colocationLimit,
    shardedPeerManagement = builder.shardAware,
    maxConnections = builder.switchMaxConnections.get(MaxConnections),
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
