{.used.}

import std/[options, net, sequtils, sets, strutils, uri]
import chronos, metrics, testutils/unittests, presto, presto/client as presto_client
import brokers/broker_context
import logos_delivery
import
  logos_delivery/api/conf/logos_delivery_conf,
  logos_delivery/messaging/rest_api/client as messaging_rest_client,
  logos_delivery/messaging/delivery_service/send_service/send_service,
  logos_delivery/waku/[
    common/base64,
    waku_core,
    waku_enr,
    waku_metadata,
    waku_node,
    waku_relay/protocol,
    waku_store/common,
    waku_filter_v2/client,
    node/peer_manager,
    factory/validator_signed,
  ],
  logos_delivery/waku/rest_api/endpoint/client,
  logos_delivery/waku/rest_api/endpoint/relay/types,
  logos_delivery/waku/rest_api/endpoint/relay/client as relay_rest_client,
  logos_delivery/waku/rest_api/endpoint/store/client as store_rest_client
import tools/confutils/cli_args
import ../testlib/[rest_requests, testasync, wakucore, wakunode, wakunodeconf]

## Validates the layer-selection invariant of `LogosDelivery.new(LogosDeliveryNodeConf)`:
## `messagingClient` (and `reliableChannelManager`) are instantiated only for the
## entry layers that call for them.
##
##   kernel    -> waku only
##   messaging -> waku + messagingClient
##   channels  -> waku + messagingClient + reliableChannelManager

proc nodeConf(entryLayer: EntryLayer, rest = false): LogosDeliveryNodeConf =
  defaultTestNodeConf(entryLayer = entryLayer, rest = rest)

proc restClientFor(node: LogosDelivery): RestClientRef =
  let boundPort = node.waku.restServer.httpServer.address.port
  newRestHttpClient(initTAddress(parseIpAddress("127.0.0.1"), boundPort))

proc signedOutcomeCount(outcome: string): float64 =
  ## Read by name: `value(labelValues = ...)` ignores the label selector in metrics 0.2.1.
  try:
    return logos_delivery_msg_validator_signed_outcome.valueByName(
      "logos_delivery_msg_validator_signed_outcome_total", [outcome]
    )
  except ValueError:
    return 0.0

suite "LogosDelivery - entry layer selection":
  asyncTest "kernel: waku only, no messaging / channels":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(nodeConf(EntryLayer.kernel))).valueOr:
        raiseAssert error
    check:
      not node.waku.isNil()
      node.messagingClient.isNil()
      node.reliableChannelManager.isNil()
      node.ensureMessaging().isErr()
      node.ensureChannels().isErr()
    (await node.stop()).isOkOr:
      raiseAssert "stop failed: " & error

  asyncTest "messaging: waku + messagingClient, no channels":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(nodeConf(EntryLayer.messaging))).valueOr:
        raiseAssert error
    check:
      not node.waku.isNil()
      not node.messagingClient.isNil()
      node.reliableChannelManager.isNil()
      node.ensureMessaging().isOk()
      node.ensureChannels().isErr()
    (await node.stop()).isOkOr:
      raiseAssert "stop failed: " & error

  asyncTest "channels: full stack":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(nodeConf(EntryLayer.channels))).valueOr:
        raiseAssert error
    check:
      not node.waku.isNil()
      not node.messagingClient.isNil()
      not node.reliableChannelManager.isNil()
      node.ensureMessaging().isOk()
      node.ensureChannels().isOk()
    (await node.stop()).isOkOr:
      raiseAssert "stop failed: " & error

  asyncTest "messaging: the messaging flags reach the send service":
    var conf = nodeConf(EntryLayer.messaging)
    conf.messaging.anonymityLevel = Opt.some(AnonymityLevel.Preferred)
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
    check:
      node.messagingClient.sendService.maxDeliveryTime ==
        maxDeliveryTime(AnonymityLevel.Preferred)
    (await node.stop()).isOkOr:
      raiseAssert "stop failed: " & error

  asyncTest "messaging + rest: messaging REST endpoints are installed and working":
    ## entry-layer=messaging, mode=Core, rest=true -> `start` mounts the messaging
    ## REST endpoints; they respond over HTTP.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(nodeConf(EntryLayer.messaging, rest = true))).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error

    check not node.messagingClient.isNil()

    let client = restClientFor(node)

    # A command endpoint and an observability endpoint both respond -> the
    # handlers were installed onto the kernel router.
    let subResp =
      await client.messagingPostSubscriptionsV1(@["/test/1/entry-layer/proto"])
    check subResp.status == 200

    let sendEventsResp = await client.messagingGetSendEventsV1()
    check sendEventsResp.status == 200

    (await node.stop()).isOkOr:
      raiseAssert "stop failed: " & error

  asyncTest "kernel + rest: messaging REST endpoints are NOT installed":
    ## Gating check: a kernel-only node still starts a REST server, but the
    ## messaging endpoints must be absent (no messaging client to mount them).
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(nodeConf(EntryLayer.kernel, rest = true))).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error

    check node.messagingClient.isNil()

    let client = restClientFor(node)
    let subResp =
      await client.messagingPostSubscriptionsV1(@["/test/1/entry-layer/proto"])
    check:
      subResp.status == 404
      subResp.data.contains("--entry-layer")

    let withQuery =
      await issueRequest(node.waku.restServer.getAddress("/messaging?x=1"))
    check:
      withQuery.status == 404
      withQuery.data.contains("--entry-layer")

    # presto rejects a path with more than 64 segments
    let tooDeep = await issueRequest(
      node.waku.restServer.getAddress("/messaging" & "/x".repeat(70))
    )
    check tooDeep.status == 400

    (await node.stop()).isOkOr:
      raiseAssert "stop failed: " & error

suite "LogosDelivery - relay REST API":
  asyncTest "the configured shard and content topic are served without a REST subscription":
    let
      contentTopic = ContentTopic("/toychat/2/huilong/proto")
      configuredShard = $RelayShard(clusterId: TestClusterId, shardId: 0)
      contentTopicShard = $RelayShard(clusterId: TestClusterId, shardId: 3)

    var conf = nodeConf(EntryLayer.kernel, rest = true)
    conf.kernel.numShardsInNetwork = 8
    conf.kernel.shards = @[0'u16]
    conf.kernel.contentTopics = @[contentTopic]

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error
    defer:
      (await node.stop()).isOkOr:
        raiseAssert "stop failed: " & error

    var publisher: WakuNode
    lockNewGlobalBrokerContext:
      publisher = newTestWakuNode(generateSecp256k1Key())
      publisher.mountMetadata(TestClusterId, toSeq(0'u16 ..< 8'u16)).isOkOr:
        raiseAssert error
      (await publisher.mountRelay()).isOkOr:
        raiseAssert error
      await publisher.start()
    defer:
      await publisher.stop()

    proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      discard

    for shard in [configuredShard, contentTopicShard]:
      publisher.subscribe((kind: PubsubSub, topic: shard), dummyHandler).isOkOr:
        raiseAssert error

    await node.waku.node.connectToNodes(@[publisher.peerInfo.toRemotePeerInfo()])
    checkUntilTimeout:
      publisher.hasGossipsubPeer(configuredShard, node.waku.node.peerId)
      publisher.hasGossipsubPeer(contentTopicShard, node.waku.node.peerId)

    let
      shardMessage = fakeWakuMessage("on the configured shard")
      contentTopicMessage =
        fakeWakuMessage("on the content topic", contentTopic = contentTopic)
    (await publisher.publish(Opt.some(configuredShard), shardMessage)).isOkOr:
      raiseAssert error
    (await publisher.publish(Opt.some(contentTopicShard), contentTopicMessage)).isOkOr:
      raiseAssert error

    let client = restClientFor(node)
    let shardMessages = await client.waitForRelayMessages(configuredShard, 1)
    let contentTopicMessages = await client.waitForRelayAutoMessages(contentTopic, 1)
    check:
      shardMessages.mapIt(it.payload) == @[base64.encode(shardMessage.payload)]
      contentTopicMessages.mapIt(it.payload) ==
        @[base64.encode(contentTopicMessage.payload)]

  asyncTest "a shard outside the configured shards is archived and takes a publish, while reading its messages answers 404":
    # TODO: logos-delivery#4455
    let
      configuredShard = $RelayShard(clusterId: TestClusterId, shardId: 1)
      otherShard = $RelayShard(clusterId: TestClusterId, shardId: 0)

    var conf = nodeConf(EntryLayer.kernel, rest = true)
    conf.kernel.numShardsInNetwork = 8
    conf.kernel.shards = @[1'u16]
    conf.kernel.store = Opt.some(true)
    conf.kernel.storeMessageDbUrl = "none"

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error
    defer:
      (await node.stop()).isOkOr:
        raiseAssert "stop failed: " & error

    var publisher: WakuNode
    lockNewGlobalBrokerContext:
      publisher = newTestWakuNode(generateSecp256k1Key())
      publisher.mountMetadata(TestClusterId, toSeq(0'u16 ..< 8'u16)).isOkOr:
        raiseAssert error
      (await publisher.mountRelay()).isOkOr:
        raiseAssert error
      await publisher.start()
    defer:
      await publisher.stop()

    proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      discard

    var otherShardReceived: seq[WakuMessage]
    proc otherShardHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      otherShardReceived.add(msg)

    publisher.subscribe((kind: PubsubSub, topic: configuredShard), dummyHandler).isOkOr:
      raiseAssert error
    publisher.subscribe((kind: PubsubSub, topic: otherShard), otherShardHandler).isOkOr:
      raiseAssert error

    await node.waku.node.connectToNodes(@[publisher.peerInfo.toRemotePeerInfo()])
    checkUntilTimeout:
      publisher.hasGossipsubPeer(configuredShard, node.waku.node.peerId)
      publisher.hasGossipsubPeer(otherShard, node.waku.node.peerId)

    let
      configuredShardMessage = fakeWakuMessage("on the configured shard")
      otherShardMessage = fakeWakuMessage("on another shard")
      restMessage = fakeWakuMessage("published over REST")
    (await publisher.publish(Opt.some(configuredShard), configuredShardMessage)).isOkOr:
      raiseAssert error
    (await publisher.publish(Opt.some(otherShard), otherShardMessage)).isOkOr:
      raiseAssert error

    let client = restClientFor(node)
    let otherShardHash =
      computeMessageHash(otherShard, otherShardMessage).toRestStringWakuMessageHash()
    checkUntilTimeout:
      (await client.getStoreMessagesV3(pubsubTopic = encodeUrl(otherShard))).data.messages.mapIt(
        it.messageHash
      ) == @[otherShardHash]

    let configuredShardMessages = await client.waitForRelayMessages(configuredShard, 1)
    let otherShardRead = await issueRequest(
      node.waku.restServer.getAddress("/relay/v1/messages/" & encodeUrl(otherShard))
    )
    let otherShardPublish =
      await client.relayPostMessagesV1(otherShard, toRelayWakuMessage(restMessage))
    check:
      configuredShardMessages.mapIt(it.payload) ==
        @[base64.encode(configuredShardMessage.payload)]
      otherShardRead.status == 404
      otherShardPublish.status == 200
    checkUntilTimeout:
      restMessage.payload in otherShardReceived.mapIt(it.payload)

suite "LogosDelivery - configured shards":
  asyncTest "under static sharding the relay is on the configured shard only, and a publish to another shard answers 400":
    # TODO: logos-delivery#4455
    let
      configuredShard = $RelayShard(clusterId: TestClusterId, shardId: 1)
      otherShard = $RelayShard(clusterId: TestClusterId, shardId: 0)

    var conf = nodeConf(EntryLayer.kernel, rest = true)
    conf.kernel.numShardsInNetwork = 0
    conf.kernel.shards = @[1'u16]

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error
    defer:
      (await node.stop()).isOkOr:
        raiseAssert "stop failed: " & error

    let otherShardPublish = await restClientFor(node).relayPostMessagesV1(
      otherShard, toRelayWakuMessage(fakeWakuMessage("published over REST"))
    )
    check:
      node.waku.node.wakuRelay.subscribedTopics() == @[configuredShard]
      otherShardPublish.status == 400

  asyncTest "under static sharding without REST the relay is on no shard, while the ENR and metadata report the configured shard":
    # TODO: logos-delivery#3446
    var conf = nodeConf(EntryLayer.kernel)
    conf.kernel.numShardsInNetwork = 0
    conf.kernel.shards = @[1'u16]

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error
    defer:
      (await node.stop()).isOkOr:
        raiseAssert "stop failed: " & error

    var peer: WakuNode
    lockNewGlobalBrokerContext:
      peer = newTestWakuNode(generateSecp256k1Key())
      peer.mountMetadata(TestClusterId, @[]).isOkOr:
        raiseAssert error
      await peer.start()
    defer:
      await peer.stop()

    let conn = (
      await peer.peerManager.dialPeer(
        node.waku.node.peerInfo.toRemotePeerInfo(), WakuMetadataCodec
      )
    ).valueOr:
      raiseAssert "could not dial metadata"
    let metadata = (await peer.wakuMetadata.request(conn)).valueOr:
      raiseAssert error

    check:
      node.waku.node.wakuRelay.subscribedTopics().len == 0
      toSeq(0'u16 ..< 8'u16).filterIt(
        node.waku.node.enr.containsShard(TestClusterId, it)
      ) == @[1'u16]
      metadata.shards == @[1'u32]

  asyncTest "under static sharding without REST the node is no relay peer on the configured shard, and a peer's message there is neither archived nor pushed to a filter subscriber":
    # TODO: logos-delivery#3446
    let
      configuredShard = $RelayShard(clusterId: TestClusterId, shardId: 1)
      contentTopic = ContentTopic("/toychat/2/huilong/proto")

    var conf = nodeConf(EntryLayer.kernel)
    conf.kernel.numShardsInNetwork = 0
    conf.kernel.shards = @[1'u16]
    conf.kernel.store = Opt.some(true)
    conf.kernel.storeMessageDbUrl = "none"

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error
    defer:
      (await node.stop()).isOkOr:
        raiseAssert "stop failed: " & error

    var publisher: WakuNode
    lockNewGlobalBrokerContext:
      publisher = newTestWakuNode(generateSecp256k1Key())
      publisher.mountMetadata(TestClusterId, @[1'u16]).isOkOr:
        raiseAssert error
      (await publisher.mountRelay()).isOkOr:
        raiseAssert error
      publisher.mountStoreClient()
      await publisher.start()
    defer:
      await publisher.stop()

    var receiver: WakuNode
    lockNewGlobalBrokerContext:
      receiver = newTestWakuNode(generateSecp256k1Key())
      receiver.mountMetadata(TestClusterId, @[1'u16]).isOkOr:
        raiseAssert error
      (await receiver.mountRelay()).isOkOr:
        raiseAssert error
      await receiver.start()
    defer:
      await receiver.stop()

    var subscriber: WakuNode
    lockNewGlobalBrokerContext:
      subscriber = newTestWakuNode(generateSecp256k1Key())
      subscriber.mountMetadata(TestClusterId, @[]).isOkOr:
        raiseAssert error
      await subscriber.mountFilterClient()
      await subscriber.start()
    defer:
      await subscriber.stop()

    proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      discard

    var received: seq[WakuMessage]
    proc receiverHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      received.add(msg)

    var pushed: seq[WakuMessage]
    proc pushHandler(
        pubsubTopic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, closure, gcsafe.} =
      pushed.add(msg)

    publisher.subscribe((kind: PubsubSub, topic: configuredShard), dummyHandler).isOkOr:
      raiseAssert error
    receiver.subscribe((kind: PubsubSub, topic: configuredShard), receiverHandler).isOkOr:
      raiseAssert error
    subscriber.wakuFilterClient.registerPushHandler(pushHandler)
    let filterSubscribe = await subscriber.filterSubscribe(
      Opt.some(configuredShard),
      @[contentTopic],
      node.waku.node.peerInfo.toRemotePeerInfo(),
    )

    await node.waku.node.connectToNodes(@[publisher.peerInfo.toRemotePeerInfo()])
    await receiver.connectToNodes(@[publisher.peerInfo.toRemotePeerInfo()])
    checkUntilTimeout:
      publisher.hasGossipsubPeer(configuredShard, receiver.peerId)

    let message =
      fakeWakuMessage("on the configured shard", contentTopic = contentTopic)
    (await publisher.publish(Opt.some(configuredShard), message)).isOkOr:
      raiseAssert error
    checkUntilTimeout:
      message.payload in received.mapIt(it.payload)

    let stored = (
      await publisher.query(
        StoreQueryRequest(includeData: true, pubsubTopic: Opt.some(configuredShard)),
        node.waku.node.peerInfo.toRemotePeerInfo(),
      )
    ).valueOr:
      raiseAssert $error
    check:
      filterSubscribe.isOk()
      not publisher.hasGossipsubPeer(configuredShard, node.waku.node.peerId)
      stored.messages.len == 0
      pushed.len == 0

  asyncTest "under static sharding without REST the messaging entry layer leaves the relay on no shard":
    # TODO: logos-delivery#3446
    var conf = nodeConf(EntryLayer.messaging)
    conf.kernel.numShardsInNetwork = 0
    conf.kernel.shards = @[1'u16]

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error
    defer:
      (await node.stop()).isOkOr:
        raiseAssert "stop failed: " & error

    check:
      node.waku.node.wakuRelay.subscribedTopics().len == 0

  asyncTest "an unsigned message on a protected shard outside the configured shards is archived":
    # TODO: logos-delivery#4455
    let protectedShard = $RelayShard(clusterId: TestClusterId, shardId: 0)

    var conf = nodeConf(EntryLayer.kernel, rest = true)
    conf.kernel.numShardsInNetwork = 8
    conf.kernel.shards = @[1'u16]
    conf.kernel.protectedShards = @[
      ProtectedShard.parseCmdArg(
        "0:0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
      )
    ]
    conf.kernel.store = Opt.some(true)
    conf.kernel.storeMessageDbUrl = "none"

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error
    defer:
      (await node.stop()).isOkOr:
        raiseAssert "stop failed: " & error

    var publisher: WakuNode
    lockNewGlobalBrokerContext:
      publisher = newTestWakuNode(generateSecp256k1Key())
      publisher.mountMetadata(TestClusterId, toSeq(0'u16 ..< 8'u16)).isOkOr:
        raiseAssert error
      (await publisher.mountRelay()).isOkOr:
        raiseAssert error
      await publisher.start()
    defer:
      await publisher.stop()

    proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      discard

    publisher.subscribe((kind: PubsubSub, topic: protectedShard), dummyHandler).isOkOr:
      raiseAssert error

    await node.waku.node.connectToNodes(@[publisher.peerInfo.toRemotePeerInfo()])
    checkUntilTimeout:
      publisher.hasGossipsubPeer(protectedShard, node.waku.node.peerId)

    let unsignedMessage = fakeWakuMessage("unsigned")
    (await publisher.publish(Opt.some(protectedShard), unsignedMessage)).isOkOr:
      raiseAssert error

    let client = restClientFor(node)
    let unsignedHash =
      computeMessageHash(protectedShard, unsignedMessage).toRestStringWakuMessageHash()
    checkUntilTimeout:
      (await client.getStoreMessagesV3(pubsubTopic = encodeUrl(protectedShard))).data.messages.mapIt(
        it.messageHash
      ) == @[unsignedHash]

  asyncTest "a protected shard among the configured shards rejects an unsigned message":
    # TODO: logos-delivery#4455
    let
      protectedShard = $RelayShard(clusterId: TestClusterId, shardId: 0)
      unprotectedShard = $RelayShard(clusterId: TestClusterId, shardId: 1)

    var conf = nodeConf(EntryLayer.kernel, rest = true)
    conf.kernel.numShardsInNetwork = 8
    conf.kernel.shards = @[0'u16, 1'u16]
    conf.kernel.protectedShards = @[
      ProtectedShard.parseCmdArg(
        "0:0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
      )
    ]
    conf.kernel.store = Opt.some(true)
    conf.kernel.storeMessageDbUrl = "none"

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error
    defer:
      (await node.stop()).isOkOr:
        raiseAssert "stop failed: " & error

    var publisher: WakuNode
    lockNewGlobalBrokerContext:
      publisher = newTestWakuNode(generateSecp256k1Key())
      publisher.mountMetadata(TestClusterId, toSeq(0'u16 ..< 8'u16)).isOkOr:
        raiseAssert error
      (await publisher.mountRelay()).isOkOr:
        raiseAssert error
      await publisher.start()
    defer:
      await publisher.stop()

    proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      discard

    for shard in [protectedShard, unprotectedShard]:
      publisher.subscribe((kind: PubsubSub, topic: shard), dummyHandler).isOkOr:
        raiseAssert error

    await node.waku.node.connectToNodes(@[publisher.peerInfo.toRemotePeerInfo()])
    checkUntilTimeout:
      publisher.hasGossipsubPeer(protectedShard, node.waku.node.peerId)
      publisher.hasGossipsubPeer(unprotectedShard, node.waku.node.peerId)

    let
      unsignedMessage = fakeWakuMessage("unsigned")
      laterMessage = fakeWakuMessage("published after the unsigned message")
      rejectsBefore = signedOutcomeCount("Reject")
    (await publisher.publish(Opt.some(protectedShard), unsignedMessage)).isOkOr:
      raiseAssert error
    (await publisher.publish(Opt.some(unprotectedShard), laterMessage)).isOkOr:
      raiseAssert error

    let client = restClientFor(node)
    let laterHash =
      computeMessageHash(unprotectedShard, laterMessage).toRestStringWakuMessageHash()
    checkUntilTimeout:
      (await client.getStoreMessagesV3(pubsubTopic = encodeUrl(unprotectedShard))).data.messages.mapIt(
        it.messageHash
      ) == @[laterHash]
      signedOutcomeCount("Reject") >= rejectsBefore + 1

    let protectedShardMessages =
      await client.getStoreMessagesV3(pubsubTopic = encodeUrl(protectedShard))
    check:
      protectedShardMessages.data.messages.len == 0

  asyncTest "without discv5 the ENR lists the configured shard while metadata reports every shard":
    # TODO: logos-delivery#4455
    var conf = nodeConf(EntryLayer.kernel)
    conf.kernel.numShardsInNetwork = 8
    conf.kernel.shards = @[1'u16]
    conf.kernel.discv5Discovery = Opt.some(false)

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error
    defer:
      (await node.stop()).isOkOr:
        raiseAssert "stop failed: " & error

    var peer: WakuNode
    lockNewGlobalBrokerContext:
      peer = newTestWakuNode(generateSecp256k1Key())
      peer.mountMetadata(TestClusterId, @[]).isOkOr:
        raiseAssert error
      await peer.start()
    defer:
      await peer.stop()

    let conn = (
      await peer.peerManager.dialPeer(
        node.waku.node.peerInfo.toRemotePeerInfo(), WakuMetadataCodec
      )
    ).valueOr:
      raiseAssert "could not dial metadata"
    let metadata = (await peer.wakuMetadata.request(conn)).valueOr:
      raiseAssert error

    check:
      toSeq(0'u16 ..< 8'u16).filterIt(
        node.waku.node.enr.containsShard(TestClusterId, it)
      ) == @[1'u16]
      metadata.shards.toHashSet() == toSeq(0'u32 ..< 8'u32).toHashSet()

  asyncTest "with discv5 the ENR lists every shard":
    # TODO: logos-delivery#4455
    var conf = nodeConf(EntryLayer.kernel)
    conf.kernel.numShardsInNetwork = 8
    conf.kernel.shards = @[1'u16]
    conf.kernel.discv5Discovery = Opt.some(true)

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "start failed: " & error
    defer:
      (await node.stop()).isOkOr:
        raiseAssert "stop failed: " & error

    checkUntilTimeout:
      toSeq(0'u16 ..< 8'u16).allIt(node.waku.node.enr.containsShard(TestClusterId, it))
