## chat2disco is an example of usage of Waku v2 with Kademlia service discovery.
## Users create named chat rooms; the app derives a service ID from the room name,
## advertises via Kademlia, and discovers/connects to other peers with the same service.

when not (compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

{.push raises: [].}

import std/[strformat, strutils, times, options, sequtils, tables]
import
  confutils,
  chronicles,
  chronos,
  eth/keys,
  stew/byteutils,
  results,
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
    extended_peer_record,
    nameresolving/dnsresolver,
    protocols/connectivity/relay/client,
    services/autorelayservice,
    services/hpservice,
  ]
import
  waku/[
    waku_core,
    waku_enr,
    discovery/waku_kademlia,
    discovery/autonat_service,
    waku_node,
    node/waku_metrics,
    node/peer_manager,
    factory/builder,
    common/utils/nat,
    waku_relay,
  ],
  ./config_chat2disco

import libp2p/protocols/pubsub/rpc/messages, libp2p/protocols/pubsub/pubsub
import libp2p/protocols/service_discovery/types

logScope:
  topics = "chat2disco"

const Help = """
  Commands: /[?|help|room|rooms|nick|exit]
  help: Prints this help
  room <room>: Create, join, or switch to a chat room
  rooms: List joined rooms
  nick: change nickname
  exit: exits chat session
"""

type
  ChatRoom = object
    serviceId*: string
    contentTopic*: string
    discovered*: seq[RemotePeerInfo]

  Chat = ref object
    node: WakuNode
    transp: StreamTransport
    subscribed: bool
    started: bool
    nick: string
    prompt: bool
    rooms: Table[string, ChatRoom]
    currentRoom: string

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

proc toString*(message: Chat2Message): string =
  let time = message.timestamp.fromUnix().local().format("'<'MMM' 'dd,' 'HH:mm'>'")
  return time & " " & message.nick & ": " & string.fromBytes(message.payload)

#####################

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

proc readNick(transp: StreamTransport): Future[string] {.async.} =
  stdout.write("Choose a nickname >> ")
  stdout.flushFile()
  return await transp.readLine()

proc readRoom(transp: StreamTransport): Future[string] {.async.} =
  stdout.write("Choose or create a room >> ")
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

proc publish(c: Chat, line: string) =
  let time = getTime().toUnix()
  let chat2pb =
    Chat2Message(timestamp: time, nick: c.nick, payload: line.toBytes()).encode()

  let room =
    try:
      c.rooms[c.currentRoom]
    except KeyError:
      error "current room not found in rooms table", room = c.currentRoom
      return

  var message = WakuMessage(
    payload: chat2pb.buffer,
    contentTopic: room.contentTopic,
    version: 0,
    timestamp: getNanosecondTime(time),
  )

  try:
    (waitFor c.node.publish(some(DefaultPubsubTopic), message)).isOkOr:
      error "failed to publish message", error = error
  except CatchableError:
    error "caught error publishing message: ", error = getCurrentExceptionMsg()

proc createRoom(c: Chat, roomName: string) {.async.} =
  let serviceIdStr = "/waku/chat-room/" & roomName & "/1.0.0"
  let contentTopic = "/chat2disco/1/" & roomName & "/proto"

  let serviceInfo = ServiceInfo(id: serviceIdStr, data: @[])

  if not c.node.wakuKademlia.isNil():
    c.node.wakuKademlia.advertiseService(serviceInfo)
    echo &"Advertising service: {serviceIdStr}"

    let peers = await c.node.wakuKademlia.lookup(serviceIdStr)
    echo &"Discovered {peers.len} peer(s) for room '{roomName}'"

    if peers.len > 0:
      await c.node.connectToNodes(peers)
      echo "Connected to discovered peers"

    c.rooms[roomName] = ChatRoom(
      serviceId: serviceIdStr, contentTopic: contentTopic, discovered: peers
    )
  else:
    echo "Warning: Kademlia not available. Room created locally only."
    c.rooms[roomName] =
      ChatRoom(serviceId: serviceIdStr, contentTopic: contentTopic, discovered: @[])

  c.currentRoom = roomName
  echo &"Created/joined room '{roomName}'. Content topic: {contentTopic}"

# TODO Implement
proc writeAndPrint(c: Chat) {.async.} =
  while true:
    showChatPrompt(c)

    let line = await c.transp.readLine()
    if line.startsWith("/help") or line.startsWith("/?") or not c.started:
      echo Help
      continue
    elif line.startsWith("/room"):
      let roomName = line[5 ..^ 1].strip()
      if roomName.len == 0:
        echo "Usage: /room <room-name>"
        continue

      if roomName in c.rooms:
        c.currentRoom = roomName
        echo &"Switched to room '{roomName}'"
      else:
        await c.createRoom(roomName)
    elif line.startsWith("/rooms"):
      if c.rooms.len == 0:
        echo "No rooms joined yet. Use /room <room-name> to create one."
      else:
        echo "Joined rooms:"
        for name, room in c.rooms:
          let marker = if name == c.currentRoom: " *" else: ""
          echo &"  {name} ({room.discovered.len} peers){marker}"
    elif line.startsWith("/nick"):
      c.nick = await readNick(c.transp)
      echo "You are now known as " & c.nick
    elif line.startsWith("/exit"):
      echo "quitting..."

      try:
        await c.node.stop()
      except:
        echo "exception happened when stopping: " & getCurrentExceptionMsg()

      quit(QuitSuccess)
    else:
      if c.started:
        if c.rooms.len == 0:
          echo "No room active. Use /room <room-name> first."
        else:
          c.publish(line)
      else:
        try:
          if line.startsWith("/") and "p2p" in line:
            await c.node.connectToNodes(@[line])
        except:
          echo &"unable to dial remote peer {line}"
          echo getCurrentExceptionMsg()

proc readWriteLoop(c: Chat) {.async.} =
  asyncSpawn c.writeAndPrint()

proc readInput(wfd: AsyncFD) {.thread, raises: [Defect, CatchableError].} =
  let transp = fromPipe(wfd)

  while true:
    let line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

{.pop.}
proc processInput(rfd: AsyncFD, rng: crypto.Rng) {.async.} =
  let
    transp = fromPipe(rfd)
    conf = Chat2DiscoConf.load()
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
    error "failed to create enr record", error
    quit(QuitFailure)

  let circuitRelay = RelayClient.new()

  let node = block:
    var builder = WakuNodeBuilder.init()
    builder.withNodeKey(nodeKey)
    builder.withRecord(record)

    let netConf = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = Port(uint16(conf.tcpPort) + conf.portsShift),
      extIp = extIp,
      extPort = extTcpPort,
      dnsNameServers = @[parseIpAddress("1.1.1.1"), parseIpAddress("1.0.0.1")],
    ).valueOR:
      error "invalid network configuration", error
      quit(QuitFailure)

    let nameResolver =
      DnsResolver.new(netConf.dnsNameServers.mapIt(initTAddress(it, Port(53))))

    builder.withNetworkConfiguration(netConf)
    builder.withSwitchConfiguration(nameResolver = nameResolver)
    builder.withCircuitRelay(circuitRelay)
    builder.build().tryGet()

  proc onReservation(addresses: seq[MultiAddress]) {.gcsafe, raises: [].} =
    info "circuit relay handler new reserve event",
      addrs_before = $(node.announcedAddresses), addrs = $addresses

    node.announcedAddresses.setLen(0) ## remove previous addresses
    node.announcedAddresses.add(addresses)

    info "chat2disco node announced addresses updated",
      announcedAddresses = node.announcedAddresses

  let
    autonatService = getAutonatService(rng)
    autoRelayService = AutoRelayService.new(2, circuitRelay, onReservation, rng)
    holePunchService = HPService.new(autonatService, autoRelayService)

  node.switch.services = @[Service(holePunchService)]

  if conf.relay:
    (await node.mountRelay()).isOkOr:
      error "failed to mount relay", error
      quit(QuitFailure)

  await node.mountLibp2pPing()

  var kadBootstrapPeers: seq[(PeerId, seq[MultiAddress])] = @[]
  if conf.kadBootstrapNodes.len > 0:
    for nodeStr in conf.kadBootstrapNodes:
      let (peerId, ma) = parseFullAddress(nodeStr).valueOr:
        error "Failed to parse kademlia bootstrap node", node = nodeStr, error = error
        continue
      kadBootstrapPeers.add((peerId, @[ma]))

  node.wakuKademlia = WakuKademlia.new(
    switch = node.switch,
    peerManager = node.peerManager,
    bootstrapNodes = kadBootstrapPeers,
    xprPublishing = false,
    disableBootstrapping = true,
  )

  let catchRes = catch:
    node.switch.mount(node.wakuKademlia.protocol)

  if catchRes.isErr():
    error "failed to mount kademlia discovery", error = catchRes.error.msg
    quit(QuitFailure)

  # node start include kademlia
  await node.start()

  let nick = await readNick(transp)
  echo "Welcome, " & nick & "!"

  var chat = Chat(
    node: node,
    transp: transp,
    subscribed: true,
    started: true,
    nick: nick,
    prompt: false,
  )

  let roomName = await readRoom(transp)
  if roomName.len > 0:
    await chat.createRoom(roomName)

  let peerInfo = node.switch.peerInfo
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & $peerInfo.peerId
  echo &"Listening on\n {listenStr}"

  # Subscribe to relay topic
  if conf.relay:
    proc handler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
      var matched = false
      for roomName, room in chat.rooms:
        if msg.contentTopic == room.contentTopic:
          let chatLine = getChatLine(msg.payload)
          let prefix =
            if chat.rooms.len > 1:
              "[" & roomName & "] "
            else:
              ""
          try:
            echo &"{prefix}{chatLine}"
          except ValueError:
            echo prefix & chatLine
          chat.prompt = false
          showChatPrompt(chat)
          matched = true
          break
      if not matched:
        let chatLine = getChatLine(msg.payload)
        try:
          echo &"[unknown] {chatLine}"
        except ValueError:
          echo "[unknown] " & chatLine
        chat.prompt = false
        showChatPrompt(chat)

    node.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), WakuRelayHandler(handler)
    ).isOkOr:
      error "failed to subscribe to pubsub topic",
        topic = DefaultPubsubTopic, error = error

  if conf.metricsLogging:
    startMetricsLog()

  if conf.metricsServer:
    let metricsServer = startMetricsServer(
      conf.metricsServerAddress, Port(conf.metricsServerPort + conf.portsShift)
    )

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
