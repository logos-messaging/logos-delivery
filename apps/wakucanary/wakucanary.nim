import
  std/[strutils, sequtils, tables, strformat],
  confutils,
  chronos,
  chronicles/topics_registry,
  os
import
  libp2p/protocols/ping,
  libp2p/crypto/[crypto, secp],
  libp2p/nameresolving/dnsresolver,
  libp2p/multicodec
import
  ./certsgenerator,
  waku/[waku_enr, node/peer_manager, waku_core, waku_node, factory/builder]

# protocols and their tag
const ProtocolsTable = {
  "store": "/vac/waku/store/",
  "storev3": "/vac/waku/store-query/3",
  "relay": "/vac/waku/relay/",
  "lightpush": "/vac/waku/lightpush/",
  "filter": "/vac/waku/filter-subscribe/2",
  "filter-push": "/vac/waku/filter-push/",
  "ipfs-id": "/ipfs/id/",
  "autonat": "/libp2p/autonat/",
  "circuit-relay": "/libp2p/circuit/relay/",
  "metadata": "/vac/waku/metadata/",
  "rendezvous": "/rendezvous/",
  "ipfs-ping": "/ipfs/ping/",
  "peer-exchange": "/vac/waku/peer-exchange/",
  "mix": "mix/1.0.0",
}.toTable

const WebSocketPortOffset = 1000
const CertsDirectory = "./certs"

# cli flags
type WakuCanaryConf* = object
  address* {.
    desc: "Multiaddress of the peer node to attempt to dial",
    defaultValue: "",
    name: "address",
    abbr: "a"
  .}: string

  timeout* {.
    desc: "Timeout to consider that the connection failed",
    defaultValue: chronos.seconds(10),
    name: "timeout",
    abbr: "t"
  .}: chronos.Duration

  protocols* {.
    desc:
      "Protocol required to be supported: store,relay,lightpush,filter (can be used multiple times)",
    name: "protocol",
    abbr: "p"
  .}: seq[string]

  logLevel* {.
    desc: "Sets the log level",
    defaultValue: LogLevel.INFO,
    name: "log-level",
    abbr: "l"
  .}: LogLevel

  nodePort* {.
    desc: "Listening port for waku node",
    defaultValue: 60000,
    name: "node-port",
    abbr: "np"
  .}: uint16

  ## websocket secure config
  websocketSecureKeyPath* {.
    desc: "Secure websocket key path:   '/path/to/key.txt' ",
    defaultValue: "",
    name: "websocket-secure-key-path"
  .}: string

  websocketSecureCertPath* {.
    desc: "Secure websocket Certificate path:   '/path/to/cert.txt' ",
    defaultValue: "",
    name: "websocket-secure-cert-path"
  .}: string

  ping* {.
    desc: "Ping the peer node to measure latency", defaultValue: true, name: "ping"
  .}: bool

  shards* {.
    desc:
      "Shards index to subscribe to [0..NUM_SHARDS_IN_NETWORK-1]. Argument may be repeated.",
    defaultValue: @[],
    name: "shard",
    abbr: "s"
  .}: seq[uint16]

  clusterId* {.
    desc:
      "Cluster id that the node is running in. Node in a different cluster id is disconnected.",
    defaultValue: 1,
    name: "cluster-id",
    abbr: "c"
  .}: uint16

proc parseCmdArg*(T: type chronos.Duration, p: string): T =
  try:
    result = chronos.seconds(parseInt(p))
  except CatchableError:
    raise newException(ValueError, "Invalid timeout value")

proc completeCmdArg*(T: type chronos.Duration, val: string): seq[string] =
  return @[]

proc areProtocolsSupported(
    toValidateProtocols: seq[string], nodeProtocols: seq[string]
): bool =
  ## Checks if all toValidateProtocols are contained in nodeProtocols.
  ## nodeProtocols contains the full list of protocols currently informed by the node under analysis.
  ## toValidateProtocols contains the protocols, without version number, that we want to check if they are supported by the node.
  var numOfSupportedProt: int = 0

  for rawProtocol in toValidateProtocols:
    let protocolTag = ProtocolsTable[rawProtocol]
    info "Checking if protocol is supported", expected_protocol_tag = protocolTag

    var protocolSupported = false
    for nodeProtocol in nodeProtocols:
      if nodeProtocol.startsWith(protocolTag):
        info "The node supports the protocol", supported_protocol = nodeProtocol
        numOfSupportedProt += 1
        protocolSupported = true
        break

    if not protocolSupported:
      error "The node does not support the protocol", expected_protocol = protocolTag

  if numOfSupportedProt == toValidateProtocols.len:
    return true

  return false

proc pingNode(
    node: WakuNode, peerInfo: RemotePeerInfo
): Future[bool] {.async, gcsafe.} =
  try:
    let conn = await node.switch.dial(peerInfo.peerId, peerInfo.addrs, PingCodec)
    let pingDelay = await node.libp2pPing.ping(conn)
    info "Peer response time (ms)", peerId = peerInfo.peerId, ping = pingDelay.millis
    return true
  except CatchableError:
    var msg = getCurrentExceptionMsg()
    if msg == "Future operation cancelled!":
      msg = "timedout"
    error "Failed to ping the peer", peer = peerInfo, err = msg
    return false

proc main(rng: ref HmacDrbgContext): Future[int] {.async.} =
  let conf: WakuCanaryConf = WakuCanaryConf.load()

  # create dns resolver
  let
    nameServers = @[
      initTAddress(parseIpAddress("1.1.1.1"), Port(53)),
      initTAddress(parseIpAddress("1.0.0.1"), Port(53)),
    ]
    resolver: DnsResolver = DnsResolver.new(nameServers)

  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  # ensure input protocols are valid
  for p in conf.protocols:
    if p notin ProtocolsTable:
      error "invalid protocol", protocol = p, valid = ProtocolsTable
      raise newException(ConfigurationError, "Invalid cli flag values" & p)

  info "Cli flags",
    address = conf.address,
    timeout = conf.timeout,
    protocols = conf.protocols,
    logLevel = conf.logLevel

  let peer = parsePeerInfo(conf.address).valueOr:
    error "Couldn't parse 'conf.address'", error = error
    quit(QuitFailure)

  let
    nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
    bindIp = parseIpAddress("0.0.0.0")
    wsBindPort = Port(conf.nodePort + WebSocketPortOffset)
    nodeTcpPort = Port(conf.nodePort)
    isWs = peer.addrs[0].contains(multiCodec("ws")).get()
    isWss = peer.addrs[0].contains(multiCodec("wss")).get()
    keyPath =
      if conf.websocketSecureKeyPath.len > 0:
        conf.websocketSecureKeyPath
      else:
        CertsDirectory & "/key.pem"
    certPath =
      if conf.websocketSecureCertPath.len > 0:
        conf.websocketSecureCertPath
      else:
        CertsDirectory & "/cert.pem"

  var builder = WakuNodeBuilder.init()
  builder.withNodeKey(nodeKey)

  let netConfig = NetConfig.init(
    bindIp = bindIp,
    bindPort = nodeTcpPort,
    wsBindPort = some(wsBindPort),
    wsEnabled = isWs,
    wssEnabled = isWss,
  )

  var enrBuilder = EnrBuilder.init(nodeKey)

  enrBuilder.withWakuRelaySharding(
    RelayShards(clusterId: conf.clusterId, shardIds: conf.shards)
  ).isOkOr:
    error "could not initialize ENR with shards", error
    quit(QuitFailure)

  let record = enrBuilder.build().valueOr:
    error "failed to create enr record", error = error
    quit(QuitFailure)

  if isWss and
      (conf.websocketSecureKeyPath.len == 0 or conf.websocketSecureCertPath.len == 0):
    info "WebSocket Secure requires key and certificate. Generating them"
    if not dirExists(CertsDirectory):
      createDir(CertsDirectory)
    if generateSelfSignedCertificate(certPath, keyPath) != 0:
      error "Error generating key and certificate"
      quit(QuitFailure)

  builder.withRecord(record)
  builder.withNetworkConfiguration(netConfig.tryGet())
  builder.withSwitchConfiguration(
    secureKey = some(keyPath), secureCert = some(certPath), nameResolver = resolver
  )

  let node = builder.build().tryGet()

  if conf.ping:
    try:
      await mountLibp2pPing(node)
    except CatchableError:
      error "failed to mount libp2p ping protocol: " & getCurrentExceptionMsg()
      quit(QuitFailure)

  node.mountMetadata(conf.clusterId, conf.shards).isOkOr:
    error "failed to mount metadata protocol", error
    quit(QuitFailure)

  await node.start()

  var pingFut: Future[bool]
  if conf.ping:
    pingFut = pingNode(node, peer).withTimeout(conf.timeout)

  let timedOut = not await node.connectToNodes(@[peer]).withTimeout(conf.timeout)
  if timedOut:
    error "Timedout after", timeout = conf.timeout
    quit(QuitFailure)

  let lp2pPeerStore = node.switch.peerStore
  let conStatus = node.peerManager.switch.peerStore[ConnectionBook][peer.peerId]

  var pingSuccess = true
  if conf.ping:
    try:
      pingSuccess = await pingFut
    except CatchableError as exc:
      pingSuccess = false
      error "Ping operation failed or timed out", error = exc.msg

  if not pingSuccess:
    error "Ping to the node failed", peerId = peer.peerId, conStatus = $conStatus
    quit(QuitFailure)

  if conStatus in [Connected, CanConnect]:
    let nodeProtocols = lp2pPeerStore[ProtoBook][peer.peerId]

    if not areProtocolsSupported(conf.protocols, nodeProtocols):
      error "Not all protocols are supported",
        expected = conf.protocols, supported = nodeProtocols
      quit(QuitFailure)
  elif conStatus == CannotConnect:
    error "Could not connect", peerId = peer.peerId
    quit(QuitFailure)
  return 0

when isMainModule:
  let rng = crypto.newRng()
  let status = waitFor main(rng)
  if status == 0:
    info "The node is reachable and supports all specified protocols"
  else:
    error "The node has some problems (see logs)"
  quit status
