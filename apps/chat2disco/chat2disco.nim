## chat2disco is an example of usage of Waku v2 with Kademlia service discovery.
## Users create named chat rooms; the app derives a service ID from the room name,
## advertises via Kademlia, and discovers/connects to other peers with the same service.

when not (compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

{.push raises: [].}

import std/[strformat, strutils, times, options, random, sequtils, tables]
import
  confutils,
  chronicles,
  chronos,
  eth/keys,
  bearssl,
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
    nameresolving/dnsresolver,
    extended_peer_record,
  ]
import
  waku/[
    waku_core,
    waku_enr,
    discovery/waku_dnsdisc,
    discovery/waku_kademlia,
    waku_node,
    node/waku_metrics,
    node/peer_manager,
    factory/builder,
    common/utils/nat,
    waku_relay,
    waku_store/common,
  ],
  ./config_chat2disco

import libp2p/protocols/pubsub/rpc/messages, libp2p/protocols/pubsub/pubsub
import libp2p/protocols/service_discovery/types

logScope:
  topics = "chat2disco"

const Help = """
  Commands: /[?|help|create|rooms|switch|nick|exit]
  help: Prints this help
  create <room>: Create/join a chat room via service discovery
  rooms: List joined rooms
  switch <room>: Switch active room for sending messages
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

# TODO This should read or be subscribe handler subscribe
proc readAndPrint(c: Chat) {.async.} =
  while true:
    await sleepAsync(100.millis)

# TODO Implement
proc writeAndPrint(c: Chat) {.async.} =
  while true:
    showChatPrompt(c)

    let line = await c.transp.readLine()
    if line.startsWith("/help") or line.startsWith("/?") or not c.started:
      echo Help
      continue
    elif line.startsWith("/create"):
      let roomName = line[7 ..^ 1].strip()
      if roomName.len == 0:
        echo "Usage: /create <room-name>"
        continue

      if roomName in c.rooms:
        echo &"Already in room '{roomName}'. Use /switch {roomName} to make it active."
        continue

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
    elif line.startsWith("/rooms"):
      if c.rooms.len == 0:
        echo "No rooms joined yet. Use /create <room-name> to create one."
      else:
        echo "Joined rooms:"
        for name, room in c.rooms:
          let marker = if name == c.currentRoom: " *" else: ""
          echo &"  {name} ({room.discovered.len} peers){marker}"
    elif line.startsWith("/switch"):
      let roomName = line[7 ..^ 1].strip()
      if roomName.len == 0:
        echo "Usage: /switch <room-name>"
        continue

      if roomName notin c.rooms:
        echo &"Room '{roomName}' not found. Use /create {roomName} to create it."
        continue

      c.currentRoom = roomName
      echo &"Switched to room '{roomName}'"
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
          echo "No room active. Use /create <room-name> first."
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
  asyncSpawn c.readAndPrint()

proc readInput(wfd: AsyncFD) {.thread, raises: [Defect, CatchableError].} =
  let transp = fromPipe(wfd)

  while true:
    let line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

{.pop.}
proc processInput(rfd: AsyncFD, rng: ref HmacDrbgContext) {.async.} =
  let
    transp = fromPipe(rfd)
    conf = Chat2DiscoConf.load()
    nodekey =
      if conf.nodekey.isSome():
        conf.nodekey.get()
      else:
        PrivateKey.random(Secp256k1, rng[]).tryGet()

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
        wsBindPort = Port(uint16(conf.websocketPort) + conf.portsShift),
        wsEnabled = conf.websocketSupport,
        wssEnabled = conf.websocketSecureSupport,
      )
      .tryGet()
    builder.build().tryGet()

  if conf.relay:
    (await node.mountRelay()).isOkOr:
      echo "failed to mount relay: " & error
      return

  await node.mountLibp2pPing()

  # Setup kademlia discovery if bootstrap nodes are provided
  var providedServices: seq[ServiceInfo] = @[]

  if conf.kadBootstrapNodes.len > 0:
    var kadBootstrapPeers: seq[(PeerId, seq[MultiAddress])]
    for nodeStr in conf.kadBootstrapNodes:
      let (peerId, ma) = parseFullAddress(nodeStr).valueOr:
        error "Failed to parse kademlia bootstrap node", node = nodeStr, error = error
        continue
      kadBootstrapPeers.add((peerId, @[ma]))

    if kadBootstrapPeers.len > 0:
      node.wakuKademlia = WakuKademlia.new(
        node.switch, node.peerManager, kadBootstrapPeers, providedServices
      )
  else:
    # Create as seed node (no bootstrap) so we can still advertise services
    node.wakuKademlia =
      WakuKademlia.new(node.switch, node.peerManager, @[], providedServices)

  await node.start()

  if not node.wakuKademlia.isNil():
    node.wakuKademlia.start()

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

  if conf.staticnodes.len > 0:
    echo "Connecting to static peers..."
    await node.connectToNodes(conf.staticnodes)

  var dnsDiscoveryUrl = none(string)

  if conf.fleet != Fleet.none:
    echo "Connecting to " & $conf.fleet & " fleet using DNS discovery..."

    if conf.fleet == Fleet.test:
      dnsDiscoveryUrl = some(
        "enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im"
      )
    else:
      dnsDiscoveryUrl = some(
        "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
      )
  elif conf.dnsDiscoveryUrl != "":
    info "Discovering nodes using Waku DNS discovery", url = conf.dnsDiscoveryUrl
    dnsDiscoveryUrl = some(conf.dnsDiscoveryUrl)

  var discoveredNodes: seq[RemotePeerInfo]

  if dnsDiscoveryUrl.isSome:
    var nameServers: seq[TransportAddress]
    for ip in conf.dnsAddrsNameServers:
      nameServers.add(initTAddress(ip, Port(53)))

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain = domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0]

    let wakuDnsDiscovery = WakuDnsDiscovery.init(dnsDiscoveryUrl.get(), resolver)
    if wakuDnsDiscovery.isOk:
      let discoveredPeers = await wakuDnsDiscovery.get().findPeers()
      if discoveredPeers.isOk:
        info "Connecting to discovered peers"
        discoveredNodes = discoveredPeers.get()
        echo "Discovered and connecting to " & $discoveredNodes
        waitFor chat.node.connectToNodes(discoveredNodes)
      else:
        warn "Failed to find peers via DNS discovery", error = discoveredPeers.error
    else:
      warn "Failed to init Waku DNS discovery", error = wakuDnsDiscovery.error

  let peerInfo = node.switch.peerInfo
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & $peerInfo.peerId
  echo &"Listening on\n {listenStr}"

  if (conf.storenode != "") or (conf.store == true):
    await node.mountStore()

    var storenode: Option[RemotePeerInfo]

    if conf.storenode != "":
      let peerInfo = parsePeerInfo(conf.storenode)
      if peerInfo.isOk():
        storenode = some(peerInfo.value)
      else:
        error "Incorrect conf.storenode", error = peerInfo.error
    elif discoveredNodes.len > 0:
      echo "Store enabled, but no store nodes configured. Choosing one at random from discovered peers"
      storenode = some(discoveredNodes[rand(0 .. len(discoveredNodes) - 1)])

    if storenode.isSome():
      echo "Connecting to storenode: " & $(storenode.get())

      node.mountStoreClient()
      node.peerManager.addServicePeer(storenode.get(), WakuStoreCodec)

  # Subscribe to relay topic
  if conf.relay:
    proc handler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
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
          break

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

proc main(rng: ref HmacDrbgContext) {.async.} =
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
