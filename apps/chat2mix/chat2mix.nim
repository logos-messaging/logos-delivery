## chat2 is an example of usage of Waku v2. For suggested usage options, please
## see dingpu tutorial in docs folder.

when not (compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

{.push raises: [].}

import std/[strformat, strutils, times, options, random, sequtils]
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
    switch, # manage transports, a single entry point for dialing and listening
    crypto/crypto, # cryptographic functions
    stream/connection, # create and close stream read / write connections
    multiaddress,
      # encode different addressing schemes. For example, /ip4/7.7.7.7/tcp/6543 means it is using IPv4 protocol and TCP
    peerinfo,
      # manage the information of a peer, such as peer ID and public / private key
    peerid, # Implement how peers interact
    protobuf/minprotobuf, # message serialisation/deserialisation from and to protobufs
    nameresolving/dnsresolver,
    protocols/mix/curve25519,
    protocols/mix/mix_protocol,
  ] # define DNS resolution
import
  waku/[
    waku_core,
    waku_core/topics/sharding,
    waku_lightpush/common,
    waku_lightpush/rpc,
    waku_enr,
    discovery/waku_dnsdisc,
    discovery/waku_kademlia,
    waku_node,
    node/waku_metrics,
    node/peer_manager,
    factory/builder,
    common/utils/nat,
    waku_store/common,
    waku_filter_v2/client,
    waku_filter_v2/common as filter_common,
    waku_mix/protocol,
    common/logging,
  ],
  ./config_chat2mix

import libp2p/protocols/pubsub/rpc/messages, libp2p/protocols/pubsub/pubsub
import ../../waku/waku_rln_relay

logScope:
  topics = "chat2 mix"

#########################
## Mix Spam Protection ##
#########################

# Forward declaration
proc maintainSpamProtectionSubscription(
  node: WakuNode, contentTopics: seq[ContentTopic]
) {.async.}

proc setupMixSpamProtectionViaFilter(node: WakuNode) {.async.} =
  ## Setup filter-based spam protection coordination for mix protocol.
  ## Since chat2mix doesn't use relay, we subscribe via filter to receive
  ## spam protection coordination messages.

  # Register message handler for spam protection coordination
  let spamTopics = node.wakuMix.getSpamProtectionContentTopics()

  proc handleSpamMessage(
      pubsubTopic: PubsubTopic, message: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    await node.wakuMix.handleMessage(pubsubTopic, message)

  node.wakuFilterClient.registerPushHandler(handleSpamMessage)

  # Wait for filter peer and maintain subscription
  asyncSpawn maintainSpamProtectionSubscription(node, spamTopics)

proc maintainSpamProtectionSubscription(
    node: WakuNode, contentTopics: seq[ContentTopic]
) {.async.} =
  ## Maintain filter subscription for spam protection topics.
  ## Monitors subscription health with periodic pings and re-subscribes on failure.
  const RetryInterval = chronos.seconds(5)
  const SubscriptionMaintenance = chronos.seconds(30)
  const MaxFailedSubscribes = 3
  var currentFilterPeer: Option[RemotePeerInfo] = none(RemotePeerInfo)
  var noFailedSubscribes = 0

  while true:
    # Select or reuse filter peer
    if currentFilterPeer.isNone():
      let filterPeerOpt = node.peerManager.selectPeer(WakuFilterSubscribeCodec)
      if filterPeerOpt.isNone():
        debug "No filter peer available yet for spam protection, retrying..."
        await sleepAsync(RetryInterval)
        continue
      currentFilterPeer = some(filterPeerOpt.get())
      info "Selected filter peer for spam protection",
        peer = currentFilterPeer.get().peerId

    # Check if subscription is still alive with ping
    let pingErr = (await node.wakuFilterClient.ping(currentFilterPeer.get())).errorOr:
      # Subscription is alive, wait before next check
      await sleepAsync(SubscriptionMaintenance)
      if noFailedSubscribes > 0:
        noFailedSubscribes = 0
      continue

    # Subscription lost, need to re-subscribe
    warn "Spam protection filter subscription ping failed, re-subscribing",
      error = pingErr, peer = currentFilterPeer.get().peerId

    # Determine pubsub topic from content topics (using auto-sharding)
    if node.wakuAutoSharding.isNone():
      error "Auto-sharding not configured, cannot determine pubsub topic for spam protection"
      await sleepAsync(RetryInterval)
      continue

    let shardRes = node.wakuAutoSharding.get().getShard(contentTopics[0])
    if shardRes.isErr():
      error "Failed to determine shard for spam protection", error = shardRes.error
      await sleepAsync(RetryInterval)
      continue

    let shard = shardRes.get()
    let pubsubTopic: PubsubTopic = shard # converter toPubsubTopic

    # Subscribe to spam protection topics
    let res = await node.wakuFilterClient.subscribe(
      currentFilterPeer.get(), pubsubTopic, contentTopics
    )
    if res.isErr():
      noFailedSubscribes += 1
      warn "Failed to subscribe to spam protection topics via filter",
        error = res.error, topics = contentTopics, failCount = noFailedSubscribes

      if noFailedSubscribes >= MaxFailedSubscribes:
        # Try with a different peer
        warn "Max subscription failures reached, selecting new filter peer"
        currentFilterPeer = none(RemotePeerInfo)
        noFailedSubscribes = 0

      await sleepAsync(RetryInterval)
    else:
      info "Successfully subscribed to spam protection topics via filter",
        topics = contentTopics, peer = currentFilterPeer.get().peerId
      noFailedSubscribes = 0
      await sleepAsync(SubscriptionMaintenance)

const Help =
  """
  Commands: /[?|help|connect|nick|exit]
  help: Prints this help
  connect: dials a remote peer
  nick: change nickname for current chat session
  exit: exits chat session
"""

# XXX Connected is a bit annoying, because incoming connections don't trigger state change
# Could poll connection pool or something here, I suppose
# TODO Ensure connected turns true on incoming connections, or get rid of it
type Chat = ref object
  node: WakuNode # waku node for publishing, subscribing, etc
  transp: StreamTransport # transport streams between read & write file descriptor
  subscribed: bool # indicates if a node is subscribed or not to a topic
  connected: bool # if the node is connected to another peer
  started: bool # if the node has started
  nick: string # nickname for this chat session
  prompt: bool # chat prompt is showing
  contentTopic: string # default content topic for chat messages
  conf: Chat2Conf # configuration for chat2

type
  PrivateKey* = crypto.PrivateKey
  Topic* = waku_core.PubsubTopic

const MinMixNodePoolSize = 4

#####################
## chat2 protobufs ##
#####################

type
  SelectResult*[T] = Result[T, string]

  Chat2Message* = object
    timestamp*: int64
    nick*: string
    payload*: seq[byte]

proc getPubsubTopic*(
    conf: Chat2Conf, node: WakuNode, contentTopic: string
): PubsubTopic =
  let shard = node.wakuAutoSharding.get().getShard(contentTopic).valueOr:
      echo "Could not parse content topic: " & error
      return "" #TODO: fix this.
  return $RelayShard(clusterId: conf.clusterId, shardId: shard.shardId)

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
  # Get message date and timestamp in local time
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
  # No payload encoding/encryption from Waku
  let pb = Chat2Message.init(payload).valueOr:
    return string.fromBytes(payload)
  return $pb

proc printReceivedMessage(c: Chat, msg: WakuMessage) =
  let chatLine = getChatLine(msg.payload)
  try:
    echo &"{chatLine}"
  except ValueError:
    # Formatting fail. Print chat line in any case.
    echo chatLine

  c.prompt = false
  showChatPrompt(c)
  trace "Printing message", chatLine, contentTopic = msg.contentTopic

proc readNick(transp: StreamTransport): Future[string] {.async.} =
  # Chat prompt
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

proc publish(c: Chat, line: string) {.async.} =
  # First create a Chat2Message protobuf with this line of text
  let time = getTime().toUnix()
  let chat2pb =
    Chat2Message(timestamp: time, nick: c.nick, payload: line.toBytes()).encode()

  ## @TODO: error handling on failure
  proc handler(response: LightPushResponse) {.gcsafe, closure.} =
    trace "lightpush response received", response = response

  var message = WakuMessage(
    payload: chat2pb.buffer,
    contentTopic: c.contentTopic,
    version: 0,
    timestamp: getNanosecondTime(time),
  )

  try:
    if not c.node.wakuLightpushClient.isNil():
      # Attempt lightpush with mix
      let res = await c.node.lightpushPublish(
        some(c.conf.getPubsubTopic(c.node, c.contentTopic)),
        message,
        none(RemotePeerInfo),
        true,
      )
      if res.isErr():
        error "failed to publish lightpush message", error = res.error
        echo "Error: " & res.error.desc.get("unknown error")
    else:
      error "failed to publish message as lightpush client is not initialized"
      echo "Error: lightpush client is not initialized"
  except CatchableError:
    error "caught error publishing message: ", error = getCurrentExceptionMsg()
    echo "Error: " & getCurrentExceptionMsg()

# TODO This should read or be subscribe handler subscribe
proc readAndPrint(c: Chat) {.async.} =
  while true:
    #    while p.connected:
    #      # TODO: echo &"{p.id} -> "
    #
    #      echo cast[string](await p.conn.readLp(1024))
    #echo "readAndPrint subscribe NYI"
    await sleepAsync(100)

# TODO Implement
proc writeAndPrint(c: Chat) {.async.} =
  while true:
    # Connect state not updated on incoming WakuRelay connections
    #    if not c.connected:
    #      echo "type an address or wait for a connection:"
    #      echo "type /[help|?] for help"

    # Chat prompt
    showChatPrompt(c)

    let line = await c.transp.readLine()
    if line.startsWith("/help") or line.startsWith("/?") or not c.started:
      echo Help
      continue

    #    if line.startsWith("/disconnect"):
    #      echo "Ending current session"
    #      if p.connected and p.conn.closed.not:
    #        await p.conn.close()
    #      p.connected = false
    elif line.startsWith("/connect"):
      # TODO Should be able to connect to multiple peers for Waku chat
      if c.connected:
        echo "already connected to at least one peer"
        continue

      echo "enter address of remote peer"
      let address = await c.transp.readLine()
      if address.len > 0:
        await c.connectToNodes(@[address])
    elif line.startsWith("/nick"):
      # Set a new nickname
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
      # XXX connected state problematic
      if c.started:
        echo "publishing message: " & line
        await c.publish(line)
        # TODO Connect to peer logic?
      else:
        try:
          if line.startsWith("/") and "p2p" in line:
            await c.connectToNodes(@[line])
        except:
          echo &"unable to dial remote peer {line}"
          echo getCurrentExceptionMsg()

proc readWriteLoop(c: Chat) {.async.} =
  asyncSpawn c.writeAndPrint() # execute the async function but does not block
  asyncSpawn c.readAndPrint()

proc readInput(wfd: AsyncFD) {.thread, raises: [Defect, CatchableError].} =
  ## This procedure performs reading from `stdin` and sends data over
  ## pipe to main thread.
  let transp = fromPipe(wfd)

  while true:
    let line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

var alreadyUsedServicePeers {.threadvar.}: seq[RemotePeerInfo]

proc selectRandomServicePeer*(
    pm: PeerManager, actualPeer: Option[RemotePeerInfo], codec: string
): Result[RemotePeerInfo, void] =
  if actualPeer.isSome():
    alreadyUsedServicePeers.add(actualPeer.get())

  let supportivePeers = pm.switch.peerStore.getPeersByProtocol(codec).filterIt(
      it notin alreadyUsedServicePeers
    )
  if supportivePeers.len == 0:
    return err()

  let rndPeerIndex = rand(0 .. supportivePeers.len - 1)
  return ok(supportivePeers[rndPeerIndex])

proc maintainSubscription(
    wakuNode: WakuNode,
    filterPubsubTopic: PubsubTopic,
    filterContentTopic: ContentTopic,
    filterPeer: RemotePeerInfo,
    preventPeerSwitch: bool,
) {.async.} =
  var actualFilterPeer = filterPeer
  const maxFailedSubscribes = 3
  const maxFailedServiceNodeSwitches = 10
  var noFailedSubscribes = 0
  var noFailedServiceNodeSwitches = 0
  # Use chronos.Duration explicitly to avoid mismatch with std/times.Duration
  let RetryWait = chronos.seconds(2) # Quick retry interval
  let SubscriptionMaintenance = chronos.seconds(30) # Subscription maintenance interval
  while true:
    info "maintaining subscription at", peer = constructMultiaddrStr(actualFilterPeer)
    # First use filter-ping to check if we have an active subscription
    let pingErr = (await wakuNode.wakuFilterClient.ping(actualFilterPeer)).errorOr:
      await sleepAsync(SubscriptionMaintenance)
      info "subscription is live."
      continue

    # No subscription found. Let's subscribe.
    error "ping failed.", error = pingErr
    trace "no subscription found. Sending subscribe request"

    let subscribeErr = (
      await wakuNode.filterSubscribe(
        some(filterPubsubTopic), filterContentTopic, actualFilterPeer
      )
    ).errorOr:
      await sleepAsync(SubscriptionMaintenance)
      if noFailedSubscribes > 0:
        noFailedSubscribes -= 1
      notice "subscribe request successful."
      continue

    noFailedSubscribes += 1
    error "Subscribe request failed.",
      error = subscribeErr, peer = actualFilterPeer, failCount = noFailedSubscribes

    # TODO: disconnet from failed actualFilterPeer
    # asyncSpawn(wakuNode.peerManager.switch.disconnect(p))
    # wakunode.peerManager.peerStore.delete(actualFilterPeer)

    if noFailedSubscribes < maxFailedSubscribes:
      await sleepAsync(RetryWait) # Wait a bit before retrying
    elif not preventPeerSwitch:
      # try again with new peer without delay
      let actualFilterPeer = selectRandomServicePeer(
        wakuNode.peerManager, some(actualFilterPeer), WakuFilterSubscribeCodec
      ).valueOr:
        error "Failed to find new service peer. Exiting."
        noFailedServiceNodeSwitches += 1
        break

      info "Found new peer for codec",
        codec = filterPubsubTopic, peer = constructMultiaddrStr(actualFilterPeer)

      noFailedSubscribes = 0
    else:
      await sleepAsync(SubscriptionMaintenance)

{.pop.}
  # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
proc processInput(rfd: AsyncFD, rng: ref HmacDrbgContext) {.async.} =
  let
    transp = fromPipe(rfd)
    conf = Chat2Conf.load()
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

  enrBuilder.withWakuRelaySharding(
    RelayShards(clusterId: conf.clusterId, shardIds: conf.shards)
  ).isOkOr:
    error "failed to add sharded topics to ENR", error = error
    quit(QuitFailure)

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

  node.mountAutoSharding(conf.clusterId, conf.numShardsInNetwork).isOkOr:
    error "failed to mount waku sharding: ", error = error
    quit(QuitFailure)
  node.mountMetadata(conf.clusterId, conf.shards).isOkOr:
    error "failed to mount waku metadata protocol: ", err = error
    quit(QuitFailure)

  let (mixPrivKey, mixPubKey) = generateKeyPair().valueOr:
    error "failed to generate mix key pair", error = error
    return

  (
    await node.mountMix(
      conf.clusterId, mixPrivKey, conf.mixnodes, some(conf.rlnUserMessageLimit)
    )
  ).isOkOr:
    error "failed to mount waku mix protocol: ", error = $error
    quit(QuitFailure)

  # Setup extended kademlia discovery if bootstrap nodes are provided
  if conf.kadBootstrapNodes.len > 0:
    var kadBootstrapPeers: seq[(PeerId, seq[MultiAddress])]
    for nodeStr in conf.kadBootstrapNodes:
      let (peerId, ma) = parseFullAddress(nodeStr).valueOr:
        error "Failed to parse kademlia bootstrap node", node = nodeStr, error = error
        continue
      kadBootstrapPeers.add((peerId, @[ma]))

    if kadBootstrapPeers.len > 0:
      node.wakuKademlia = WakuKademlia.new(
        node.switch,
        ExtendedKademliaDiscoveryParams(
          bootstrapNodes: kadBootstrapPeers,
          mixPubKey: some(mixPubKey),
          advertiseMix: false,
        ),
        node.peerManager,
        getMixNodePoolSize = proc(): int {.gcsafe, raises: [].} =
          if node.wakuMix.isNil():
            0
          else:
            node.getMixNodePoolSize(),
        isNodeStarted = proc(): bool {.gcsafe, raises: [].} =
          node.started,
      ).valueOr:
        error "failed to setup kademlia discovery", error = error
        quit(QuitFailure)

  #await node.mountRendezvousClient(conf.clusterId)

  # Subscribe to spam protection coordination topics via filter since chat2mix doesn't use relay
  if not node.wakuFilterClient.isNil():
    asyncSpawn setupMixSpamProtectionViaFilter(node)

  await node.start()

  node.peerManager.start()
  if not node.wakuKademlia.isNil():
    (await node.wakuKademlia.start(minMixPeers = MinMixNodePoolSize)).isOkOr:
      error "failed to start kademlia discovery", error = error
      quit(QuitFailure)

  await node.mountLibp2pPing()
  #await node.mountPeerExchangeClient()
  let pubsubTopic = conf.getPubsubTopic(node, conf.contentTopic)
  echo "pubsub topic is: " & pubsubTopic
  let nick = await readNick(transp)
  echo "Welcome, " & nick & "!"

  var chat = Chat(
    node: node,
    transp: transp,
    subscribed: true,
    connected: false,
    started: true,
    nick: nick,
    prompt: false,
    contentTopic: conf.contentTopic,
    conf: conf,
  )

  var dnsDiscoveryUrl = none(string)

  if conf.fleet != Fleet.none:
    # Use DNS discovery to connect to selected fleet
    echo "Connecting to " & $conf.fleet & " fleet using DNS discovery..."

    if conf.fleet == Fleet.test:
      dnsDiscoveryUrl = some(
        "enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im"
      )
    else:
      # Connect to sandbox by default
      dnsDiscoveryUrl = some(
        "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
      )
  elif conf.dnsDiscoveryUrl != "":
    # No pre-selected fleet. Discover nodes via DNS using user config
    info "Discovering nodes using Waku DNS discovery", url = conf.dnsDiscoveryUrl
    dnsDiscoveryUrl = some(conf.dnsDiscoveryUrl)

  var discoveredNodes: seq[RemotePeerInfo]

  if dnsDiscoveryUrl.isSome:
    var nameServers: seq[TransportAddress]
    for ip in conf.dnsDiscoveryNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain = domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0] # Use only first answer

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
      # We have a viable storenode. Let's query it for historical messages.
      echo "Connecting to storenode: " & $(storenode.get())

      node.mountStoreClient()
      node.peerManager.addServicePeer(storenode.get(), WakuStoreCodec)

      proc storeHandler(response: StoreQueryResponse) {.gcsafe.} =
        for msg in response.messages:
          let payload =
            if msg.message.isSome():
              msg.message.get().payload
            else:
              newSeq[byte](0)

          let chatLine = getChatLine(payload)
          echo &"{chatLine}"
        info "Hit store handler"

      let queryRes = await node.query(
        StoreQueryRequest(contentTopics: @[chat.contentTopic]), storenode.get()
      )
      if queryRes.isOk():
        storeHandler(queryRes.value)

  if conf.edgemode: #Mount light protocol clients
    node.mountLightPushClient()
    await node.mountFilterClient()
    let filterHandler = proc(
        pubsubTopic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, closure.} =
      trace "Hit filter handler", contentTopic = msg.contentTopic
      chat.printReceivedMessage(msg)

    node.wakuFilterClient.registerPushHandler(filterHandler)
  var servicePeerInfo: RemotePeerInfo
  if conf.serviceNode != "":
    servicePeerInfo = parsePeerInfo(conf.serviceNode).valueOr:
      error "Couldn't parse conf.serviceNode", error = error
      RemotePeerInfo()
  if servicePeerInfo == nil or $servicePeerInfo.peerId == "":
    # Assuming that service node supports all services
    servicePeerInfo = selectRandomServicePeer(
      node.peerManager, none(RemotePeerInfo), WakuLightpushCodec
    ).valueOr:
      error "Couldn't find any service peer"
      quit(QuitFailure)

  node.peerManager.addServicePeer(servicePeerInfo, WakuLightpushCodec)
  node.peerManager.addServicePeer(servicePeerInfo, WakuPeerExchangeCodec)
  #node.peerManager.addServicePeer(servicePeerInfo, WakuRendezVousCodec)

  # Start maintaining subscription
  asyncSpawn maintainSubscription(
    node, pubsubTopic, conf.contentTopic, servicePeerInfo, false
  )
  echo "waiting for mix nodes to be discovered..."

  while node.getMixNodePoolSize() < MinMixNodePoolSize:
    info "waiting for mix nodes to be discovered",
      currentpoolSize = node.getMixNodePoolSize()
    await sleepAsync(1000)
  notice "ready to publish with mix node pool size ",
    currentpoolSize = node.getMixNodePoolSize()
  echo "ready to publish messages now"

  # Once min mixnodes are discovered loop as per default setting
  node.startPeerExchangeLoop()

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
  # Handle only ConfigurationError for now
  # TODO: Throw other errors from the mounting procedure
  except ConfigurationError as e:
    raise e

when isMainModule: # isMainModule = true when the module is compiled as the main file
  let rng = crypto.newRng()
  try:
    waitFor(main(rng))
  except CatchableError as e:
    raise e

## Dump of things that can be improved:
##
## - Incoming dialed peer does not change connected state (not relying on it for now)
## - Unclear if staticnode argument works (can enter manually)
## - Don't trigger self / double publish own messages
## - Test/default to cluster node connection (diff protocol version)
## - Redirect logs to separate file
## - Expose basic publish/subscribe etc commands with /syntax
## - Show part of peerid to know who sent message
## - Deal with protobuf messages (e.g. other chat protocol, or encrypted)
