import
  std/[net, options, strutils],
  chronicles,
  libp2p/crypto/crypto,
  libp2p/multiaddress,
  libp2p/crypto/curve25519,
  libp2p/peerid,
  secp256k1,
  results

import
  ../waku_rln_relay/rln_relay,
  ../rest_api/endpoint/builder,
  ../discovery/waku_discv5,
  ../node/waku_metrics,
  ../common/logging,
  ../common/rate_limit/setting,
  ../waku_enr/capabilities,
  ./networks_config,
  ../waku_mix

export RlnRelayConf, RlnRelayCreds, RestServerConf, Discv5Conf, MetricsServerConf

logScope:
  topics = "waku conf"

type WebSocketSecureConf* {.requiresInit.} = object
  keyPath*: string
  certPath*: string

type WebSocketConf* = object
  port*: Port
  secureConf*: Option[WebSocketSecureConf]

type QuicConf* = object
  port*: Port

# TODO: should be defined in validator_signed.nim and imported here
type ProtectedShard* {.requiresInit.} = object
  shard*: uint16
  key*: secp256k1.SkPublicKey

type DnsDiscoveryConf* {.requiresInit.} = object
  enrTreeUrl*: string
  # TODO: should probably only have one set of name servers (see dnsaddrs)
  nameServers*: seq[IpAddress]

type StoreSyncConf* {.requiresInit.} = object
  rangeSec*: uint32
  intervalSec*: uint32
  relayJitterSec*: uint32

type MixConf* = ref object
  mixKey*: Curve25519Key
  mixPubKey*: Curve25519Key
  mixnodes*: seq[MixNodePubInfo]

type KademliaDiscoveryConf* = object
  bootstrapNodes*: seq[(PeerId, seq[MultiAddress])]
    ## Bootstrap nodes for extended kademlia discovery.

type StoreServiceConf* {.requiresInit.} = object
  dbMigration*: bool
  dbURl*: string
  dbVacuum*: bool
  maxNumDbConnections*: int
  retentionPolicies*: seq[string]
  resume*: bool
  storeSyncConf*: Option[StoreSyncConf]

type FilterServiceConf* {.requiresInit.} = object
  maxPeersToServe*: uint32
  subscriptionTimeout*: uint16
  maxCriteria*: uint32

type EndpointConf* = object # TODO: make enum
  natStrategy*: string
  p2pTcpPort*: Port
  dns4DomainName*: Option[string]
  p2pListenAddress*: IpAddress
  extMultiAddrs*: seq[MultiAddress]
  extMultiAddrsOnly*: bool

## `WakuConf` is a valid configuration for a Waku node
## All information needed by a waku node should be contained
## In this object. A convenient `validate` method enables doing
## sanity checks beyond type enforcement.
## If `Option` is `some` it means the related protocol is enabled.
type WakuConf* {.requiresInit.} = ref object
  # ref because `getRunningNetConfig` modifies it
  nodeKey*: crypto.PrivateKey

  clusterId*: uint16
  subscribeShards*: seq[uint16]
  protectedShards*: seq[ProtectedShard]

  shardingConf*: ShardingConf
  contentTopics*: seq[string]

  relay*: bool
  lightPush*: bool
  peerExchangeService*: bool
  peerExchangeDiscovery*: bool

  # TODO: remove relay peer exchange
  relayPeerExchange*: bool
  rendezvous*: bool
  circuitRelayClient*: bool

  discv5Conf*: Option[Discv5Conf]
  dnsDiscoveryConf*: Option[DnsDiscoveryConf]
  filterServiceConf*: Option[FilterServiceConf]
  storeServiceConf*: Option[StoreServiceConf]
  rlnRelayConf*: Option[RlnRelayConf]
  restServerConf*: Option[RestServerConf]
  metricsServerConf*: Option[MetricsServerConf]
  webSocketConf*: Option[WebSocketConf]
  quicConf*: Option[QuicConf]
  mixConf*: Option[MixConf]
  kademliaDiscoveryConf*: Option[KademliaDiscoveryConf]

  portsShift*: uint16
  dnsAddrsNameServers*: seq[IpAddress]
  endpointConf*: EndpointConf
  wakuFlags*: CapabilitiesBitfield

  # TODO: could probably make it a `PeerRemoteInfo`
  staticNodes*: seq[string]
  remoteStoreNode*: Option[string]
  remoteLightPushNode*: Option[string]
  remoteFilterNode*: Option[string]
  remotePeerExchangeNode*: Option[string]

  maxMessageSizeBytes*: uint64

  logLevel*: logging.LogLevel
  logFormat*: logging.LogFormat

  peerPersistence*: bool
  # TODO: should clearly be a uint
  peerStoreCapacity*: Option[int]
  # TODO: should clearly be a uint
  maxConnections*: int

  agentString*: string

  colocationLimit*: int

  rateLimit*: ProtocolRateLimitSettings

  # TODO: those could be in a relay conf object
  maxRelayPeers*: Option[int]
  relayShardedPeerManagement*: bool
  # TODO: use proper type
  relayServiceRatio*: string

  p2pReliability*: bool

proc logConf*(conf: WakuConf) =
  info "Configuration: Enabled protocols",
    relay = conf.relay,
    rlnRelay = conf.rlnRelayConf.isSome(),
    store = conf.storeServiceConf.isSome(),
    filter = conf.filterServiceConf.isSome(),
    lightPush = conf.lightPush,
    peerExchange = conf.peerExchangeService,
    rendezvous = conf.rendezvous

  info "Configuration. Network", cluster = conf.clusterId

  for shard in conf.subscribeShards:
    info "Configuration. Active Relay Shards", shard = shard

  if conf.discv5Conf.isSome():
    for i in conf.discv5Conf.get().bootstrapNodes:
      info "Configuration. Bootstrap nodes", node = i.string

  if conf.rlnRelayConf.isSome():
    var rlnRelayConf = conf.rlnRelayConf.get()
    if rlnRelayConf.dynamic:
      info "Configuration. Validation",
        mechanism = "onchain rln",
        contract = rlnRelayConf.ethContractAddress.string,
        maxMessageSize = conf.maxMessageSizeBytes,
        rlnEpochSizeSec = rlnRelayConf.epochSizeSec,
        rlnRelayUserMessageLimit = rlnRelayConf.userMessageLimit

proc validateNodeKey(wakuConf: WakuConf): Result[void, string] =
  wakuConf.nodeKey.getPublicKey().isOkOr:
    return err("nodekey param is invalid")
  return ok()

proc validateNoEmptyStrings(wakuConf: WakuConf): Result[void, string] =
  if wakuConf.endpointConf.dns4DomainName.isSome() and
      isEmptyOrWhiteSpace(wakuConf.endpointConf.dns4DomainName.get().string):
    return err("dns4-domain-name is an empty string, set it to none(string) instead")

  if isEmptyOrWhiteSpace(wakuConf.relayServiceRatio):
    return err("relay-service-ratio is an empty string")

  for sn in wakuConf.staticNodes:
    if isEmptyOrWhiteSpace(sn):
      return err("staticnode contain an empty string")

  if wakuConf.remoteStoreNode.isSome() and
      isEmptyOrWhiteSpace(wakuConf.remoteStoreNode.get()):
    return err("storenode is an empty string, set it to none(string) instead")

  if wakuConf.remoteLightPushNode.isSome() and
      isEmptyOrWhiteSpace(wakuConf.remoteLightPushNode.get()):
    return err("lightpushnode is an empty string, set it to none(string) instead")

  if wakuConf.remotePeerExchangeNode.isSome() and
      isEmptyOrWhiteSpace(wakuConf.remotePeerExchangeNode.get()):
    return err("peer-exchange-node is an empty string, set it to none(string) instead")

  if wakuConf.remoteFilterNode.isSome() and
      isEmptyOrWhiteSpace(wakuConf.remoteFilterNode.get()):
    return err("filternode is an empty string, set it to none(string) instead")

  if wakuConf.dnsDiscoveryConf.isSome() and
      isEmptyOrWhiteSpace(wakuConf.dnsDiscoveryConf.get().enrTreeUrl):
    return err("dns-discovery-url is an empty string")

  # TODO: rln relay config should validate itself
  if wakuConf.rlnRelayConf.isSome():
    let rlnRelayConf = wakuConf.rlnRelayConf.get()

    if rlnRelayConf.ethClientUrls.len == 0:
      return err("rln-relay-eth-client-address is empty")
    if isEmptyOrWhiteSpace(rlnRelayConf.ethContractAddress):
      return err("rln-relay-eth-contract-address is an empty string")

    if rlnRelayConf.creds.isSome():
      let creds = rlnRelayConf.creds.get()
      if isEmptyOrWhiteSpace(creds.path):
        return err ("rln-relay-cred-path is an empty string")
      if isEmptyOrWhiteSpace(creds.password):
        return err ("rln-relay-cred-password is an empty string")

  return ok()

proc validate*(wakuConf: WakuConf): Result[void, string] =
  ?wakuConf.validateNodeKey()
  ?wakuConf.shardingConf.validateShards(wakuConf.subscribeShards)
  ?wakuConf.validateNoEmptyStrings()
  return ok()
