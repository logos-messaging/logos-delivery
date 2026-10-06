{.used.}

## Mix test fixtures.

import
  std/[net, sequtils, strutils, tables],
  chronos,
  results,
  stew/byteutils,
  testutils/unittests,
  libp2p/[multiaddress, peerid, peerinfo, switch],
  libp2p/crypto/crypto,
  libp2p/stream/connection,
  libp2p_mix/[curve25519, mix_protocol]
import
  logos_delivery/waku/[waku_core, waku_node, waku_mix, waku_lightpush],
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/peer_manager/waku_peer_store,
  logos_delivery/waku/common/rate_limit/setting,
  logos_delivery/waku/discovery/[peer_discovery_interface, peer_discovery_conversion],
  ./[futures, testasync, wakucore, wakunode]

const
  MixNodeCount* = 4
  DeadAddress* = "/ip4/127.0.0.1/tcp/1"
    ## Nothing listens on port 1, so a dial to it fails at once.

proc mountMixWith(
    node: WakuNode,
    addressPolicy: PeerAddressPolicy,
    bootnodes: seq[MixNodePubInfo] = @[],
) {.async.} =
  let keys = generateKeyPair().expect("mix key pair")
  (await node.mountMix(DefaultClusterId, keys.privateKey, bootnodes, addressPolicy)).isOkOr:
    raiseAssert "mountMix: " & $error

proc mixNode*(
    addressPolicy: PeerAddressPolicy = mixAddressPolicy(false),
    bootnodes: seq[MixNodePubInfo] = @[],
): Future[WakuNode] {.async.} =
  ## A node with mix that never starts, so it dials nothing.
  let node = newTestWakuNode(generateSecp256k1Key(), quicEnabled = false)
  await node.mountMixWith(addressPolicy, bootnodes)
  return node

proc loopbackNode(quicEnabled: bool): WakuNode =
  let node = newTestWakuNode(
    generateSecp256k1Key(),
    parseIpAddress("127.0.0.1"),
    Port(0),
    quicEnabled = quicEnabled,
  )
  node.mountMetadata(uint32(DefaultClusterId), @[0'u16]).expect("metadata")
  return node

proc tcpAddress*(node: WakuNode): string =
  ## The loopback tcp address that a started node listens on.
  "/ip4/127.0.0.1/tcp/" & $node.boundTcpPort()

proc startNodeWithoutMix*(): Future[WakuNode] {.async.} =
  ## A started node without mix, for a real dial.
  let node = loopbackNode(quicEnabled = false)
  await node.start()
  return node

proc startMixNode*(
    quicEnabled = false, poolLoopInterval = chronos.hours(1)
): Future[WakuNode] {.async.} =
  ## A started node with mix. It uses `defaultAddressPolicy`, which accepts
  ## loopback addresses. With the default `poolLoopInterval`, the pool loop runs
  ## only once, at the start.
  let node = loopbackNode(quicEnabled)
  await node.mountMixWith(defaultAddressPolicy)
  node.wakuMix.pool.poolLoopInterval = poolLoopInterval
  await node.start()
  return node

proc discover*(
    node: WakuNode,
    addrs: seq[string],
    peerId = PeerId.init(generateSecp256k1Key()).tryGet(),
): PeerId {.discardable.} =
  ## Stores a discovery record with a new mix key, for a new or known peer.
  let keys = generateKeyPair().expect("mix key pair")
  let found = DiscoveredPeer(
    peerId: $peerId,
    addrs: addrs,
    services: @[DiscoveredService(id: MixProtocolID, data: @(keys.publicKey))],
  )
  node.peerManager.addPeer(found.toRemotePeerInfo().expect("discovered peer"))
  return peerId

proc bootnode*(address: string): MixNodePubInfo =
  let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
  let keys = generateKeyPair().expect("mix key pair")
  MixNodePubInfo(multiAddr: address & "/p2p/" & $peerId, pubKey: keys.publicKey)

proc peerId*(entry: MixNodePubInfo): PeerId =
  parsePeerInfo(entry.multiAddr).tryGet().peerId

proc discoverAt*(node: WakuNode, addresses: varargs[string]): seq[PeerId] =
  ## One discovered mix peer at each address.
  addresses.mapIt(node.discover(@[it]))

proc deadPeers*(node: WakuNode, count: int): seq[PeerId] =
  ## Discovered mix peers at `DeadAddress`.
  (0 ..< count).toSeq().mapIt(node.discover(@[DeadAddress]))

proc inPool*(node: WakuNode, peerId: PeerId): bool =
  node.wakuMix.nodePool.get(peerId).isSome()

proc hopOf*(node: WakuNode, peerId: PeerId): MultiAddress =
  node.wakuMix.nodePool.get(peerId).expect("pool entry").multiAddr

# Each node of the mixnet fixture has relay, lightpush and mix. It connects to
# each other node.

type
  ExitHook* = ref object
    ## Makes the first lightpush request at the exit wait until the test lets it
    ## reply.
    enabled: bool ## True until the first request.
    requested*: AsyncEvent
    reply*: AsyncEvent

  MixNet* = object
    nodes*: seq[WakuNode]
    infos*: seq[MixNodePubInfo]
    arrivals: ref seq[string] ## The test messages that a mix node received over relay.

proc new*(T: type ExitHook): ExitHook =
  ExitHook(enabled: true, requested: newAsyncEvent(), reply: newAsyncEvent())

proc exit*(net: MixNet): WakuNode =
  net.nodes[0]

proc mountHookedLightpush(node: WakuNode, hook: ExitHook) =
  ## Lightpush over relay, whose first request waits for the test.
  let relayHandler = getRelayPushHandler(node.wakuRelay)
  let handler: PushMessageHandler = proc(
      pubsubTopic: PubsubTopic, message: WakuMessage
  ): Future[WakuLightPushResult] {.async.} =
    if hook.enabled:
      hook.enabled = false
      hook.requested.fire()
      await hook.reply.wait()
    return await relayHandler(pubsubTopic, message)
  node.wakuLightPush = WakuLightPush.new(
    node.peerManager,
    node.rng,
    handler,
    node.wakuAutoSharding,
    Opt.none(RateLimitSetting),
  )
  node.switch.mount(node.wakuLightPush, protocolMatcher(WakuLightPushCodec))

proc meshFormed(net: MixNet): bool =
  for node in net.nodes:
    for other in net.nodes:
      if other != node and
          not node.hasMeshPeer(DefaultPubsubTopic, other.peerInfo.peerId):
        return false
  return true

proc startMixNodes*(hook: ExitHook = nil): Future[MixNet] {.async.} =
  ## Starts the mixnet fixture. `hook` makes the first lightpush request at the
  ## exit wait for the test.
  var net = MixNet(arrivals: new(seq[string]))
  var keys: seq[FieldElement]
  for i in 0 ..< MixNodeCount:
    # The default transports, quic and tcp, as on the fleet.
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    (await node.mountRelay()).expect("relay")
    if i == 0 and not hook.isNil():
      node.mountHookedLightpush(hook)
    else:
      (await node.mountLightpush()).expect("lightpush")
    node.mountMetadata(uint32(DefaultClusterId), @[0'u16]).expect("metadata")
    let kp = generateKeyPair().expect("mix key")
    keys.add(kp.publicKey)
    (await node.mountMix(DefaultClusterId, kp.privateKey, @[], defaultAddressPolicy)).expect(
      "mix"
    )
    await node.start()
    net.nodes.add(node)

  # Each node knows the others by their bound tcp ports.
  for i, node in net.nodes:
    net.infos.add(
      MixNodePubInfo(
        multiAddr: node.tcpAddress() & "/p2p/" & $node.peerInfo.peerId, pubKey: keys[i]
      )
    )
  for i, node in net.nodes:
    node.wakuMix.addBootNodes(
      (0 ..< MixNodeCount).toSeq().filterIt(it != i).mapIt(net.infos[it])
    )

  for i in 0 ..< MixNodeCount:
    for j in i + 1 ..< MixNodeCount:
      await net.nodes[i].switch.connect(
        net.nodes[j].peerInfo.peerId, net.nodes[j].peerInfo.addrs
      )
    let arrivals = net.arrivals
    proc receive(topic: PubsubTopic, msg: WakuMessage) {.async.} =
      let payload = string.fromBytes(msg.payload)
      if payload.startsWith("mix-nat-") and payload notin arrivals[]:
        arrivals[].add(payload)

    net.nodes[i].subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), receive).expect(
      "subscribe"
    )
  checkUntilTimeout:
    net.meshFormed()
  return net

proc addNatSender*(
    bootnodes: seq[MixNodePubInfo], quicEnabled = true
): Future[WakuNode] {.async.} =
  ## A lightpush client with mix that announces only `DeadAddress`.
  let sender = newTestWakuNode(
    generateSecp256k1Key(),
    parseIpAddress("127.0.0.1"),
    Port(0),
    quicEnabled = quicEnabled,
    extMultiAddrs = @[MultiAddress.init(DeadAddress).tryGet()],
    extMultiAddrsOnly = true,
  )
  sender.mountLightpushClient()
  sender.mountMetadata(uint32(DefaultClusterId), @[0'u16]).expect("metadata")
  await sender.mountMixWith(defaultAddressPolicy, bootnodes)
  await sender.start()
  return sender

proc stop*(net: MixNet, senders: seq[WakuNode]) {.async.} =
  for node in senders:
    await node.stop()
  for node in net.nodes:
    await node.stop()

proc connectExit*(net: MixNet, sender: WakuNode) {.async.} =
  ## Connects the sender to the exit.
  await sender.switch.connect(net.exit.peerInfo.peerId, net.exit.peerInfo.addrs)

proc connectedNodes*(net: MixNet, sender: WakuNode): seq[int] =
  (0 ..< MixNodeCount).toSeq().filterIt(
    sender.switch.isConnected(net.nodes[it].peerInfo.peerId)
  )

proc disconnectAll*(net: MixNet, sender: WakuNode) {.async.} =
  ## Drops every connection between the sender and the mix nodes, and waits
  ## until both sides see it.
  for node in net.nodes:
    await sender.switch.disconnect(node.peerInfo.peerId)
  checkUntilTimeout:
    net.connectedNodes(sender).len == 0
    net.nodes.allIt(not it.switch.isConnected(sender.peerInfo.peerId))

proc connectOnly*(net: MixNet, sender: WakuNode, index: int) {.async.} =
  ## Leaves the sender with one outbound connection, to node `index`.
  await net.disconnectAll(sender)
  await sender.switch.connect(
    net.nodes[index].peerInfo.peerId, net.nodes[index].peerInfo.addrs
  )
  doAssert net.connectedNodes(sender) == @[index]

proc noInboundConnections*(sender: WakuNode): bool =
  ## True when the sender opened each of its connections itself.
  for peerId, muxers in sender.switch.connManager.getConnections():
    for muxer in muxers:
      if muxer.connection.transportDir == Direction.In:
        return false
  return true

type SendOutcome* = object
  marker: string
  acked*: bool
  error*: string
  elapsed*: Duration

proc send*(
    net: MixNet, sender: WakuNode, label: string
): Future[SendOutcome] {.async.} =
  let marker = "mix-nat-" & label
  let message =
    fakeWakuMessage(payload = marker, contentTopic = "/mix-nat/1/probe/proto")
  let start = Moment.now()
  let response = await sender.lightpushPublish(
    Opt.some(DefaultPubsubTopic),
    message,
    Opt.some(net.exit.peerInfo.toRemotePeerInfo()),
    mixify = true,
  )
  let elapsed = Moment.now() - start
  return SendOutcome(
    marker: marker,
    acked: response.isOk(),
    error:
      if response.isErr():
        response.error.desc.get($response.error.code)
      else:
        "",
    elapsed: elapsed,
  )

proc published*(
    net: MixNet, outcome: SendOutcome, window = FUTURE_TIMEOUT
): Future[bool] {.async.} =
  ## True when the message of `outcome` reaches a mix node within `window`.
  ## Relay supplies the message also when the lightpush reply does not come.
  let deadline = Moment.now() + window
  while outcome.marker notin net.arrivals[]:
    if Moment.now() >= deadline:
      return false
    await sleepAsync(chronos.milliseconds(10))
  return true

proc count(counter: ref int): int =
  # An async proc that dereferences a `ref int` parameter crashes the compiler.
  counter[]

proc staysAtMost*(
    counter: ref int, limit: int, window = FUTURE_TIMEOUT_SHORT
): Future[bool] {.async.} =
  ## True when `counter` stays at or below `limit` for the whole `window`.
  let deadline = Moment.now() + window
  while Moment.now() < deadline:
    if counter.count() > limit:
      return false
    await sleepAsync(chronos.milliseconds(10))
  return counter.count() <= limit

proc unresponsiveServer*(accepted: ref int = nil): StreamServer =
  ## Accepts TCP connections and never answers. Each connection stays open
  ## until the peer closes it. Counts them in `accepted`.
  proc serve(server: StreamServer, transp: StreamTransport) {.async: (raises: []).} =
    if not accepted.isNil():
      accepted[].inc()
    try:
      discard await transp.read()
    except CatchableError:
      discard
    await transp.closeWait()

  let server = createStreamServer(initTAddress("127.0.0.1", Port(0)), serve)
  server.start()
  return server

proc address*(server: StreamServer): string =
  ## The loopback tcp address of `server`.
  "/ip4/127.0.0.1/tcp/" & $server.localAddress().port
