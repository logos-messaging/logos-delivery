import
  chronicles,
  chronos,
  confutils,
  confutils/defs,
  confutils/std/net,
  eth/keys,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  nimcrypto/utils,
  std/strutils
import waku/waku_core

const
  defaultMetricsAddress* = parseIpAddress("127.0.0.1")
  defaultDnsResolver1* = parseIpAddress("1.1.1.1")
  defaultDnsResolver2* = parseIpAddress("1.0.0.1")

type
  Fleet* = enum
    none
    prod
    test

  Chat2DiscoConf* = object ## General node config
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

    ## Relay config
    relay* {.
      desc: "Enable relay protocol: true|false", defaultValue: true, name: "relay"
    .}: bool

    staticnodes* {.
      desc: "Peer multiaddr to directly connect with. Argument may be repeated.",
      name: "staticnode"
    .}: seq[string]

    keepAlive* {.
      desc: "Enable keep-alive for idle connections: true|false",
      defaultValue: false,
      name: "keep-alive"
    .}: bool

    clusterId* {.
      desc:
        "Cluster id that the node is running in. Node in a different cluster id is disconnected.",
      defaultValue: 0,
      name: "cluster-id"
    .}: uint16

    shards* {.
      desc:
        "Shards index to subscribe to [0..NUM_SHARDS_IN_NETWORK-1]. Argument may be repeated.",
      defaultValue: @[uint16(0)],
      name: "shard"
    .}: seq[uint16]

    ## Store config
    store* {.
      desc: "Enable store protocol: true|false", defaultValue: true, name: "store"
    .}: bool

    storenode* {.
      desc: "Peer multiaddr to query for storage.", defaultValue: "", name: "storenode"
    .}: string

    ## Metrics config
    metricsServer* {.
      desc: "Enable the metrics server: true|false",
      defaultValue: false,
      name: "metrics-server"
    .}: bool

    metricsServerAddress* {.
      desc: "Listening address of the metrics server.",
      defaultValue: defaultMetricsAddress,
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
    dnsDiscoveryUrl* {.
      desc: "URL for DNS node list in format 'enrtree://<key>@<fqdn>'",
      defaultValue: "",
      name: "dns-discovery-url"
    .}: string

    dnsAddrsNameServers* {.
      desc:
        "DNS name server IPs to query for DNS multiaddrs resolution. Argument may be repeated.",
      defaultValue: @[defaultDnsResolver1, defaultDnsResolver2],
      name: "dns-addrs-name-server"
    .}: seq[IpAddress]

    ## Chat2 configuration
    fleet* {.
      desc:
        "Select the fleet to connect to. This sets the DNS discovery URL to the selected fleet.",
      defaultValue: Fleet.prod,
      name: "fleet"
    .}: Fleet

    contentTopic* {.
      desc: "Content topic for chat messages.",
      defaultValue: "/chat2disco/1/default/proto",
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

# NOTE: Keys are different in nim-libp2p
proc parseCmdArg*(T: type crypto.PrivateKey, p: string): T =
  try:
    let key = SkPrivateKey.init(utils.fromHex(p)).tryGet()
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

func defaultListenAddress*(conf: Chat2DiscoConf): IpAddress =
  (static parseIpAddress("0.0.0.0"))
