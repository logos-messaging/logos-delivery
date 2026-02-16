import chronicles, chronos, std/strutils, regex

import
  eth/keys,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/crypto/curve25519,
  libp2p/multiaddress,
  libp2p/multicodec,
  nimcrypto/utils,
  confutils,
  confutils/defs,
  confutils/std/net

import waku/waku_core, waku/waku_mix

type
  Fleet* = enum
    none
    sandbox
    test

  EthRpcUrl* = distinct string

  Chat2Conf* = object ## General node config
    edgemode* {.
      defaultValue: true, desc: "Run the app in edge mode", name: "edge-mode"
    .}: bool

    logLevel* {.
      desc: "Sets the log level.", defaultValue: LogLevel.INFO, name: "log-level"
    .}: LogLevel

    nodekey* {.desc: "P2P node private key as 64 char hex string.", name: "nodekey".}:
      Option[crypto.PrivateKey]

    listenAddress* {.
      defaultValue: defaultListenAddress(config),
      desc: "Listening address for the LibP2P traffic.",
      name: "listen-address"
    .}: IpAddress

    tcpPort* {.desc: "TCP listening port.", defaultValue: 60000, name: "tcp-port".}:
      Port

    udpPort* {.desc: "UDP listening port.", defaultValue: 60000, name: "udp-port".}:
      Port

    portsShift* {.
      desc: "Add a shift to all port numbers.", defaultValue: 0, name: "ports-shift"
    .}: uint16

    nat* {.
      desc:
        "Specify method to use for determining public address. " &
        "Must be one of: any, none, upnp, pmp, extip:<IP>.",
      defaultValue: "any"
    .}: string

    ## Persistence config
    dbPath* {.
      desc: "The database path for peristent storage", defaultValue: "", name: "db-path"
    .}: string

    persistPeers* {.
      desc: "Enable peer persistence: true|false",
      defaultValue: false,
      name: "persist-peers"
    .}: bool

    persistMessages* {.
      desc: "Enable message persistence: true|false",
      defaultValue: false,
      name: "persist-messages"
    .}: bool

    ## Relay config
    relay* {.
      desc: "Enable relay protocol: true|false", defaultValue: true, name: "relay"
    .}: bool

    staticnodes* {.
      desc: "Peer multiaddr to directly connect with. Argument may be repeated.",
      name: "staticnode",
      defaultValue: @[]
    .}: seq[string]

    mixnodes* {.
      desc:
        "Multiaddress and mix-key of mix node to be statically specified in format multiaddr:mixPubKey. Argument may be repeated.",
      name: "mixnode"
    .}: seq[MixNodePubInfo]

    keepAlive* {.
      desc: "Enable keep-alive for idle connections: true|false",
      defaultValue: false,
      name: "keep-alive"
    .}: bool

    clusterId* {.
      desc:
        "Cluster id that the node is running in. Node in a different cluster id is disconnected.",
      defaultValue: 1,
      name: "cluster-id"
    .}: uint16

    numShardsInNetwork* {.
      desc: "Number of shards in the network",
      defaultValue: 8,
      name: "num-shards-in-network"
    .}: uint32

    shards* {.
      desc:
        "Shards index to subscribe to [0..NUM_SHARDS_IN_NETWORK-1]. Argument may be repeated.",
      defaultValue:
        @[
          uint16(0),
          uint16(1),
          uint16(2),
          uint16(3),
          uint16(4),
          uint16(5),
          uint16(6),
          uint16(7),
        ],
      name: "shard"
    .}: seq[uint16]

    ## Store config
    store* {.
      desc: "Enable store protocol: true|false", defaultValue: false, name: "store"
    .}: bool

    storenode* {.
      desc: "Peer multiaddr to query for storage.", defaultValue: "", name: "storenode"
    .}: string

    ## Filter config
    filter* {.
      desc: "Enable filter protocol: true|false", defaultValue: false, name: "filter"
    .}: bool

    ## Lightpush config
    lightpush* {.
      desc: "Enable lightpush protocol: true|false",
      defaultValue: false,
      name: "lightpush"
    .}: bool

    servicenode* {.
      desc: "Peer multiaddr to request lightpush and filter services",
      defaultValue: "",
      name: "servicenode"
    .}: string

    ## Metrics config
    metricsServer* {.
      desc: "Enable the metrics server: true|false",
      defaultValue: false,
      name: "metrics-server"
    .}: bool

    metricsServerAddress* {.
      desc: "Listening address of the metrics server.",
      defaultValue: parseIpAddress("127.0.0.1"),
      name: "metrics-server-address"
    .}: IpAddress

    metricsServerPort* {.
      desc: "Listening HTTP port of the metrics server.",
      defaultValue: 8008,
      name: "metrics-server-port"
    .}: uint16

    metricsLogging* {.
      desc: "Enable metrics logging: true|false",
      defaultValue: true,
      name: "metrics-logging"
    .}: bool

    ## DNS discovery config
    dnsDiscovery* {.
      desc:
        "Deprecated, please set dns-discovery-url instead. Enable discovering nodes via DNS",
      defaultValue: false,
      name: "dns-discovery"
    .}: bool

    dnsDiscoveryUrl* {.
      desc: "URL for DNS node list in format 'enrtree://<key>@<fqdn>'",
      defaultValue: "",
      name: "dns-discovery-url"
    .}: string

    dnsDiscoveryNameServers* {.
      desc: "DNS name server IPs to query. Argument may be repeated.",
      defaultValue: @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")],
      name: "dns-discovery-name-server"
    .}: seq[IpAddress]

    ## Chat2 configuration
    fleet* {.
      desc:
        "Select the fleet to connect to. This sets the DNS discovery URL to the selected fleet.",
      defaultValue: Fleet.none,
      name: "fleet"
    .}: Fleet

    contentTopic* {.
      desc: "Content topic for chat messages.",
      defaultValue: "/toy-chat/2/baixa-chiado/proto",
      name: "content-topic"
    .}: string

    ## Websocket Configuration
    websocketSupport* {.
      desc: "Enable websocket:  true|false",
      defaultValue: false,
      name: "websocket-support"
    .}: bool

    websocketPort* {.
      desc: "WebSocket listening port.", defaultValue: 8000, name: "websocket-port"
    .}: Port

    websocketSecureSupport* {.
      desc: "WebSocket Secure Support.",
      defaultValue: false,
      name: "websocket-secure-support"
    .}: bool

    ## Kademlia Discovery config
    kadBootstrapNodes* {.
      desc:
        "Peer multiaddr for kademlia discovery bootstrap node (must include /p2p/<peerID>). Argument may be repeated.",
      name: "kad-bootstrap-node"
    .}: seq[string]

    ## RLN spam protection config
    rlnUserMessageLimit* {.
      desc: "Maximum messages per epoch for RLN spam protection.",
      defaultValue: 100,
      name: "rln-user-message-limit"
    .}: int

proc parseCmdArg*(T: type MixNodePubInfo, p: string): T =
  let elements = p.split(":")
  if elements.len != 2:
    raise newException(
      ValueError, "Invalid format for mix node expected multiaddr:mixPublicKey"
    )
  let multiaddr = MultiAddress.init(elements[0]).valueOr:
    raise newException(ValueError, "Invalid multiaddress format")
  if not multiaddr.contains(multiCodec("ip4")).get():
    raise newException(
      ValueError, "Invalid format for ip address, expected a ipv4 multiaddress"
    )

  return MixNodePubInfo(
    multiaddr: elements[0], pubKey: intoCurve25519Key(ncrutils.fromHex(elements[1]))
  )

# NOTE: Keys are different in nim-libp2p
proc parseCmdArg*(T: type crypto.PrivateKey, p: string): T =
  try:
    let key = SkPrivateKey.init(utils.fromHex(p)).tryGet()
    # XXX: Here at the moment
    result = crypto.PrivateKey(scheme: Secp256k1, skkey: key)
  except CatchableError as e:
    raise newException(ValueError, "Invalid private key")

proc completeCmdArg*(T: type crypto.PrivateKey, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type IpAddress, p: string): T =
  try:
    result = parseIpAddress(p)
  except CatchableError as e:
    raise newException(ValueError, "Invalid IP address")

proc completeCmdArg*(T: type IpAddress, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type Port, p: string): T =
  try:
    result = Port(parseInt(p))
  except CatchableError as e:
    raise newException(ValueError, "Invalid Port number")

proc completeCmdArg*(T: type Port, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type Option[uint], p: string): T =
  try:
    some(parseUint(p))
  except CatchableError:
    raise newException(ValueError, "Invalid unsigned integer")

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
  ## disallowed patterns:
  ## any valid/invalid ws or wss url
  var httpPattern =
    re2"^(https?):\/\/((localhost)|([\w_-]+(?:(?:\.[\w_-]+)+)))(:[0-9]{1,5})?([\w.,@?^=%&:\/~+#-]*[\w@?^=%&\/~+#-])*"
  var wsPattern =
    re2"^(wss?):\/\/((localhost)|([\w_-]+(?:(?:\.[\w_-]+)+)))(:[0-9]{1,5})?([\w.,@?^=%&:\/~+#-]*[\w@?^=%&\/~+#-])*"
  if regex.match(s, wsPattern):
    raise newException(
      ValueError, "Websocket RPC URL is not supported, Please use an HTTP URL"
    )
  if not regex.match(s, httpPattern):
    raise newException(ValueError, "Invalid HTTP RPC URL")
  return EthRpcUrl(s)

func defaultListenAddress*(conf: Chat2Conf): IpAddress =
  # TODO: How should we select between IPv4 and IPv6
  # Maybe there should be a config option for this.
  (static parseIpAddress("0.0.0.0"))
