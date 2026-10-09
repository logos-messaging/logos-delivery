## CLI configuration of logosdeliverynode.

import
  std/[strutils, strformat, sequtils],
  results,
  chronicles,
  chronos,
  regex,
  stew/endians2,
  confutils,
  confutils/defs,
  confutils/std/net,
  confutils/toml/defs as confTomlDefs,
  confutils/toml/std/net as confTomlNet,
  libp2p/crypto/curve25519,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  nimcrypto/utils,
  secp256k1,
  json,
  mix_rln_spam_protection/[constants, module_api]

import
  logos_delivery/api/conf/modes,
  logos_delivery/api/conf/messaging_node_conf,
  logos_delivery/waku/net/nat_strategy,
  logos_delivery/waku/factory/[waku_conf, conf_builder/conf_builder, networks_config],
  logos_delivery/waku/factory/conf_builder/rest_server_conf_builder,
  logos_delivery/waku/common/[logging],
  logos_delivery/waku/[
    waku_enr,
    node/peer_manager,
    waku_core/topics/pubsub_topic,
    waku_core/message/default_values,
    waku_mix,
  ],
  ./entry_nodes

import ./envvar as confEnvvarDefs, ./envvar_net as confEnvvarNet

export
  confTomlDefs, confTomlNet, confEnvvarDefs, confEnvvarNet, ProtectedShard,
  DefaultMaxWakuMessageSizeStr, DefaultAgentString, modes, messaging_node_conf

logScope:
  topics = "waku cli args"

# Git version in git describe format (defined at compile time)
const git_version* {.strdefine.} = "n/a"

const NodeEnvvarPrefix* = "logos_delivery_node"
  ## `--tcp-port` reads `LOGOS_DELIVERY_NODE_TCP_PORT`.

# CLI defaults that differ from confbuilder defaults
const
  DefaultCLIRelay* = true
  DefaultCLIPeerExchange* = true
  DefaultCLIRendezvous* = true
  DefaultCLINat* = "any"
  DefaultCliRestMessagingCacheCapacity* = DefaultRestMessagingCacheCapacity
    ## Exported because confutils expands `defaultValue` where `load` is called.

# Each `ModeProtocolFlags` field that the config and the mode do not set gets
# its value from `DefaultKernelModeFlags`. Apply it after the mode, so that the
# mode and the explicit flags have priority.
const DefaultKernelModeFlags* = ModeProtocolFlags(
  relay: Opt.some(DefaultCLIRelay),
  filter: Opt.some(true),
  lightpush: Opt.some(true),
  store: Opt.some(false),
  discv5Discovery: Opt.some(true),
  peerExchange: Opt.some(DefaultCLIPeerExchange),
  rendezvous: Opt.some(DefaultCLIRendezvous),
)

type ConfResult*[T] = Result[T, string]

type EthRpcUrl* = distinct string

type WakuNodeConf* = object
  configFile* {.
    desc: "Loads configuration from a TOML file (cmd-line parameters take precedence)",
    name: "config-file"
  .}: Opt[InputFile]

  ## Log configuration
  logLevel* {.
    desc:
      "Sets the log level for process. Supported levels: TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL",
    defaultValue: logging.LogLevel.INFO,
    name: "log-level"
  .}: logging.LogLevel

  logFormat* {.
    desc:
      "Specifies what kind of logs should be written to stdout. Supported formats: TEXT, JSON",
    defaultValue: logging.LogFormat.TEXT,
    name: "log-format"
  .}: logging.LogFormat

  rlnRelayCredPath* {.
    desc: "The path for persisting rln-relay credential (requires --rln-relay)",
    defaultValue: "",
    name: "rln-relay-cred-path"
  .}: string

  ethClientUrls* {.
    desc:
      "HTTP address of an Ethereum testnet client e.g., http://localhost:8540/. Argument may be repeated. (requires --rln-relay)",
    defaultValue: @[EthRpcUrl("http://localhost:8540/")],
    name: "rln-relay-eth-client-address"
  .}: seq[EthRpcUrl]

  rlnRelayEthContractAddress* {.
    desc:
      "Address of membership contract on an Ethereum testnet. (requires --rln-relay)",
    defaultValue: "",
    name: "rln-relay-eth-contract-address"
  .}: string

  rlnRelayChainId* {.
    desc:
      "Chain ID of the provided contract (optional, will fetch from RPC provider if not used) (requires --rln-relay)",
    defaultValue: 0,
    name: "rln-relay-chain-id"
  .}: uint

  rlnRelayCredPassword* {.
    desc: "Password for encrypting RLN credentials (requires --rln-relay)",
    defaultValue: "",
    name: "rln-relay-cred-password"
  .}: string

  rlnRelayEthPrivateKey* {.
    obsolete: "ignored, set it on the rlnkeystore tool instead; removed in v0.42.0",
    desc: "Deprecated and ignored. Only the rlnkeystore tool uses it.",
    defaultValue: "",
    name: "rln-relay-eth-private-key"
  .}: string

  # Opt-typed; desc states the default since the CLI can't auto-show it for Opt.none().
  rlnRelayUserMessageLimit* {.
    desc:
      "Set a user message limit for the rln membership registration. Must be a positive integer. Default is " &
      $DefaultRlnRelayUserMessageLimit & ". (requires --rln-relay)",
    defaultValue: Opt.none(uint64),
    name: "rln-relay-user-message-limit"
  .}: Opt[uint64]

  # Opt-typed; desc states the default since the CLI can't auto-show it for Opt.none().
  rlnEpochSizeSec* {.
    desc:
      "Epoch size in seconds used to rate limit RLN memberships. Default is " &
      $DefaultRlnRelayEpochSizeSec & " second. (requires --rln-relay)",
    defaultValue: Opt.none(uint64),
    name: "rln-relay-epoch-sec"
  .}: Opt[uint64]

  maxMessageSize* {.
    desc:
      "Maximum message size. Accepted units: KiB, KB, and B. e.g. 1024KiB; 1500 B; etc.",
    defaultValue: DefaultMaxWakuMessageSizeStr,
    name: "max-msg-size"
  .}: string

  ##  Application-level configuration
  protectedShards* {.
    desc:
      "Shards and its public keys to be used for message validation, shard:pubkey. Argument may be repeated.",
    defaultValue: newSeq[ProtectedShard](0),
    name: "protected-shard"
  .}: seq[ProtectedShard]

  ## General node config
  preset* {.
    desc:
      "Network preset to use. 'twn' is The RLN-protected Waku Network (cluster 1). 'logos.dev' is the Logos Dev Network (cluster 3). 'logos.test' is the Logos Test Network (cluster 2). 'status.prod' is the Status Production Network (cluster 16, RLN off, auto-sharding with 1 shard). Overrides other values.",
    defaultValue: "",
    name: "preset"
  .}: string

  # Opt-typed; desc states the default since the CLI can't auto-show it for Opt.none().
  clusterId* {.
    desc: static(
      "Cluster id that the node is running in. Node in a different cluster id is disconnected. Default is " &
        $DefaultClusterId & "."
    ),
    defaultValue: Opt.none(uint16),
    name: "cluster-id"
  .}: Opt[uint16]

  agentString* {.
    obsolete: "unused; removed in v0.42.0",
    defaultValue: DefaultAgentString,
    desc: "Node agent string which is used as identifier in network",
    name: "agent-string"
  .}: string

  nodekey* {.desc: "P2P node private key as 64 char hex string.", name: "nodekey".}:
    Opt[PrivateKey]

  listenAddress* {.
    defaultValue: defaultListenAddress(),
    desc: "Listening address for LibP2P (and Discovery v5, if enabled) traffic.",
    name: "listen-address"
  .}: IpAddress

  tcpPort* {.desc: "TCP listening port.", defaultValue: 60000, name: "tcp-port".}: Port

  portsShift* {.
    obsolete: "set each port to 0 to auto-assign; removed in v0.42.0",
    desc: "Deprecated. Add a shift to all port numbers.",
    defaultValue: 0,
    name: "ports-shift"
  .}: uint16

  nat* {.
    desc:
      "Specify method to use for determining public address. " &
      "Must be one of: any, none, upnp, pmp, extip:<IP>.",
    defaultValue: DefaultCLINat,
    name: "nat"
  .}: string

  natDiscoveryTimeoutMs* {.
    obsolete: "unused; removed in v0.42.0",
    desc: "Time limit in milliseconds for NAT gateway discovery.",
    defaultValue: defaultNatDiscoveryTimeoutMs(),
    name: "nat-discovery-timeout-ms"
  .}: uint32

  extMultiAddrs* {.
    desc:
      "External multiaddresses to advertise to the network. Argument may be repeated.",
    name: "ext-multiaddr"
  .}: seq[string]

  extMultiAddrsOnly* {.
    obsolete: "unused; removed in v0.42.0",
    desc: "Deprecated. Only announce external multiaddresses setup with --ext-multiaddr",
    defaultValue: false,
    name: "ext-multiaddr-only"
  .}: bool

  maxConnections* {.
    desc:
      "Maximum allowed number of libp2p connections. (Default: 150) that's recommended value for better connectivity",
    defaultValue: 150,
    name: "max-connections"
  .}: int

  relayServiceRatio* {.
    desc:
      "This percentage ratio represents the relay peers to service peers. For example, 60:40, tells that 60% of the max-connections will be used for relay protocol and the other 40% of max-connections will be reserved for other service protocols (e.g., filter, lightpush, store, metadata, etc.)",
    defaultValue: "50:50",
    name: "relay-service-ratio"
  .}: string

  colocationLimit* {.
    desc:
      "Max num allowed peers from the same IP. Set it to 0 to remove the limitation.",
    defaultValue: defaultColocationLimit(),
    name: "ip-colocation-limit"
  .}: int

  # Opt-typed; desc states the default since the CLI can't auto-show it for Opt.none().
  maxPureLibp2pPeers* {.
    desc:
      "Max inbound peers that are not waku nodes but offer a protocol this node consumes (kademlia service discovery, mix). 0 admits none. Default is 20 without a network preset; logos.dev and logos.test presets set 50, other presets 0.",
    defaultValue: Opt.none(int),
    name: "max-pure-libp2p-peers"
  .}: Opt[int]

  peerStoreCapacity* {.
    obsolete: "unused; removed in v0.42.0",
    desc: "Deprecated. Maximum stored peers in the peerstore.",
    name: "peer-store-capacity"
  .}: Opt[int]

  peerPersistence* {.
    desc: "Enable peer persistence.", defaultValue: false, name: "peer-persistence"
  .}: bool

  ## DNS addrs config
  dnsAddrsNameServers* {.
    desc:
      "DNS name server IPs to query for DNS multiaddrs resolution. Argument may be repeated.",
    defaultValue: @[
      IpAddress(family: IpAddressFamily.IPv4, address_v4: [1'u8, 1, 1, 1]),
      IpAddress(family: IpAddressFamily.IPv4, address_v4: [1'u8, 0, 0, 1]),
    ],
    name: "dns-addrs-name-server"
  .}: seq[IpAddress]

  dns4DomainName* {.
    desc: "The domain name resolving to the node's public IPv4 address",
    defaultValue: "",
    name: "dns4-domain-name"
  .}: string

  ## Circuit-relay config
  circuitRelayClient* {.
    desc: """Set the node as a circuit-relay client.
Set it to true for nodes that run behind a NAT or firewall and
hence would have reachability issues.""",
    defaultValue: false,
    name: "circuit-relay-client"
  .}: bool

  isRelayClient* {.
    obsolete: "use --circuit-relay-client; removed in v0.42.0",
    desc: "Deprecated. Use --circuit-relay-client instead.",
    defaultValue: false,
    name: "relay-client"
  .}: bool

  ## Relay config
  relay* {.
    desc: "Enable relay protocol: true|false. Default is true.",
    defaultValue: Opt.none(bool),
    name: "relay"
  .}: Opt[bool]

  relayPeerExchange* {.
    obsolete: "unused; removed in v0.42.0",
    desc: "Enable gossipsub peer exchange in relay protocol: true|false",
    defaultValue: false,
    name: "relay-peer-exchange"
  .}: bool

  relayShardedPeerManagement* {.
    desc: "Enable experimental shard aware peer manager for relay protocol: true|false",
    defaultValue: false,
    name: "relay-shard-manager"
  .}: bool

  # Opt-typed; desc states the default since the CLI can't auto-show it for Opt.none().
  rlnRelay* {.
    desc:
      "Enable spam protection through rln-relay: true|false. Default is " &
      $DefaultRlnRelayEnabled & ".",
    defaultValue: Opt.none(bool),
    name: "rln-relay"
  .}: Opt[bool]

  rlnRelayCredIndex* {.
    desc: "The index of the onchain commitment to use (requires --rln-relay)",
    name: "rln-relay-membership-index"
  .}: Opt[uint]

  rlnRelayDynamic* {.
    obsolete: "not needed, on-chain RLN is the only mode; removed in v0.42.0",
    desc: "Deprecated. On-chain dynamic group management is the only RLN mode.",
    defaultValue: Opt.none(bool),
    name: "rln-relay-dynamic"
  .}: Opt[bool]

  rlnDisableValidation* {.
    desc: "Disable validation RLN proofs of received messages: true|false",
    defaultValue: false,
    name: "rln-disable-validation"
  .}: bool

  entryNodes* {.
    desc:
      "Entry node address (enrtree:, enr:, or multiaddr). " &
      "Automatically classified and distributed to DNS discovery, discv5 bootstrap, " &
      "and static nodes. Argument may be repeated.",
    name: "entry-node"
  .}: seq[string]

  staticnodes* {.
    obsolete: "use --entry-node; removed in v0.42.0",
    desc: "Deprecated. Use --entry-node, which accepts multiaddrs too.",
    name: "staticnode"
  .}: seq[string]

  numShardsInNetwork* {.
    desc:
      "Enables autosharding and set number of shards in the cluster, set to `0` to use static sharding",
    defaultValue: 0,
    name: "num-shards-in-network"
  .}: uint16

  shards* {.
    desc:
      "Shards index to subscribe to [0..NUM_SHARDS_IN_NETWORK-1]. Argument may be repeated. Subscribes to all shards by default in auto-sharding, no shard for static sharding",
    name: "shard"
  .}: seq[uint16]

  contentTopics* {.
    desc: "Default content topic to subscribe to. Argument may be repeated.",
    name: "content-topic"
  .}: seq[string]

  ## Store and message store config
  store* {.
    desc: "Enable/disable waku store protocol. Default is false.",
    defaultValue: Opt.none(bool),
    name: "store"
  .}: Opt[bool]

  storenode* {.
    desc: "Peer multiaddress to query for storage", defaultValue: "", name: "storenode"
  .}: string

  storeMessageRetentionPolicy* {.
    desc:
      "Message store retention policy. Multiple policies may be provided as a semicolon-separated string and are applied as a union. Time retention policy: 'time:<seconds>'. Capacity retention policy: 'capacity:<count>'. Size retention policy: 'size:<xMB/xGB>'. Set to 'none' to disable. Example: 'time:3600;size:1GB;capacity:100'. (requires --store)",
    defaultValue: "time:" & $2.days.seconds,
    name: "store-message-retention-policy"
  .}: string

  storeMessageDbUrl* {.
    desc: "The database connection URL for persistent storage. (requires --store)",
    defaultValue: "sqlite://store.sqlite3",
    name: "store-message-db-url"
  .}: string

  storeMessageDbVacuum* {.
    desc:
      "Enable database vacuuming at start. Only supported by SQLite database engine. (requires --store)",
    defaultValue: false,
    name: "store-message-db-vacuum"
  .}: bool

  storeMessageDbMigration* {.
    obsolete: "migrations always run; removed in v0.42.0",
    desc: "Enable database migration at start. (requires --store)",
    defaultValue: true,
    name: "store-message-db-migration"
  .}: bool

  storeMaxNumDbConnections* {.
    desc: "Maximum number of simultaneous Postgres connections. (requires --store)",
    defaultValue: 50,
    name: "store-max-num-db-connections"
  .}: int

  storeResume* {.
    obsolete: "use --store-sync; removed in v0.42.0",
    desc: "Enable store resume functionality (requires --store)",
    defaultValue: false,
    name: "store-resume"
  .}: bool

  ## Sync config
  storeSync* {.
    desc: "Enable store sync protocol: true|false (requires --store)",
    defaultValue: false,
    name: "store-sync"
  .}: bool

  storeSyncInterval* {.
    desc: "Interval between store sync attempts. In seconds. (requires --store-sync)",
    defaultValue: 300, # 5 minutes
    name: "store-sync-interval"
  .}: uint32

  storeSyncRange* {.
    desc: "Amount of time to sync. In seconds. (requires --store-sync)",
    defaultValue: 3600, # 1 hour
    name: "store-sync-range"
  .}: uint32

  storeSyncRelayJitter* {.
    hidden,
    desc:
      "Time offset to account for message propagation jitter. In seconds. (requires --store-sync)",
    defaultValue: 20,
    name: "store-sync-relay-jitter"
  .}: uint32

  ## Filter config
  filter* {.
    desc: "Enable filter protocol: true|false. Default is true.",
    defaultValue: Opt.none(bool),
    name: "filter"
  .}: Opt[bool]

  filternode* {.
    desc: "Peer multiaddr to request content filtering of messages.",
    defaultValue: "",
    name: "filternode"
  .}: string

  filterSubscriptionTimeout* {.
    obsolete: "unused, the default is kept; removed in v0.42.0",
    desc:
      "Timeout in seconds for a filter subscription that is not pinged or refreshed. (requires --filter)",
    defaultValue: 300, # 5 minutes
    name: "filter-subscription-timeout"
  .}: uint16

  filterMaxPeersToServe* {.
    obsolete: "unused, the default is kept; removed in v0.42.0",
    desc: "Maximum number of filter peers to serve at a time. (requires --filter)",
    defaultValue: 1000,
    name: "filter-max-peers-to-serve"
  .}: uint32

  filterMaxCriteria* {.
    obsolete: "unused, the default is kept; removed in v0.42.0",
    desc:
      "Maximum number of pubsub and content topic combinations per peer at a time. (requires --filter)",
    defaultValue: 1000,
    name: "filter-max-criteria"
  .}: uint32

  ## Lightpush config
  lightpush* {.
    desc: "Enable lightpush protocol: true|false. Default is true.",
    defaultValue: Opt.none(bool),
    name: "lightpush"
  .}: Opt[bool]

  lightpushnode* {.
    desc: "Peer multiaddr to request lightpush of published messages.",
    defaultValue: "",
    name: "lightpushnode"
  .}: string

  ## REST HTTP config
  rest* {.
    desc: "Enable Waku REST HTTP server: true|false", defaultValue: false, name: "rest"
  .}: bool

  restAddress* {.
    desc: "Listening address of the REST HTTP server. (requires --rest)",
    defaultValue: IpAddress(family: IpAddressFamily.IPv4, address_v4: [127'u8, 0, 0, 1]),
    name: "rest-address"
  .}: IpAddress

  restPort* {.
    desc: "Listening port of the REST HTTP server. (requires --rest)",
    defaultValue: 8645,
    name: "rest-port"
  .}: uint16

  restRelayCacheCapacity* {.
    desc: "Capacity of the Relay REST API message cache. (requires --rest)",
    defaultValue: 50,
    name: "rest-relay-cache-capacity"
  .}: uint32

  restMessagingCacheCapacity* {.
    desc:
      "Capacity of the messaging REST API received-messages cache. The newest messages are kept until polled. (requires --rest)",
    defaultValue: DefaultCliRestMessagingCacheCapacity,
    name: "rest-messaging-cache-capacity"
  .}: uint32

  restAdmin* {.
    desc: "Enable access to REST HTTP Admin API: true|false (requires --rest)",
    defaultValue: false,
    name: "rest-admin"
  .}: bool

  restAllowOrigin* {.
    desc:
      "Allow cross-origin requests from the specified origin. " &
      "Argument may be repeated. Wildcards: * or ? allowed. " &
      "Ex.: \"localhost:*\" or \"127.0.0.1:8080\" (requires --rest)",
    defaultValue: newSeq[string](),
    name: "rest-allow-origin"
  .}: seq[string]

  ## Metrics config
  metricsServer* {.
    desc: "Enable the metrics server: true|false",
    defaultValue: false,
    name: "metrics-server"
  .}: bool

  metricsServerAddress* {.
    desc: "Listening address of the metrics server. (requires --metrics-server)",
    defaultValue: IpAddress(family: IpAddressFamily.IPv4, address_v4: [127'u8, 0, 0, 1]),
    name: "metrics-server-address"
  .}: IpAddress

  metricsServerPort* {.
    desc: "Listening HTTP port of the metrics server. (requires --metrics-server)",
    defaultValue: 8008,
    name: "metrics-server-port"
  .}: uint16

  metricsLogging* {.
    obsolete: "the metrics server covers it; removed in v0.42.0",
    desc: "Deprecated. Enable metrics logging: true|false",
    defaultValue: true,
    name: "metrics-logging"
  .}: bool

  ## DNS discovery config
  dnsDiscovery* {.
    obsolete: "ignored, use --dns-discovery-url; removed in v0.42.0",
    desc: "Deprecated and ignored. Set --dns-discovery-url instead.",
    defaultValue: false,
    name: "dns-discovery"
  .}: bool

  dnsDiscoveryUrl* {.
    desc:
      "URL for DNS node list in format 'enrtree://<key>@<fqdn>', enables DNS Discovery",
    defaultValue: "",
    name: "dns-discovery-url"
  .}: string

  ## Discovery v5 config
  discv5Discovery* {.
    desc: "Enable discovering nodes via Node Discovery v5. Default is true.",
    defaultValue: Opt.none(bool),
    name: "discv5-discovery"
  .}: Opt[bool]

  discv5UdpPort* {.
    desc: "Listening UDP port for Node Discovery v5. (requires --discv5-discovery)",
    defaultValue: 9000,
    name: "discv5-udp-port"
  .}: Port

  discv5BootstrapNodes* {.
    obsolete: "use --entry-node; removed in v0.42.0",
    desc:
      "Text-encoded ENR for bootstrap node. Used when connecting to the network. Argument may be repeated. (requires --discv5-discovery)",
    name: "discv5-bootstrap-node"
  .}: seq[string]

  discv5EnrAutoUpdate* {.
    desc:
      "Discovery can automatically update its ENR with the IP address " &
      "and UDP port as seen by other nodes it communicates with. " &
      "This option allows to enable/disable this functionality (requires --discv5-discovery)",
    defaultValue: false,
    name: "discv5-enr-auto-update"
  .}: bool

  discv5TableIpLimit* {.
    obsolete: "tuning knob; removed in v0.42.0",
    desc:
      "Maximum amount of nodes with the same IP in discv5 routing tables (requires --discv5-discovery)",
    defaultValue: 10,
    name: "discv5-table-ip-limit"
  .}: uint

  discv5BucketIpLimit* {.
    obsolete: "tuning knob; removed in v0.42.0",
    desc:
      "Maximum amount of nodes with the same IP in discv5 routing table buckets (requires --discv5-discovery)",
    defaultValue: 2,
    name: "discv5-bucket-ip-limit"
  .}: uint

  discv5BitsPerHop* {.
    obsolete: "tuning knob; removed in v0.42.0",
    desc:
      "Kademlia's b variable, increase for less hops per lookup (requires --discv5-discovery)",
    defaultValue: 1,
    name: "discv5-bits-per-hop"
  .}: int

  ## waku peer exchange config
  peerExchange* {.
    desc:
      "Enable waku peer exchange protocol (responder side): true|false. Default is true.",
    defaultValue: Opt.none(bool),
    name: "peer-exchange"
  .}: Opt[bool]

  peerExchangeNode* {.
    desc:
      "Peer multiaddr to send peer exchange requests to. (enables peer exchange protocol requester side)",
    defaultValue: "",
    name: "peer-exchange-node"
  .}: string

  ## Rendez vous
  rendezvous* {.
    desc: "Enable waku rendezvous discovery server. Default is true.",
    defaultValue: Opt.none(bool),
    name: "rendezvous"
  .}: Opt[bool]

  #Mix config
  # Opt-typed; desc states the default since the CLI can't auto-show it for Opt.none().
  mix* {.
    desc: "Enable mix protocol: true|false. Default is " & $DefaultMix & ".",
    defaultValue: Opt.none(bool),
    name: "mix"
  .}: Opt[bool]

  mixkey* {.
    desc:
      "ED25519 private key as 64 char hex string, without 0x. If not provided, a random key will be generated. (requires --mix)",
    name: "mixkey"
  .}: Opt[string]

  mixnodes* {.
    desc:
      "A mix node to seed the pool with, as multiaddr:mixPubKey. The multiaddress carries a /p2p/<peer id> on TCP or QUIC-v1 over IPv4 (directly or through a circuit relay), or names its host (dns4), which is resolved after the mount. Argument may be repeated. (requires --mix)",
    name: "mixnode"
  .}: seq[MixNodePubInfo]

  mixRlnRegistryId* {.
    desc:
      "Shared RLN module registry for Mix per-hop proofs; empty disables the adapter.",
    defaultValue: "",
    name: "mix-rln-registry-id"
  .}: string

  mixRlnIdentifierHex* {.
    desc: "Mix application RLN identifier (32-byte hex).",
    defaultValue: "6d69782d726c6e2d7370616d2d70726f74656374696f6e2f7631000000000000",
    name: "mix-rln-identifier-hex"
  .}: string

  mixRlnMetadataTopic* {.
    desc:
      "Delivery content topic for Mix proof metadata; required with mix-rln-registry-id.",
    defaultValue: "",
    name: "mix-rln-metadata-topic"
  .}: string

  # Kademlia Discovery config
  # Opt-typed; desc states the default since the CLI can't auto-show it for Opt.none().
  enableKadDiscovery* {.
    desc:
      "Enable extended kademlia discovery. Can be enabled without bootstrap nodes for the first node in the network. Default is " &
      $DefaultKadEnabled & ".",
    defaultValue: Opt.none(bool),
    name: "enable-kad-discovery"
  .}: Opt[bool]

  kadBootstrapNodes* {.
    desc:
      "Peer multiaddr for kademlia discovery bootstrap node (must include /p2p/<peerID>). Argument may be repeated. (requires --enable-kad-discovery or --plugin-kad-discovery)",
    name: "kad-bootstrap-node"
  .}: seq[string]

  kadRandomLookupIntervalSec* {.
    desc:
      "Interval seconds between random kademlia lookups. 0 (the default) disables them. (requires --enable-kad-discovery or --plugin-kad-discovery)",
    defaultValue: 0,
    name: "kad-random-lookup-interval"
  .}: uint32

  kadServiceLookupIntervalSec* {.
    desc:
      "Interval seconds between service-specific kademlia lookups. (requires --enable-kad-discovery or --plugin-kad-discovery)",
    defaultValue: 60,
    name: "kad-service-lookup-interval"
  .}: uint32

  # Plugin-hosted Kademlia discovery
  # The same service discovery as above, hosted by an externally registered
  # plugin instead of in-process. Mutually exclusive with the in-process
  # backend; the lookup intervals above apply to whichever is running.
  pluginKadDiscovery* {.
    desc:
      "Run kademlia service discovery through an externally registered plugin " &
      "instead of in-process. Turns off in-process kademlia discovery. Default is " &
      $DefaultPluginKadEnabled & ".",
    defaultValue: Opt.none(bool),
    name: "plugin-kad-discovery"
  .}: Opt[bool]

  ## websocket config
  websocketSupport* {.
    desc: "Enable websocket: true|false", defaultValue: false, name: "websocket-support"
  .}: bool

  websocketPort* {.
    desc: "WebSocket listening port. (requires --websocket-support)",
    defaultValue: 8000,
    name: "websocket-port"
  .}: Port

  websocketSecureSupport* {.
    desc: "Enable secure websocket: true|false (requires --websocket-support)",
    defaultValue: false,
    name: "websocket-secure-support"
  .}: bool

  websocketSecureKeyPath* {.
    desc:
      "Secure websocket key path: '/path/to/key.txt' (requires --websocket-secure-support)",
    defaultValue: "",
    name: "websocket-secure-key-path"
  .}: string

  websocketSecureCertPath* {.
    desc:
      "Secure websocket certificate path: '/path/to/cert.txt' (requires --websocket-secure-support)",
    defaultValue: "",
    name: "websocket-secure-cert-path"
  .}: string

  ## quic config
  quicSupport* {.
    desc: "Enable QUIC transport: true|false", defaultValue: true, name: "quic-support"
  .}: bool

  # Opt-typed; desc states the default since the CLI can't auto-show it for Opt.none().
  quicPort* {.
    desc:
      "QUIC (UDP) listening port. Default is the TCP port (--tcp-port). (requires --quic-support)",
    defaultValue: Opt.none(Port),
    name: "quic-port"
  .}: Opt[Port]

  ## Entries are merged over the default service limits (filter 100/1s, lightpush 5/1s, px 5/1s)
  ## unless a global entry is given, which replaces the defaults of the protocols not named
  rateLimits* {.
    desc:
      "Rate limit settings for different protocols, merged over the defaults filter:100/1s, lightpush:5/1s and px:5/1s." &
      " A protocol you do not set keeps its default, unless you give a global setting (no protocol), which then applies to every protocol you do not name." &
      " A volume of 0 disables the limit, e.g. lightpush:0/1s." &
      " Format: protocol:volume/period<unit>." &
      " Where 'protocol' can be one of: <store|storev3|lightpush|px|filter>; if not defined it means a global setting." &
      " 'volume' and 'period' must be integer values." &
      " 'unit' must be one of <h|m|s|ms> - hours, minutes, seconds, milliseconds respectively. " &
      "Argument may be repeated.",
    defaultValue: newSeq[string](0),
    name: "rate-limit"
  .}: seq[string]

  localStoragePath* {.
    desc: "Path to store local data.",
    defaultValue: "./data",
    name: "local-storage-path"
  .}: string

## Parsing

# NOTE: Keys are different in nim-libp2p
proc parseCmdArg*(T: type crypto.PrivateKey, p: string): T =
  try:
    let key = SkPrivateKey.init(utils.fromHex(p)).tryGet()
    crypto.PrivateKey(scheme: Secp256k1, skkey: key)
  except CatchableError:
    raise newException(ValueError, "Invalid private key")

proc parseCmdArg*[T](_: type seq[T], s: string): seq[T] {.raises: [ValueError].} =
  var
    inputSeq: JsonNode
    res: seq[T] = @[]

  try:
    inputSeq = s.parseJson()
  except Exception:
    raise newException(ValueError, fmt"Could not parse sequence: {s}")

  for entry in inputSeq:
    let formattedString = ($entry).strip(chars = {'\"'})
    res.add(parseCmdArg(T, formattedString))

  return res

proc completeCmdArg*(T: type crypto.PrivateKey, val: string): seq[string] =
  return @[]

# TODO: Remove when removing protected-topic configuration
proc isNumber(x: string): bool =
  try:
    discard parseInt(x)
    result = true
  except ValueError:
    result = false

proc parseCmdArg*(T: type MixNodePubInfo, p: string): T =
  return parseMixNode(p).valueOr:
    raise newException(ValueError, error)

proc parseCmdArg*(T: type ProtectedShard, p: string): T =
  let elements = p.split(":")
  if elements.len != 2:
    raise newException(
      ValueError, "Invalid format for protected shard expected shard:publickey"
    )
  let publicKey = secp256k1.SkPublicKey.fromHex(elements[1]).valueOr:
    raise newException(ValueError, "Invalid public key")

  if isNumber(elements[0]):
    return ProtectedShard(shard: uint16.parseCmdArg(elements[0]), key: publicKey)

  # TODO: Remove when removing protected-topic configuration
  let shard = RelayShard.parse(elements[0]).valueOr:
    raise newException(
      ValueError,
      "Invalid pubsub topic. Pubsub topics must be in the format /waku/2/rs/<cluster-id>/<shard-id>",
    )
  return ProtectedShard(shard: shard.shardId, key: publicKey)

proc completeCmdArg*(T: type ProtectedShard, val: string): seq[string] =
  return @[]

proc completeCmdArg*(T: type IpAddress, val: string): seq[string] =
  return @[]

proc defaultNatDiscoveryTimeoutMs*(): uint32 =
  DefaultNatDiscoveryTimeoutMs

proc defaultListenAddress*(): IpAddress =
  # TODO: Should probably listen on both ipv4 and ipv6 by default.
  (static IpAddress(family: IpAddressFamily.IPv4, address_v4: [0'u8, 0, 0, 0]))

proc defaultColocationLimit*(): int =
  return DefaultColocationLimit

proc completeCmdArg*(T: type Port, val: string): seq[string] =
  return @[]

proc completeCmdArg*(T: type EthRpcUrl, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type EthRpcUrl, s: string): T =
  ## allowed patterns:
  ## http://url:port
  ## https://url:port
  ## http://url:port/path
  ## https://url:port/path
  ## http://url/with/path
  ## http://url:port/path?query
  ## https://url:port/path?query
  ## https://username:password@url:port/path
  ## https://username:password@url:port/path?query
  ## supports IPv4, IPv6, URL-encoded credentials
  ## disallowed patterns:
  ## any valid/invalid ws or wss url
  var httpPattern =
    re2"^(https?):\/\/(([^\s:@]*(?:%[0-9A-Fa-f]{2})*):([^\s:@]*(?:%[0-9A-Fa-f]{2})*)@)?((?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?|(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)|\[[0-9a-fA-F:]+\])(?::([0-9]{1,5}))?(\/[^\s?#]*)?(\?[^\s#]*)?(#[^\s]*)?$"
  var wsPattern =
    re2"^(wss?):\/\/([\w-]+(\.[\w-]+)+)(:[0-9]{1,5})?(\/[\w.,@?^=%&:\/~+#-]*)?$"
  if regex.match(s, wsPattern):
    raise newException(
      ValueError, "Websocket RPC URL is not supported, Please use an HTTP URL"
    )
  if not regex.match(s, httpPattern):
    raise newException(ValueError, "Invalid HTTP RPC URL")
  return EthRpcUrl(s)

## Load

proc readValue*(
    r: var TomlReader, value: var crypto.PrivateKey
) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(crypto.PrivateKey, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

proc readValue*(
    r: var EnvvarReader, value: var crypto.PrivateKey
) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(crypto.PrivateKey, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

proc readValue*(
    r: var TomlReader, value: var MixNodePubInfo
) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(MixNodePubInfo, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

proc readValue*(
    r: var EnvvarReader, value: var MixNodePubInfo
) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(MixNodePubInfo, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

proc readValue*(
    r: var TomlReader, value: var ProtectedShard
) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(ProtectedShard, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

proc readValue*(
    r: var EnvvarReader, value: var ProtectedShard
) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(ProtectedShard, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

proc readValue*(
    r: var TomlReader, value: var EthRpcUrl
) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(EthRpcUrl, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

proc readValue*(
    r: var EnvvarReader, value: var EthRpcUrl
) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(EthRpcUrl, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

proc readValue*[T](
    r: var TomlReader, value: var Opt[T]
) {.gcsafe, raises: [SerializationError, IOError].} =
  mixin readValue
  value = Opt.some(r.readValue(T))

proc load*(T: type WakuNodeConf, version = ""): ConfResult[T] =
  try:
    var conf = WakuNodeConf.load(
      version = version,
      secondarySources = proc(
          conf: WakuNodeConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        sources.addConfigFile(Envvar, InputFile(NodeEnvvarPrefix))

        if conf.configFile.isSome():
          sources.addConfigFile(Toml, conf.configFile.get())
      ,
    )
    applyModeFlags(conf, DefaultKernelModeFlags)

    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())

proc defaultKernelConf*(modeFlags = DefaultKernelModeFlags): ConfResult[WakuNodeConf] =
  ## The kernel config with its defaults. With `modeFlags = ModeProtocolFlags()`,
  ## the protocol flags stay unset, so that a mode can set them first.
  try:
    var conf = WakuNodeConf.load(version = "", cmdLine = @[])
    applyModeFlags(conf, modeFlags)
    return ok(conf)
  except CatchableError:
    return err("exception in defaultKernelConf: " & getCurrentExceptionMsg())

proc parseCmdArg*(T: type LogosDeliveryMode, s: string): T {.raises: [ValueError].} =
  ## The generic `Opt[T]` flag parser dispatches to `parseCmdArg(T, ...)` for
  ## the inner type, so `Opt[LogosDeliveryMode]` needs this overload (bare enum
  ## fields parse through confutils' internal enum support instead).
  case s.strip().toLowerAscii()
  of "edge":
    LogosDeliveryMode.Edge
  of "core":
    LogosDeliveryMode.Core
  else:
    raise
      newException(ValueError, "Invalid mode: '" & s & "' (expected 'Edge' or 'Core')")

proc completeCmdArg*(T: type LogosDeliveryMode, val: string): seq[string] =
  return @[]

type LogosDeliveryNodeConf* = object
  ## LogosDeliveryNodeConf is the kernel configuration with two additional
  ## fields and the Messaging API flags.
  ##
  ## `entryLayer` lets logosdeliverynode users specify the layer-mount height,
  ## which is never guessed from given CLI parameters.
  ##
  ## `mode` is a messaging-only option. The kernel layer has no mode: its
  ## entire configuration must be given explicitly and it has its own
  ## per-config-option defaults which add up to what you'd expect for
  ## fleet-node use.
  ##
  ## `messaging` holds the Messaging API flags. They need the `messaging` or
  ## `channels` entry layer.
  entryLayer* {.
    desc:
      "Top API layer to run: kernel (transport only), messaging, or channels (messaging + reliable channels).",
    defaultValue: EntryLayer.kernel,
    name: "entry-layer"
  .}: EntryLayer

  mode* {.
    desc:
      "Node operating mode: Edge (client-only) or Core (full service node). Applies to --entry-layer=messaging|channels; rejected for --entry-layer=kernel. Default is Core.",
    defaultValue: Opt.none(LogosDeliveryMode),
    name: "mode"
  .}: Opt[LogosDeliveryMode]

  messaging* {.flatten.}: MessagingNodeConf

  kernel* {.flatten.}: WakuNodeConf

proc load*(T: type LogosDeliveryNodeConf, version = ""): ConfResult[T] =
  try:
    let conf = LogosDeliveryNodeConf.load(
      version = version,
      secondarySources = proc(
          conf: LogosDeliveryNodeConf, sources: auto
      ) {.gcsafe, raises: [ConfigurationError].} =
        sources.addConfigFile(Envvar, InputFile(NodeEnvvarPrefix))

        if conf.kernel.configFile.isSome():
          sources.addConfigFile(Toml, conf.kernel.configFile.get())
      ,
    )

    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())

proc defaultLogosDeliveryNodeConf*(): ConfResult[LogosDeliveryNodeConf] =
  try:
    let conf = LogosDeliveryNodeConf.load(version = "", cmdLine = @[])
    return ok(conf)
  except CatchableError:
    return err("exception in defaultLogosDeliveryNodeConf: " & getCurrentExceptionMsg())

proc toNetworkPresetConf*(
    preset: string, clusterId: Opt[uint16]
): ConfResult[Opt[NetworkPresetConf]] =
  var lcPreset = toLowerAscii(preset)
  if clusterId.isSome() and clusterId.get() == 1:
    warn(
      "TWN - The Waku Network configuration will not be applied when `--cluster-id=1` is passed in future releases. Use `--preset=twn` instead."
    )
    lcPreset = "twn"
  if clusterId.isSome() and clusterId.get() == 2:
    warn(
      "Logos.dev - Logos.dev configuration will not be applied when `--cluster-id=2` is passed in future releases. Use `--preset=logos.dev` instead."
    )
    lcPreset = "logos.dev"

  case lcPreset
  of "":
    ok(Opt.none(NetworkPresetConf))
  of "twn":
    ok(Opt.some(NetworkPresetConf.TheWakuNetworkConf()))
  of "logos.dev", "logosdev":
    ok(Opt.some(NetworkPresetConf.LogosDevConf()))
  of "logos.test", "logostest":
    ok(Opt.some(NetworkPresetConf.LogosTestConf()))
  of "status.prod", "statusprod":
    ok(Opt.some(NetworkPresetConf.StatusProdConf()))
  else:
    err("Invalid --preset value passed: " & lcPreset)

func ignoredFlagWarnings*(
    n: WakuNodeConf, defaults: WakuNodeConf, conf: WakuConf
): seq[string] =
  ## Flags that differ from `defaults` while the feature they configure is off
  ## in `conf`, the effective config (CLI, mode and preset applied).
  template changed(field: untyped): bool =
    n.field != defaults.field

  let
    store = conf.storeServiceConf.isSome()
    storeSync = store and conf.storeServiceConf.get().storeSyncConf.isSome()
    filter = conf.filterServiceConf.isSome()
    rest = conf.restServerConf.isSome()
    metrics = conf.metricsServerConf.isSome()
    discv5 = conf.discv5Conf.isSome()
    webSocket = conf.webSocketConf.isSome()
    webSocketSecure = webSocket and conf.webSocketConf.get().secureConf.isSome()
    quic = conf.quicConf.isSome()
    mix = conf.mixConf.isSome()
    kad = conf.kademliaDiscoveryConf.isSome() or conf.externalDiscoveryConf.isSome()
    kadParent = "enable-kad-discovery or --plugin-kad-discovery"
    rln = conf.rlnEvmConf.isSome()

  # (flag, parent flag, parent enabled, flag set)
  let dependentFlags = [
    (
      "store-message-retention-policy",
      "store",
      store,
      changed(storeMessageRetentionPolicy),
    ),
    ("store-message-db-url", "store", store, changed(storeMessageDbUrl)),
    ("store-message-db-vacuum", "store", store, changed(storeMessageDbVacuum)),
    ("store-message-db-migration", "store", store, changed(storeMessageDbMigration)),
    ("store-max-num-db-connections", "store", store, changed(storeMaxNumDbConnections)),
    ("store-resume", "store", store, changed(storeResume)),
    ("store-sync", "store", store, changed(storeSync)),
    ("store-sync-interval", "store-sync", storeSync, changed(storeSyncInterval)),
    ("store-sync-range", "store-sync", storeSync, changed(storeSyncRange)),
    ("store-sync-relay-jitter", "store-sync", storeSync, changed(storeSyncRelayJitter)),
    (
      "filter-subscription-timeout",
      "filter",
      filter,
      changed(filterSubscriptionTimeout),
    ),
    ("filter-max-peers-to-serve", "filter", filter, changed(filterMaxPeersToServe)),
    ("filter-max-criteria", "filter", filter, changed(filterMaxCriteria)),
    ("rest-address", "rest", rest, changed(restAddress)),
    ("rest-port", "rest", rest, changed(restPort)),
    ("rest-relay-cache-capacity", "rest", rest, changed(restRelayCacheCapacity)),
    ("rest-messaging-cache-capacity", "rest", rest, changed(restMessagingCacheCapacity)),
    ("rest-admin", "rest", rest, changed(restAdmin)),
    ("rest-allow-origin", "rest", rest, changed(restAllowOrigin)),
    ("metrics-server-address", "metrics-server", metrics, changed(metricsServerAddress)),
    ("metrics-server-port", "metrics-server", metrics, changed(metricsServerPort)),
    ("discv5-udp-port", "discv5-discovery", discv5, changed(discv5UdpPort)),
    ("discv5-bootstrap-node", "discv5-discovery", discv5, changed(discv5BootstrapNodes)),
    ("discv5-enr-auto-update", "discv5-discovery", discv5, changed(discv5EnrAutoUpdate)),
    ("discv5-table-ip-limit", "discv5-discovery", discv5, changed(discv5TableIpLimit)),
    ("discv5-bucket-ip-limit", "discv5-discovery", discv5, changed(discv5BucketIpLimit)),
    ("discv5-bits-per-hop", "discv5-discovery", discv5, changed(discv5BitsPerHop)),
    ("websocket-port", "websocket-support", webSocket, changed(websocketPort)),
    (
      "websocket-secure-support",
      "websocket-support",
      webSocket,
      changed(websocketSecureSupport),
    ),
    (
      "websocket-secure-key-path",
      "websocket-secure-support",
      webSocketSecure,
      changed(websocketSecureKeyPath),
    ),
    (
      "websocket-secure-cert-path",
      "websocket-secure-support",
      webSocketSecure,
      changed(websocketSecureCertPath),
    ),
    ("quic-port", "quic-support", quic, changed(quicPort)),
    ("mixkey", "mix", mix, changed(mixkey)),
    ("mixnode", "mix", mix, n.mixnodes.len > 0),
    ("kad-bootstrap-node", kadParent, kad, changed(kadBootstrapNodes)),
    ("kad-random-lookup-interval", kadParent, kad, changed(kadRandomLookupIntervalSec)),
    (
      "kad-service-lookup-interval",
      kadParent,
      kad,
      changed(kadServiceLookupIntervalSec),
    ),
    ("rln-relay-cred-path", "rln-relay", rln, changed(rlnRelayCredPath)),
    ("rln-relay-cred-password", "rln-relay", rln, changed(rlnRelayCredPassword)),
    (
      "rln-relay-eth-client-address",
      "rln-relay",
      rln,
      n.ethClientUrls.mapIt(string(it)) != defaults.ethClientUrls.mapIt(string(it)),
    ),
    (
      "rln-relay-eth-contract-address",
      "rln-relay",
      rln,
      changed(rlnRelayEthContractAddress),
    ),
    ("rln-relay-chain-id", "rln-relay", rln, changed(rlnRelayChainId)),
    (
      "rln-relay-user-message-limit",
      "rln-relay",
      rln,
      changed(rlnRelayUserMessageLimit),
    ),
    ("rln-relay-epoch-sec", "rln-relay", rln, changed(rlnEpochSizeSec)),
    ("rln-relay-membership-index", "rln-relay", rln, changed(rlnRelayCredIndex)),
  ]

  var warnings: seq[string]
  for (flag, parent, parentEnabled, isSet) in dependentFlags:
    if isSet and not parentEnabled:
      warnings.add("--" & flag & " is ignored: --" & parent & " is not enabled")
  return warnings

proc logConfigWarnings(n: WakuNodeConf, conf: WakuConf) =
  let defaults = defaultKernelConf(ModeProtocolFlags()).valueOr:
    return
  for msg in ignoredFlagWarnings(n, defaults, conf):
    warn "configuration flag ignored", detail = msg

proc toWakuConf*(n: WakuNodeConf): ConfResult[WakuConf] =
  var b = WakuConfBuilder.init()

  let networkPresetConf = toNetworkPresetConf(n.preset, n.clusterId).valueOr:
    return err("Error determining cluster from preset: " & $error)

  if networkPresetConf.isSome():
    b.withNetworkPresetConf(networkPresetConf.get())

  b.withLogLevel(n.logLevel)
  b.withLogFormat(n.logFormat)

  if n.rlnRelay.isSome():
    b.rlnRelayConf.withEnabled(n.rlnRelay.get())
  if n.rlnRelayCredPath != "":
    b.rlnRelayConf.withCredPath(n.rlnRelayCredPath)
  if n.rlnRelayCredPassword != "":
    b.rlnRelayConf.withCredPassword(n.rlnRelayCredPassword)
  if n.ethClientUrls.len > 0:
    b.rlnRelayConf.withEthClientUrls(n.ethClientUrls.mapIt(string(it)))
  if n.rlnRelayEthContractAddress != "":
    b.rlnRelayConf.withEthContractAddress(n.rlnRelayEthContractAddress)

  if n.rlnRelayChainId != 0:
    b.rlnRelayConf.withChainId(n.rlnRelayChainId)
  if n.rlnRelayUserMessageLimit.isSome():
    b.rlnRelayConf.withUserMessageLimit(n.rlnRelayUserMessageLimit.get())
  if n.rlnEpochSizeSec.isSome():
    b.rlnRelayConf.withEpochSizeSec(n.rlnEpochSizeSec.get())

  if n.rlnRelayCredIndex.isSome():
    b.rlnRelayConf.withCredIndex(n.rlnRelayCredIndex.get())
  if n.rlnRelayDynamic.isSome():
    b.rlnRelayConf.withDynamic(n.rlnRelayDynamic.get())
  if n.rlnDisableValidation:
    b.withRlnDisableValidation(n.rlnDisableValidation)

  if n.maxMessageSize != "":
    b.withMaxMessageSize(n.maxMessageSize)

  b.withProtectedShards(n.protectedShards)
  if n.clusterId.isSome():
    b.withClusterId(n.clusterId.get())

  b.withAgentString(n.agentString)

  if n.nodeKey.isSome():
    b.withNodeKey(n.nodeKey.get())

  b.withP2pListenAddress(n.listenAddress)
  b.withP2pTcpPort(n.tcpPort)
  b.withPortsShift(n.portsShift)
  ## Library code builds WakuNodeConf directly and zero means unset there.
  ## An explicit --nat-discovery-timeout-ms=0 selects the default.
  if n.nat.strip() != "":
    b.withNatStrategy(n.nat)
  if n.natDiscoveryTimeoutMs != 0:
    b.withNatDiscoveryTimeoutMs(n.natDiscoveryTimeoutMs)
  b.withExtMultiAddrs(n.extMultiAddrs)
  b.withExtMultiAddrsOnly(n.extMultiAddrsOnly)
  b.withMaxConnections(n.maxConnections)

  if n.relayServiceRatio != "":
    b.withRelayServiceRatio(n.relayServiceRatio)
  b.withColocationLimit(n.colocationLimit)
  if n.maxPureLibp2pPeers.isSome():
    b.withMaxPureLibp2pPeers(n.maxPureLibp2pPeers.get())
  elif networkPresetConf.isNone():
    b.withMaxPureLibp2pPeers(20)

  if n.peerStoreCapacity.isSome:
    b.withPeerStoreCapacity(n.peerStoreCapacity.get())

  b.withPeerPersistence(n.peerPersistence)
  b.withDnsAddrsNameServers(n.dnsAddrsNameServers)
  b.withDns4DomainName(n.dns4DomainName)
  b.withCircuitRelayClient(n.circuitRelayClient or n.isRelayClient)
  if n.relay.isSome():
    b.withRelay(n.relay.get())
  b.withRelayPeerExchange(n.relayPeerExchange)
  b.withRelayShardedPeerManagement(n.relayShardedPeerManagement)
  b.withStaticNodes(n.staticNodes)

  # Process entry nodes - supports enrtree:, enr:, and multiaddress formats
  if n.entryNodes.len > 0:
    let (enrTreeUrls, bootstrapEnrs, staticNodesFromEntry) = processEntryNodes(
      n.entryNodes
    ).valueOr:
      return err("Failed to process entry nodes: " & error)

    # Set ENRTree URLs for DNS discovery
    if enrTreeUrls.len > 0:
      for url in enrTreeUrls:
        b.dnsDiscoveryConf.withEnrTreeUrl(url)

    # Set ENR records as bootstrap nodes for discv5
    if bootstrapEnrs.len > 0:
      b.discv5Conf.withBootstrapNodes(bootstrapEnrs)

    # Add static nodes (multiaddrs and those extracted from ENR entries)
    if staticNodesFromEntry.len > 0:
      b.withStaticNodes(staticNodesFromEntry)

  if n.numShardsInNetwork != 0:
    b.withNumShardsInCluster(n.numShardsInNetwork)
    b.withShardingConf(AutoSharding)
  elif networkPresetConf.isNone():
    b.withShardingConf(StaticSharding)

  # It is not possible to pass an empty sequence on the CLI
  # If this is empty, it means the user did not specify any shards
  if n.shards.len != 0:
    b.withSubscribeShards(n.shards)

  b.withContentTopics(n.contentTopics)

  if n.store.isSome():
    b.storeServiceConf.withEnabled(n.store.get())
  b.storeServiceConf.withRetentionPolicies(n.storeMessageRetentionPolicy)
  b.storeServiceConf.withDbUrl(n.storeMessageDbUrl)
  b.storeServiceConf.withDbVacuum(n.storeMessageDbVacuum)
  b.storeServiceConf.withDbMigration(n.storeMessageDbMigration)
  b.storeServiceConf.withMaxNumDbConnections(n.storeMaxNumDbConnections)
  b.storeServiceConf.withResume(n.storeResume)

  # TODO: can we just use `Opt` on the CLI?
  if n.storenode != "":
    b.withRemoteStoreNode(n.storenode)
  if n.filternode != "":
    b.withRemoteFilterNode(n.filternode)
  if n.lightpushnode != "":
    b.withRemoteLightPushNode(n.lightpushnode)
  if n.peerExchangeNode != "":
    b.withRemotePeerExchangeNode(n.peerExchangeNode)

  b.storeServiceConf.storeSyncConf.withEnabled(n.storeSync)
  b.storeServiceConf.storeSyncConf.withIntervalSec(n.storeSyncInterval)
  b.storeServiceConf.storeSyncConf.withRangeSec(n.storeSyncRange)
  b.storeServiceConf.storeSyncConf.withRelayJitterSec(n.storeSyncRelayJitter)

  if n.mix.isSome():
    b.mixConf.withEnabled(n.mix.get())
    b.withMix(n.mix.get())
  if n.mixRlnRegistryId.len > 0:
    if n.mixRlnMetadataTopic.len == 0:
      return err("Mix RLN coordination topic is required")
    b.mixConf.withMixRln(
      ModuleRlnConfig(
        registryId: n.mixRlnRegistryId,
        rlnIdentifierHex: n.mixRlnIdentifierHex,
        epochSeconds: uint64(EpochDurationSeconds),
        maxEpochGap: uint64(MaxEpochGap),
        metadataTopic: n.mixRlnMetadataTopic,
      )
    )
  b.mixConf.withMixNodes(n.mixnodes)
  if n.mixkey.isSome():
    b.mixConf.withMixKey(n.mixkey.get())

  if n.filter.isSome():
    b.filterServiceConf.withEnabled(n.filter.get())
  b.filterServiceConf.withSubscriptionTimeout(n.filterSubscriptionTimeout)
  b.filterServiceConf.withMaxPeersToServe(n.filterMaxPeersToServe)
  b.filterServiceConf.withMaxCriteria(n.filterMaxCriteria)

  if n.lightpush.isSome():
    b.withLightPush(n.lightpush.get())

  b.restServerConf.withEnabled(n.rest)
  b.restServerConf.withListenAddress(n.restAddress)
  b.restServerConf.withPort(n.restPort)
  b.restServerConf.withRelayCacheCapacity(n.restRelayCacheCapacity)
  b.restServerConf.withMessagingCacheCapacity(n.restMessagingCacheCapacity)
  b.restServerConf.withAdmin(n.restAdmin)
  b.restServerConf.withAllowOrigin(n.restAllowOrigin)

  b.metricsServerConf.withEnabled(n.metricsServer)
  b.metricsServerConf.withHttpAddress(n.metricsServerAddress)
  b.metricsServerConf.withHttpPort(n.metricsServerPort)
  b.metricsServerConf.withLogging(n.metricsLogging)

  if n.dnsDiscoveryUrl != "":
    b.dnsDiscoveryConf.withEnrTreeUrl(n.dnsDiscoveryUrl)

  if n.discv5Discovery.isSome():
    b.discv5Conf.withEnabled(n.discv5Discovery.get())

  b.discv5Conf.withUdpPort(n.discv5UdpPort)
  b.discv5Conf.withBootstrapNodes(n.discv5BootstrapNodes)
  b.discv5Conf.withEnrAutoUpdate(n.discv5EnrAutoUpdate)
  b.discv5Conf.withTableIpLimit(n.discv5TableIpLimit)
  b.discv5Conf.withBucketIpLimit(n.discv5BucketIpLimit)
  b.discv5Conf.withBitsPerHop(n.discv5BitsPerHop)

  if n.peerExchange.isSome():
    b.withPeerExchange(n.peerExchange.get())

  if n.rendezvous.isSome():
    b.withRendezvous(n.rendezvous.get())

  b.webSocketConf.withEnabled(n.websocketSupport)
  b.webSocketConf.withWebSocketPort(n.websocketPort)
  b.webSocketConf.withSecureEnabled(n.websocketSecureSupport)
  b.webSocketConf.withKeyPath(n.websocketSecureKeyPath)
  b.webSocketConf.withCertPath(n.websocketSecureCertPath)

  b.quicConf.withEnabled(n.quicSupport)
  if n.quicPort.isSome():
    b.quicConf.withQuicPort(n.quicPort.get())

  if n.rateLimits.len > 0:
    b.rateLimitConf.withRateLimits(n.rateLimits)

  b.withLocalStoragePath(n.localStoragePath)

  if n.enableKadDiscovery.isSome():
    b.kademliaDiscoveryConf.withEnabled(n.enableKadDiscovery.get())
  b.kademliaDiscoveryConf.withBootstrapNodes(n.kadBootstrapNodes)

  if n.kadRandomLookupIntervalSec > 0:
    b.kademliaDiscoveryConf.withRandomLookupInterval(
      chronos.seconds(n.kadRandomLookupIntervalSec.int64)
    )
  if n.kadServiceLookupIntervalSec > 0:
    b.kademliaDiscoveryConf.withServiceLookupInterval(
      chronos.seconds(n.kadServiceLookupIntervalSec.int64)
    )

  if n.pluginKadDiscovery.isSome():
    b.externalDiscoveryConf.withEnabled(n.pluginKadDiscovery.get())
  ## One pair of interval knobs for both hosts of the same protocol.
  if n.kadRandomLookupIntervalSec > 0:
    b.externalDiscoveryConf.withRandomLookupInterval(
      chronos.seconds(n.kadRandomLookupIntervalSec.int64)
    )
  if n.kadServiceLookupIntervalSec > 0:
    b.externalDiscoveryConf.withServiceLookupInterval(
      chronos.seconds(n.kadServiceLookupIntervalSec.int64)
    )

  let conf = ?b.build()
  logConfigWarnings(n, conf)
  return ok(conf)
