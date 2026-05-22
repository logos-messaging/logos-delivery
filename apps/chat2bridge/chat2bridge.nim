{.push raises: [].}

import
  std/[tables, times, strutils, hashes, sequtils, json],
  chronos,
  confutils,
  chronicles,
  chronicles/topics_registry,
  chronos/streams/tlsstream,
  metrics,
  metrics/chronos_httpserver,
  stew/byteutils,
  eth/net/nat,
  # Matterbridge client imports
  # Waku v2 imports
  libp2p/crypto/crypto,
  libp2p/errors,
  waku/[
    waku_core,
    waku_node,
    node/peer_manager,
    waku_filter_v2,
    waku_store,
    factory/builder,
    common/utils/matterbridge_client,
    common/rate_limit/setting,
  ],
  # Chat 2 imports
  ../chat2/chat2,
  # Common cli config
  ./config_chat2bridge

declarePublicCounter chat2_mb_transfers,
  "Number of messages transferred between chat2 and Matterbridge", ["type"]
declarePublicCounter chat2_mb_dropped, "Number of messages dropped", ["reason"]

logScope:
  topics = "chat2bridge"

##################
# Default values #
##################

const DeduplQSize = 20 # Maximum number of seen messages to keep in deduplication queue

#########
# Types #
#########

type
  Chat2MatterBridge* = ref object of RootObj
    mbClient*: MatterbridgeClient
    nodev2*: WakuNode
    running: bool
    pollPeriod: chronos.Duration
    seen: seq[Hash] #FIFO queue
    contentTopic: string

  MbMessageHandler = proc(jsonNode: JsonNode) {.async.}

###################
# Helper functions #
###################S

proc containsOrAdd(sequence: var seq[Hash], hash: Hash): bool =
  if sequence.contains(hash):
    return true

  if sequence.len >= DeduplQSize:
    trace "Deduplication queue full. Removing oldest item."
    sequence.delete 0, 0 # Remove first item in queue

  sequence.add(hash)

  return false

proc toWakuMessage(
    cmb: Chat2MatterBridge, jsonNode: JsonNode
): WakuMessage {.raises: [Defect, KeyError].} =
  # Translates a Matterbridge API JSON response to a Waku v2 message
  let msgFields = jsonNode.getFields()

  # @TODO error handling here - verify expected fields

  let chat2pb = Chat2Message(
    timestamp: getTime().toUnix(), # @TODO use provided timestamp
    nick: msgFields["username"].getStr(),
    payload: msgFields["text"].getStr().toBytes(),
  ).encode()

  WakuMessage(payload: chat2pb.buffer, contentTopic: cmb.contentTopic, version: 0)

proc toChat2(cmb: Chat2MatterBridge, jsonNode: JsonNode) {.async.} =
  let msg = cmb.toWakuMessage(jsonNode)

  if cmb.seen.containsOrAdd(msg.payload.hash()):
    # This is a duplicate message. Return.
    chat2_mb_dropped.inc(labelValues = ["duplicate"])
    return

  trace "Post Matterbridge message to chat2"

  chat2_mb_transfers.inc(labelValues = ["mb_to_chat2"])

  (await cmb.nodev2.publish(some(DefaultPubsubTopic), msg)).isOkOr:
    error "failed to publish message", error = error

proc toMatterbridge(
    cmb: Chat2MatterBridge, msg: WakuMessage
) {.gcsafe, raises: [Exception].} =
  if cmb.seen.containsOrAdd(msg.payload.hash()):
    # This is a duplicate message. Return.
    chat2_mb_dropped.inc(labelValues = ["duplicate"])
    return

  if msg.contentTopic != cmb.contentTopic:
    # Only bridge messages on the configured content topic
    chat2_mb_dropped.inc(labelValues = ["filtered"])
    return

  trace "Post chat2 message to Matterbridge"

  chat2_mb_transfers.inc(labelValues = ["chat2_to_mb"])

  let chat2Msg = Chat2Message.init(msg.payload)

  assert chat2Msg.isOk

  if not cmb.mbClient
    .postMessage(
      text = string.fromBytes(chat2Msg[].payload), username = chat2Msg[].nick
    )
    .containsValue(true):
    chat2_mb_dropped.inc(labelValues = ["duplicate"])
    error "Matterbridge host unreachable. Dropping message."

proc pollMatterbridge(cmb: Chat2MatterBridge, handler: MbMessageHandler) {.async.} =
  while cmb.running:
    let msg = cmb.mbClient.getMessages().valueOr:
      error "Matterbridge host unreachable. Sleeping before retrying."
      await sleepAsync(chronos.seconds(10))
      continue
    for jsonNode in msg:
      await handler(jsonNode)
    await sleepAsync(cmb.pollPeriod)

##############
# Public API #
##############
proc new*(
    T: type Chat2MatterBridge,
    # Matterbridge initialisation
    mbHostUri: string,
    mbGateway: string,
    # NodeV2 initialisation
    nodev2Key: crypto.PrivateKey,
    nodev2BindIp: IpAddress,
    nodev2BindPort: Port,
    nodev2ExtIp = none[IpAddress](),
    nodev2ExtPort = none[Port](),
    contentTopic: string,
): T {.
    raises: [Defect, ValueError, KeyError, TLSStreamProtocolError, IOError, LPError]
.} =
  # Setup Matterbridge
  let mbClient = MatterbridgeClient.new(mbHostUri, mbGateway)

  # Let's verify the Matterbridge configuration before continuing
  if mbClient.isHealthy().valueOr(false):
    info "Reached Matterbridge host", host = mbClient.host
  else:
    raise newException(ValueError, "Matterbridge client not reachable/healthy")

  # Setup Waku v2 node
  let nodev2 = block:
    var builder = WakuNodeBuilder.init()
    builder.withNodeKey(nodev2Key)

    builder
      .withNetworkConfigurationDetails(
        nodev2BindIp, nodev2BindPort, nodev2ExtIp, nodev2ExtPort
      )
      .tryGet()
    builder.build().tryGet()

  return Chat2MatterBridge(
    mbClient: mbClient,
    nodev2: nodev2,
    running: false,
    pollPeriod: chronos.seconds(1),
    contentTopic: contentTopic,
  )

proc start*(cmb: Chat2MatterBridge) {.async.} =
  info "Starting Chat2MatterBridge"

  cmb.running = true

  info "Start polling Matterbridge"

  # Start Matterbridge polling (@TODO: use streaming interface)
  proc mbHandler(jsonNode: JsonNode) {.async.} =
    trace "Bridging message from Matterbridge to chat2", jsonNode = jsonNode
    waitFor cmb.toChat2(jsonNode)

  asyncSpawn cmb.pollMatterbridge(mbHandler)

  # Start Waku v2 node
  info "Start listening on Waku v2"
  await cmb.nodev2.start()

  # Always mount relay for bridge
  # `triggerSelf` is false on a `bridge` to avoid duplicates
  (await cmb.nodev2.mountRelay()).isOkOr:
    error "failed to mount relay", error = error
    return

  cmb.nodev2.wakuRelay.triggerSelf = false

  # Bridging
  # Handle messages on Waku v2 and bridge to Matterbridge
  proc relayHandler(
      pubsubTopic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async.} =
    trace "Bridging message from Chat2 to Matterbridge", msg = msg
    try:
      cmb.toMatterbridge(msg)
    except:
      error "exception in relayHandler: " & getCurrentExceptionMsg()

  cmb.nodev2.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), relayHandler).isOkOr:
    error "failed to subscribe to relay", topic = DefaultPubsubTopic, error = error
    return

proc stop*(cmb: Chat2MatterBridge) {.async: (raises: [Exception]).} =
  info "Stopping Chat2MatterBridge"

  cmb.running = false

  await cmb.nodev2.stop()

{.pop.}
  # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  import waku/common/utils/nat, waku/rest_api/message_cache

  let
    rng = newRng()
    conf = Chat2MatterbridgeConf.load()

  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  let (nodev2ExtIp, nodev2ExtPort, _) = setupNat(
    conf.nat,
    clientId,
    Port(uint16(conf.libp2pTcpPort) + conf.portsShift),
    Port(uint16(conf.udpPort) + conf.portsShift),
  ).valueOr:
    raise newException(ValueError, "setupNat error " & error)

  ## The following heuristic assumes that, in absence of manual
  ## config, the external port is the same as the bind port.
  let extPort =
    if nodev2ExtIp.isSome() and nodev2ExtPort.isNone():
      some(Port(uint16(conf.libp2pTcpPort) + conf.portsShift))
    else:
      nodev2ExtPort

  let bridge = Chat2Matterbridge.new(
    mbHostUri = "http://" & $initTAddress(conf.mbHostAddress, Port(conf.mbHostPort)),
    mbGateway = conf.mbGateway,
    nodev2Key = conf.nodekey,
    nodev2BindIp = conf.listenAddress,
    nodev2BindPort = Port(uint16(conf.libp2pTcpPort) + conf.portsShift),
    nodev2ExtIp = nodev2ExtIp,
    nodev2ExtPort = extPort,
    contentTopic = conf.contentTopic,
  )

  waitFor bridge.start()

  # Now load rest of config
  # Mount configured Waku v2 protocols
  waitFor mountLibp2pPing(bridge.nodev2)

  if conf.store:
    waitFor mountStore(bridge.nodev2)

  if conf.filter:
    waitFor mountFilter(bridge.nodev2)

  if conf.staticnodes.len > 0:
    waitFor connectToNodes(bridge.nodev2, conf.staticnodes)

  if conf.storenode != "":
    let storePeer = parsePeerInfo(conf.storenode)
    if storePeer.isOk():
      bridge.nodev2.peerManager.addServicePeer(storePeer.value, WakuStoreCodec)
    else:
      error "Error parsing conf.storenode", error = storePeer.error

  if conf.filternode != "":
    let filterPeer = parsePeerInfo(conf.filternode)
    if filterPeer.isOk():
      bridge.nodev2.peerManager.addServicePeer(
        filterPeer.value, WakuFilterSubscribeCodec
      )
    else:
      error "Error parsing conf.filternode", error = filterPeer.error

  if conf.metricsServer:
    let
      address = conf.metricsServerAddress
      port = conf.metricsServerPort + conf.portsShift
    info "Starting metrics HTTP server", address, port
    startMetricsHttpServer($address, Port(port))

  runForever()
