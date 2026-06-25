# chat2disco is a minimal chat app for testing Waku Kademlia service discovery.
# /room <name> subscribes to the pubsub topic of that name and starts

when not (compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

{.push raises: [].}

import std/[strformat, strutils, times, options, sequtils]
import
  confutils,
  chronicles,
  chronos,
  eth/keys,
  bearssl,
  results,
  stew/[byteutils],
  metrics,
  metrics/chronos_httpserver
import
  libp2p/[
    switch,
    crypto/crypto,
    stream/connection,
    multiaddress,
    peerinfo,
    peerid,
    protobuf/minprotobuf,
    protocols/kademlia/types,
    protocols/service_discovery,
    protocols/service_discovery/types as sd_types,
  ]
import
  logos_delivery/waku/[
    waku_core,
    waku_enr,
    discovery/waku_kademlia,
    waku_node,
    node/waku_metrics,
    node/peer_manager,
    factory/builder,
    factory/conf_builder/kademlia_discovery_conf_builder,
    common/utils/nat,
    common/logging,
    discovery/autonat_service,
  ],
  ./config_chat2disco

import logos_delivery/waku/events/discovery_events

import libp2p/protocols/pubsub/rpc/messages, libp2p/protocols/pubsub/pubsub
import libp2p/extended_peer_record # for ServiceInfo

logScope:
  topics = "chat2disco"

const Help = """
  Commands: /[?|help|connect|nick|room|exit]
  help: Prints this help
  connect: dials a remote peer
  nick: change nickname for current chat session
  room <name>: subscribe to pubsub topic <name> and advertise + discover the kademlia service of the same name (kademlia always active)
  exit: exits chat session
"""

const DefaultContentTopic = "/chat2disco/1/room/proto"

type Chat = ref object
  node: WakuNode
  transp: StreamTransport
  subscribed: bool
  connected: bool
  started: bool
  nick: string
  prompt: bool
  currentPubsubTopic: string
  discoPeersListener: PeersDiscoveredEventListener

type
  PrivateKey* = crypto.PrivateKey
  Topic* = waku_core.PubsubTopic

#####################
## chat2 protobufs ##
#####################

type
  SelectResult*[T] = Result[T, string]

  Chat2Message* = object
    timestamp*: int64
    nick*: string
    payload*: seq[byte]

proc init*(T: type Chat2Message, buffer: seq[byte]): ProtoResult[T] =
  var msg = Chat2Message()
  let pb = initProtoBuffer(buffer)

  var timestamp: uint64
  discard ?pb.getField(1, timestamp)
  msg.timestamp = int64(timestamp)

  discard ?pb.getField(2, msg.nick)
  discard ?pb.getField(3, msg.payload)

  ok(msg)

proc encode*(message: Chat2Message): ProtoBuffer =
  var serialised = initProtoBuffer()

  serialised.write(1, uint64(message.timestamp))
  serialised.write(2, message.nick)
  serialised.write(3, message.payload)

  return serialised

proc `$`*(message: Chat2Message): string =
  let time = message.timestamp.fromUnix().local().format("'<'MMM' 'dd,' 'HH:mm'>'")
  return time & " " & message.nick & ": " & string.fromBytes(message.payload)

#####################

proc connectToNodes(c: Chat, nodes: seq[string]) {.async.} =
  echo "Connecting to nodes"
  await c.node.connectToNodes(nodes)
  c.connected = true

proc showChatPrompt(c: Chat) =
  if not c.prompt:
    try:
      stdout.write(">> ")
      stdout.flushFile()
      c.prompt = true
    except IOError:
      discard

proc getChatLine(payload: seq[byte]): string =
  let pb = Chat2Message.init(payload).valueOr:
    return string.fromBytes(payload)
  return $pb

proc printReceivedMessage(c: Chat, pubsubTopic: PubsubTopic, msg: WakuMessage) =
  let chatLine = getChatLine(msg.payload)
  try:
    echo &"[{pubsubTopic}] {chatLine}"
  except ValueError:
    echo chatLine
  c.prompt = false
  showChatPrompt(c)
  trace "Printing message", chatLine, pubsubTopic, contentTopic = msg.contentTopic

proc readNick(transp: StreamTransport): Future[string] {.async.} =
  stdout.write("Choose a nickname >> ")
  stdout.flushFile()
  return await transp.readLine()

proc readRoom(transp: StreamTransport): Future[string] {.async.} =
  stdout.write("Choose a room >> ")
  stdout.flushFile()
  return await transp.readLine()

proc startMetricsServer(
    serverIp: IpAddress, serverPort: Port
): Result[MetricsHttpServerRef, string] =
  info "Starting metrics HTTP server", serverIp = $serverIp, serverPort = $serverPort

  let server = MetricsHttpServerRef.new($serverIp, serverPort).valueOr:
    return err("metrics HTTP server start failed: " & $error)

  try:
    waitFor server.start()
  except CatchableError:
    return err("metrics HTTP server start failed: " & getCurrentExceptionMsg())

  info "Metrics HTTP server started", serverIp = $serverIp, serverPort = $serverPort
  ok(server)

proc publish(c: Chat, line: string) {.async.} =
  if c.currentPubsubTopic.len == 0:
    echo "No active room. Use /room <name> to join one first."
    return

  let time = getTime().toUnix()
  let chat2pb =
    Chat2Message(timestamp: time, nick: c.nick, payload: line.toBytes()).encode()

  var message = WakuMessage(
    payload: chat2pb.buffer,
    contentTopic: DefaultContentTopic,
    version: 0,
    timestamp: getNanosecondTime(time),
  )

  try:
    (await c.node.publish(some(c.currentPubsubTopic), message)).isOkOr:
      error "failed to publish message", error = error
  except CatchableError:
    error "caught error publishing message: ", error = getCurrentExceptionMsg()

proc joinRoom(c: Chat, roomName: string) {.async.} =
  if c.currentPubsubTopic.len > 0 and c.currentPubsubTopic != roomName:
    discard c.node.unsubscribe((kind: PubsubSub, topic: c.currentPubsubTopic))
    if not c.node.wakuKademlia.isNil():
      c.node.wakuKademlia.removeServiceToDiscover(c.currentPubsubTopic)
      await c.node.wakuKademlia.removeServiceToAdvertise(
        ServiceInfo(id: c.currentPubsubTopic, data: @[])
      )

  c.currentPubsubTopic = roomName

  proc roomHandler(
      pubsubTopic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    c.printReceivedMessage(pubsubTopic, msg)

  c.node.subscribe((kind: PubsubSub, topic: roomName), WakuRelayHandler(roomHandler)).isOkOr:
    error "failed to subscribe to pubsub topic for room",
      topic = roomName, error = error

  echo "subscribed to pubsub topic: ", roomName

  if not c.node.wakuKademlia.isNil():
    let svcInfo = ServiceInfo(id: roomName, data: @[])
    c.node.wakuKademlia.addServiceToDiscover(roomName)
    c.node.wakuKademlia.addServiceToAdvertise(svcInfo)
    echo "advertising and discovering kademlia service: ", roomName

proc readAndPrint(c: Chat) {.async.} =
  while true:
    await sleepAsync(100.millis)

proc writeAndPrint(c: Chat) {.async.} =
  while true:
    showChatPrompt(c)

    let line = await c.transp.readLine()
    if line.startsWith("/help") or line.startsWith("/?") or not c.started:
      echo Help
      continue
    elif line.startsWith("/connect"):
      if c.connected:
        echo "already connected to at least one peer"
        continue
      echo "enter address of remote peer"
      let address = await c.transp.readLine()
      if address.len > 0:
        await c.connectToNodes(@[address])
    elif line.startsWith("/nick"):
      c.nick = await readNick(c.transp)
      echo "You are now known as " & c.nick
    elif line.startsWith("/room"):
      let parts = line.split(maxsplit = 1)
      if parts.len < 2 or parts[1].strip().len == 0:
        echo "usage: /room <name>"
        continue
      let roomName = parts[1].strip()
      await c.joinRoom(roomName)
    elif line.startsWith("/exit"):
      await PeersDiscoveredEvent.dropListener(c.discoPeersListener)
      echo "quitting..."

      try:
        await c.node.stop()
      except:
        echo "exception happened when stopping: " & getCurrentExceptionMsg()

      quit(QuitSuccess)
    else:
      if c.started:
        if c.currentPubsubTopic.len > 0:
          echo "publishing message to ", c.currentPubsubTopic, ": ", line
          await c.publish(line)
        else:
          echo "Join a room first with /room <name> before sending messages"
      else:
        try:
          if line.startsWith("/") and "p2p" in line:
            await c.connectToNodes(@[line])
        except:
          echo &"unable to dial remote peer {line}"
          echo getCurrentExceptionMsg()

proc readWriteLoop(c: Chat) {.async.} =
  asyncSpawn c.writeAndPrint()
  asyncSpawn c.readAndPrint()

proc readInput(wfd: AsyncFD) {.thread, raises: [Defect, CatchableError].} =
  let transp = fromPipe(wfd)

  while true:
    let line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

{.pop.}
  # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
proc processInput(rfd: AsyncFD, rng: crypto.Rng) {.async.} =
  let
    transp = fromPipe(rfd)
    conf = Chat2Conf.load()
    nodekey =
      if conf.nodekey.isSome():
        conf.nodekey.get()
      else:
        PrivateKey.random(Secp256k1, rng).tryGet()

  # set log level
  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  let (extIp, extTcpPort, extUdpPort) = setupNat(
    conf.nat,
    clientId,
    Port(uint16(conf.tcpPort) + conf.portsShift),
    Port(uint16(conf.udpPort) + conf.portsShift),
  ).valueOr:
    raise newException(ValueError, "setupNat error " & error)

  var enrBuilder = EnrBuilder.init(nodeKey)

  let record = enrBuilder.build().valueOr:
    error "failed to create enr record", error = error
    quit(QuitFailure)

  let node = block:
    var builder = WakuNodeBuilder.init()
    builder.withNodeKey(nodeKey)
    builder.withRecord(record)

    builder
      .withNetworkConfigurationDetails(
        conf.listenAddress,
        Port(uint16(conf.tcpPort) + conf.portsShift),
        extIp,
        extTcpPort,
      )
      .tryGet()
    builder.build().tryGet()

  (await node.mountRelay()).isOkOr:
    error "failed to mount relay: ", error = error
    quit(QuitFailure)

  await node.mountLibp2pPing()

  var kadBootstrapPeers: seq[(PeerId, seq[MultiAddress])]
  for nodeStr in conf.kadBootstrapNodes:
    let (peerId, ma) = block:
      let r = parseFullAddress(nodeStr)
      if r.isErr:
        error "Failed to parse kademlia bootstrap node", node = nodeStr, error = r.error
        continue
      r.get()
    kadBootstrapPeers.add((peerId, @[ma]))

  node.mountKademlia(
    KademliaDiscoveryConf(
      bootstrapNodes: kadBootstrapPeers,
      randomLookupInterval: chronos.seconds(60),
      serviceLookupInterval: chronos.seconds(60),
      kadDhtConfig: KadDHTConfig.new(),
      discoConfig:
        sd_types.ServiceDiscoveryConfig.new(advertExpiry = chronos.seconds(60)),
      clientMode: false,
      xprPublishing: false,
    )
  ).isOkOr:
    error "failed to setup kademlia service discovery", error = error
    quit(QuitFailure)

  let autonatService = getAutonatService(rng)
  node.switch.services = @[Service(autonatService)]
  for service in node.switch.services:
    try:
      service.setup(node.switch)
    except ServiceSetupError as e:
      error "failed to set up libp2p switch service", error = e.msg

  await node.start()

  node.peerManager.start()

  let nick = await readNick(transp)
  let room = await readRoom(transp)
  echo "Welcome, " & nick & "! Joined room '" & room & "'."

  var chat = Chat(
    node: node,
    transp: transp,
    subscribed: false,
    connected: false,
    started: true,
    nick: nick,
    prompt: false,
    currentPubsubTopic: "",
    discoPeersListener: PeersDiscoveredEventListener(),
  )

  let listenerHandle = PeersDiscoveredEvent.listen(
    proc(event: PeersDiscoveredEvent) {.async: (raises: []).} =
      let peers = event.peers
      if peers.len > 0:
        try:
          echo "discovered peers via kademlia: ", peers.mapIt($it.peerId)
          await chat.node.connectToNodes(peers)
          chat.connected = true
        except CatchableError as e:
          error "error connecting discovered peers", error = e.msg
  ).valueOr:
    error "failed to subscribe to PeersDiscoveredEvent", error = error
    return

  chat.discoPeersListener = listenerHandle

  let peerInfo = node.switch.peerInfo
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & $peerInfo.peerId
  echo &"Listening on\n {listenStr}"

  if conf.metricsLogging:
    startMetricsLog()

  if conf.metricsServer:
    let metricsServer = startMetricsServer(
      conf.metricsServerAddress, Port(conf.metricsServerPort + conf.portsShift)
    )

  await chat.joinRoom(room)

  await chat.readWriteLoop()

  runForever()

proc main(rng: crypto.Rng) {.async.} =
  let (rfd, wfd) = createAsyncPipe()
  if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
    raise newException(ValueError, "Could not initialize pipe!")

  var thread: Thread[AsyncFD]
  thread.createThread(readInput, wfd)
  try:
    await processInput(rfd, rng)
  except ConfigurationError as e:
    raise e

when isMainModule:
  let rng = crypto.newRng()
  try:
    waitFor(main(rng))
  except CatchableError as e:
    raise e
