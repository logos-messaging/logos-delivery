import
  std/[tables, times, sequtils, strutils],
  stew/byteutils,
  chronicles,
  results,
  chronos,
  confutils,
  libp2p/crypto/crypto,
  libp2p/crypto/curve25519,
  libp2p/protocols/mix,
  libp2p/protocols/mix/curve25519,
  libp2p/multiaddress,
  eth/keys,
  eth/enr/enr,
  metrics,
  metrics/chronos_httpserver

import
  waku/[
    common/logging,
    node/peer_manager,
    waku_core,
    waku_core/codecs,
    waku_node,
    waku_enr,
    discovery/waku_discv5,
    factory/builder,
    waku_lightpush/client,
  ],
  ./lightpush_publisher_mix_config,
  ./lightpush_publisher_mix_metrics

const clusterId = 66
const shardId = @[0'u16]

const
  LightpushPubsubTopic = PubsubTopic("/waku/2/rs/66/0")
  LightpushContentTopic = ContentTopic("/examples/1/light-pubsub-mix-example/proto")

proc splitPeerIdAndAddr(maddr: string): (string, string) =
  let parts = maddr.split("/p2p/")
  if parts.len != 2:
    error "Invalid multiaddress format", parts = parts
    return

  let
    address = parts[0]
    peerId = parts[1]
  return (address, peerId)

proc setupAndPublish(rng: ref HmacDrbgContext, conf: LightPushMixConf) {.async.} =
  # use notice to filter all waku messaging
  setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)
  notice "starting publisher", wakuPort = conf.port

  let
    nodeKey = crypto.PrivateKey.random(Secp256k1, rng[]).get()
    ip = parseIpAddress("0.0.0.0")
    flags = CapabilitiesBitfield.init(relay = true)

  let relayShards = RelayShards.init(clusterId, shardId).valueOr:
    error "Relay shards initialization failed", error = error
    quit(QuitFailure)

  var enrBuilder = EnrBuilder.init(nodeKey)
  enrBuilder.withWakuRelaySharding(relayShards).expect(
    "Building ENR with relay sharding failed"
  )

  let record = enrBuilder.build().valueOr:
    error "failed to create enr record", error = error
    quit(QuitFailure)

  setLogLevel(logging.LogLevel.TRACE)
  var builder = WakuNodeBuilder.init()
  builder.withNodeKey(nodeKey)
  builder.withRecord(record)
  builder.withNetworkConfigurationDetails(ip, Port(conf.port)).tryGet()

  let node = builder.build().tryGet()

  node.mountMetadata(clusterId, shardId).expect(
    "failed to mount waku metadata protocol"
  )
  node.mountLightPushClient()
  try:
    await node.mountPeerExchange(some(uint16(clusterId)))
  except CatchableError:
    error "failed to mount waku peer-exchange protocol",
      error = getCurrentExceptionMsg()
    return

  let (destPeerAddr, destPeerId) = splitPeerIdAndAddr(conf.destPeerAddr)
  let (pxPeerAddr, pxPeerId) = splitPeerIdAndAddr(conf.pxAddr)
  info "dest peer address", destPeerAddr = destPeerAddr, destPeerId = destPeerId
  info "peer exchange address", pxPeerAddr = pxPeerAddr, pxPeerId = pxPeerId
  let pxPeerInfo =
    RemotePeerInfo.init(destPeerId, @[MultiAddress.init(destPeerAddr).get()])
  node.peerManager.addServicePeer(pxPeerInfo, WakuPeerExchangeCodec)

  let pxPeerInfo1 =
    RemotePeerInfo.init(pxPeerId, @[MultiAddress.init(pxPeerAddr).get()])
  node.peerManager.addServicePeer(pxPeerInfo1, WakuPeerExchangeCodec)

  if not conf.mixDisabled:
    let (mixPrivKey, mixPubKey) = generateKeyPair().valueOr:
      error "failed to generate mix key pair", error = error
      return
    (await node.mountMix(clusterId, mixPrivKey, conf.mixnodes)).isOkOr:
      error "failed to mount waku mix protocol: ", error = $error
      return

  let dPeerId = PeerId.init(destPeerId).valueOr:
    error "Failed to initialize PeerId", error = error
    return

  await node.mountRendezvousClient(clusterId)
  await node.start()
  node.peerManager.start()
  node.startPeerExchangeLoop()
  try:
    startMetricsHttpServer("0.0.0.0", Port(8008))
  except Exception:
    error "failed to start metrics server: ", error = getCurrentExceptionMsg()
  (await node.fetchPeerExchangePeers()).isOkOr:
    warn "Cannot fetch peers from peer exchange", cause = error

  if not conf.mixDisabled:
    while node.getMixNodePoolSize() < conf.minMixPoolSize:
      info "waiting for mix nodes to be discovered",
        currentpoolSize = node.getMixNodePoolSize()
      await sleepAsync(1000)
    notice "publisher service started with mix node pool size ",
      currentpoolSize = node.getMixNodePoolSize()

  var i = 0
  while i < conf.numMsgs:
    var conn: Connection
    if conf.mixDisabled:
      let connOpt = await node.peerManager.dialPeer(dPeerId, WakuLightPushCodec)
      if connOpt.isNone():
        error "failed to dial peer with WakuLightPushCodec", target_peer_id = dPeerId
        return
      conn = connOpt.get()
    else:
      conn = node.wakuMix.toConnection(
        MixDestination.exitNode(dPeerId), # destination lightpush peer
        WakuLightPushCodec, # protocol codec which will be used over the mix connection
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
          # mix parameters indicating we expect a single reply
      ).valueOr:
        error "failed to create mix connection", error = error
        return
    i = i + 1
    let text =
      """Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nullam venenatis magna ut tortor faucibus, in vestibulum nibh commodo. Aenean eget vestibulum augue. Nullam suscipit urna non nunc efficitur, at iaculis nisl consequat. Mauris quis ultrices elit. Suspendisse lobortis odio vitae laoreet facilisis. Cras ornare sem felis, at vulputate magna aliquam ac. Duis quis est ultricies, euismod nulla ac, interdum dui. Maecenas sit amet est vitae enim commodo gravida. Proin vitae elit nulla. Donec tempor dolor lectus, in faucibus velit elementum quis. Donec non mauris eu nibh faucibus cursus ut egestas dolor. Aliquam venenatis ligula id velit pulvinar malesuada. Vestibulum scelerisque, justo non porta gravida, nulla justo tempor purus, at sollicitudin erat erat vel libero.
      Fusce nec eros eu metus tristique aliquet.
      This is message #""" &
      $i & """ sent from a publisher using mix. End of transmission."""
    let message = WakuMessage(
      payload: toBytes(text), # content of the message
      contentTopic: LightpushContentTopic, # content topic to publish to
      ephemeral: true, # tell store nodes to not store it
      timestamp: getNowInNanosecondTime(),
    ) # current timestamp

    let res =
      await node.wakuLightpushClient.publish(some(LightpushPubsubTopic), message, conn)

    let startTime = getNowInNanosecondTime()

    (
      await node.wakuLightpushClient.publishWithConn(
        LightpushPubsubTopic, message, conn, dPeerId
      )
    ).isOkOr:
      error "failed to publish message via mix", error = error.desc
      lp_mix_failed.inc(labelValues = ["publish_error"])
      return

    let latency = float64(getNowInNanosecondTime() - startTime) / 1_000_000.0
    lp_mix_latency.observe(latency)
    lp_mix_success.inc()
    notice "published message",
      text = text,
      timestamp = message.timestamp,
      latency = latency,
      psTopic = LightpushPubsubTopic,
      contentTopic = LightpushContentTopic

    if conf.mixDisabled:
      await conn.close()
    await sleepAsync(conf.msgIntervalMilliseconds)
  info "Sent all messages via mix"
  quit(0)

when isMainModule:
  let conf = LightPushMixConf.load()
  let rng = crypto.newRng()
  asyncSpawn setupAndPublish(rng, conf)
  runForever()
