{.used.}

import std/[options, net, sequtils, strutils]
import chronos, testutils/unittests, presto, presto/client as presto_client
import brokers/broker_context
import logos_delivery
import
  logos_delivery/api/conf/logos_delivery_conf,
  logos_delivery/messaging/rest_api/client as messaging_rest_client,
  logos_delivery/waku/[common/base64, waku_core, waku_node],
  logos_delivery/waku/rest_api/endpoint/client
import tools/confutils/cli_args
import ../testlib/[rest_requests, testasync, wakucore, wakunode, wakunodeconf]

## Validates the layer-selection invariant of `LogosDelivery.new(WakuNodeConf)`:
## `messagingClient` (and `reliableChannelManager`) are instantiated only for the
## entry layers that call for them.
##
##   kernel    -> waku only
##   messaging -> waku + messagingClient
##   channels  -> waku + messagingClient + reliableChannelManager

proc nodeConf(entryLayer: EntryLayer, rest = false): WakuNodeConf =
  defaultTestWakuNodeConf(entryLayer = entryLayer, rest = rest)

proc restClientFor(node: LogosDelivery): RestClientRef =
  let boundPort = node.waku.restServer.httpServer.address.port
  newRestHttpClient(initTAddress(parseIpAddress("127.0.0.1"), boundPort))

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
    conf.numShardsInNetwork = 8
    conf.shards = @[0'u16]
    conf.contentTopics = @[contentTopic]

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
