import
  std/[tables, times, sequtils],
  stew/byteutils,
  chronicles,
  chronos,
  confutils,
  libp2p/crypto/crypto,
  eth/keys,
  eth/enr/enr

import
  waku/[
    common/logging,
    node/peer_manager,
    waku_core,
    waku_node,
    waku_enr,
    discovery/waku_discv5,
    factory/builder,
  ]

proc now*(): Timestamp =
  getNanosecondTime(getTime().toUnixFloat())

# An accesible bootstrap node. See waku.sandbox fleets.status.im
const bootstrapNode =
  "enr:-QEkuEB3WHNS-xA3RDpfu9A2Qycr3bN3u7VoArMEiDIFZJ6" &
  "6F1EB3d4wxZN1hcdcOX-RfuXB-MQauhJGQbpz3qUofOtLAYJpZI" &
  "J2NIJpcIQI2SVcim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmFjL" &
  "WNuLWhvbmdrb25nLWMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2" &
  "XwA2Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS5zYW5" &
  "kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQ" &
  "AGAAeJc2VjcDI1NmsxoQPK35Nnz0cWUtSAhBp7zvHEhyU_AqeQU" &
  "lqzLiLxfP2L4oN0Y3CCdl-DdWRwgiMohXdha3UyDw"

# careful if running pub and sub in the same machine
const wakuPort = 60000
const discv5Port = 9000

proc setupAndPublish(rng: ref HmacDrbgContext) {.async.} =
  # use notice to filter all waku messaging
  setupLog(logging.LogLevel.NOTICE, logging.LogFormat.TEXT)

  notice "starting publisher", wakuPort = wakuPort, discv5Port = discv5Port
  let
    nodeKey = crypto.PrivateKey.random(Secp256k1, rng[]).get()
    ip = parseIpAddress("0.0.0.0")
    flags = CapabilitiesBitfield.init(relay = true)

  var enrBuilder = EnrBuilder.init(nodeKey)

  let record = enrBuilder.build().valueOr:
    error "failed to create enr record", error = error
    quit(QuitFailure)

  var builder = WakuNodeBuilder.init()
  builder.withNodeKey(nodeKey)
  builder.withRecord(record)
  builder.withNetworkConfigurationDetails(ip, Port(wakuPort)).tryGet()
  let node = builder.build().tryGet()

  var bootstrapNodeEnr: enr.Record
  discard bootstrapNodeEnr.fromURI(bootstrapNode)

  let discv5Conf = WakuDiscoveryV5Config(
    discv5Config: none(DiscoveryConfig),
    address: ip,
    port: Port(discv5Port),
    privateKey: keys.PrivateKey(nodeKey.skkey),
    bootstrapRecords: @[bootstrapNodeEnr],
    autoupdateRecord: true,
  )

  # assumes behind a firewall, so not care about being discoverable
  let wakuDiscv5 = WakuDiscoveryV5.new(
    node.rng,
    discv5Conf,
    some(node.enr),
    some(node.peerManager),
    node.topicSubscriptionQueue,
  )

  await node.start()
  (await node.mountRelay()).isOkOr:
    error "failed to mount relay", error = error
    quit(1)

  node.peerManager.start()

  (await wakuDiscv5.start()).isOkOr:
    error "failed to start discv5", error = error
    quit(1)

  # wait for a minimum of peers to be connected, otherwise messages wont be gossiped
  while true:
    let numConnectedPeers = node.peerManager.switch.peerStore[ConnectionBook].book
      .values()
      .countIt(it == Connected)
    if numConnectedPeers >= 6:
      notice "publisher is ready", connectedPeers = numConnectedPeers, required = 6
      break
    notice "waiting to be ready", connectedPeers = numConnectedPeers, required = 6
    await sleepAsync(5000)

  # Make sure it matches the publisher. Use default value
  # see spec: https://rfc.vac.dev/spec/23/
  let pubSubTopic = PubsubTopic("/waku/2/rs/0/0")

  # any content topic can be chosen
  let contentTopic = ContentTopic("/examples/1/pubsub-example/proto")

  notice "publisher service started"
  while true:
    let text = "hi there i'm a publisher"
    let message = WakuMessage(
      payload: toBytes(text), # content of the message
      contentTopic: contentTopic, # content topic to publish to
      ephemeral: true, # tell store nodes to not store it
      timestamp: now(),
    ) # current timestamp

    let res = await node.publish(some(pubSubTopic), message)

    if res.isOk:
      notice "published message",
        text = text,
        timestamp = message.timestamp,
        psTopic = pubSubTopic,
        contentTopic = contentTopic
    else:
      error "failed to publish message", error = res.error

    await sleepAsync(5000)

when isMainModule:
  let rng = crypto.newRng()
  asyncSpawn setupAndPublish(rng)
  runForever()
