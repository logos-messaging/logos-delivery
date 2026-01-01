import
  std/[tables, sequtils],
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
    waku_relay,
    waku_filter_v2/client,
  ]

# careful if running pub and sub in the same machine
const wakuPort = 50000

const clusterId = 1
const shardId = @[0'u16]

const
  FilterPeer =
    "/ip4/64.225.80.192/tcp/30303/p2p/16Uiu2HAmNaeL4p3WEYzC9mgXBmBWSgWjPHRvatZTXnp8Jgv3iKsb"
  FilterPubsubTopic = PubsubTopic("/waku/2/rs/1/0")
  FilterContentTopic = ContentTopic("/examples/1/light-pubsub-example/proto")

proc messagePushHandler(
    pubsubTopic: PubsubTopic, message: WakuMessage
) {.async, gcsafe.} =
  let payloadStr = string.fromBytes(message.payload)
  notice "message received",
    payload = payloadStr,
    pubsubTopic = pubsubTopic,
    contentTopic = message.contentTopic,
    timestamp = message.timestamp

proc setupAndSubscribe(rng: ref HmacDrbgContext) {.async.} =
  # use notice to filter all waku messaging
  setupLog(logging.LogLevel.NOTICE, logging.LogFormat.TEXT)

  notice "starting subscriber", wakuPort = wakuPort
  let
    nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
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

  var builder = WakuNodeBuilder.init()
  builder.withNodeKey(nodeKey)
  builder.withRecord(record)
  builder.withNetworkConfigurationDetails(ip, Port(wakuPort)).tryGet()
  let node = builder.build().tryGet()

  node.mountMetadata(clusterId, shardId).expect(
    "failed to mount waku metadata protocol"
  )
  await node.mountFilterClient()

  await node.start()

  node.peerManager.start()

  node.wakuFilterClient.registerPushHandler(messagePushHandler)

  let filterPeer = parsePeerInfo(FilterPeer).get()

  while true:
    notice "maintaining subscription"
    # First use filter-ping to check if we have an active subscription
    if (await node.wakuFilterClient.ping(filterPeer)).isErr():
      # No subscription found. Let's subscribe.
      notice "no subscription found. Sending subscribe request"

      (
        await node.wakuFilterClient.subscribe(
          filterPeer, FilterPubsubTopic, @[FilterContentTopic]
        )
      ).isOkOr:
        notice "subscribe request failed. Quitting.", error = error
        break
      notice "subscribe request successful."
    else:
      notice "subscription found."

    await sleepAsync(60.seconds) # Subscription maintenance interval

when isMainModule:
  let rng = crypto.newRng()
  asyncSpawn setupAndSubscribe(rng)
  runForever()
