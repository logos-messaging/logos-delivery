import results
{.used.}

import
  std/[json, sequtils, strutils],
  chronos/timer,
  stew/byteutils,
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/crypto/crypto
import
  logos_delivery/waku/[
    common/base64,
    rest_api/message_cache,
    waku_core,
    waku_core/topics/sharding,
    waku_node,
    node/peer_manager,
    rest_api/endpoint/server,
    rest_api/endpoint/client,
    rest_api/endpoint/responses,
    rest_api/endpoint/filter/types,
    rest_api/endpoint/filter/handlers as filter_rest_interface,
    rest_api/endpoint/filter/client as filter_rest_client,
    waku_relay,
    waku_filter_v2/subscriptions,
    waku_filter_v2/common,
    waku_filter_v2/protocol,
    rest_api/endpoint/relay/handlers as relay_rest_interface,
    rest_api/endpoint/relay/client as relay_rest_client,
  ],
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../testlib/futures,
  ../testlib/rest_requests

proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  return newTestWakuNode(privkey, bindIp, port, Opt.some(extIp), Opt.some(port))

type RestFilterTest = object
  serviceNode: WakuNode
  subscriberNode: WakuNode
  restServer: WakuRestServerRef
  restServerForService: WakuRestServerRef
  messageCache: MessageCache
  client: RestClientRef
  clientTwdServiceNode: RestClientRef

proc init(T: type RestFilterTest, autoShardCount = 0'u32): Future[T] {.async.} =
  ## A zero shard count leaves both nodes on static sharding, the CLI default.
  var testSetup = RestFilterTest()
  testSetup.serviceNode = testWakuNode()
  testSetup.subscriberNode = testWakuNode()

  await allFutures(testSetup.serviceNode.start(), testSetup.subscriberNode.start())

  (await testSetup.serviceNode.mountRelay()).isOkOr:
    assert false, "Failed to mount relay: " & $error

  if autoShardCount > 0:
    for node in [testSetup.serviceNode, testSetup.subscriberNode]:
      node.mountAutoSharding(DefaultClusterId, autoShardCount).isOkOr:
        assert false, "Failed to mount auto sharding: " & error

  await testSetup.serviceNode.mountFilter(messageCacheTTL = 1.seconds)
  await testSetup.subscriberNode.mountFilterClient()

  testSetup.subscriberNode.peerManager.addServicePeer(
    testSetup.serviceNode.peerInfo.toRemotePeerInfo(), WakuFilterSubscribeCodec
  )

  var restPort = Port(0)
  let restAddress = parseIpAddress("127.0.0.1")
  testSetup.restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
  restPort = testSetup.restServer.httpServer.address.port
    # update with bound port for client use

  var restPort2 = Port(0)
  testSetup.restServerForService =
    WakuRestServerRef.init(restAddress, restPort2).tryGet()
  restPort2 = testSetup.restServerForService.httpServer.address.port
    # update with bound port for client use

  # through this one we will see if messages are pushed according to our content topic sub
  testSetup.messageCache = MessageCache.init()
  installFilterRestApiHandlers(
    testSetup.restServer.router, testSetup.subscriberNode, testSetup.messageCache
  )

  let topicCache = MessageCache.init()
  installRelayApiHandlers(
    testSetup.restServerForService.router, testSetup.serviceNode, topicCache
  )

  testSetup.restServer.start()
  testSetup.restServerForService.start()

  testSetup.client = newRestHttpClient(initTAddress(restAddress, restPort))
  testSetup.clientTwdServiceNode =
    newRestHttpClient(initTAddress(restAddress, restPort2))

  return testSetup

proc shutdown(self: RestFilterTest) {.async.} =
  await self.restServer.stop()
  await self.restServer.closeWait()
  await self.restServerForService.stop()
  await self.restServerForService.closeWait()
  await allFutures(self.serviceNode.stop(), self.subscriberNode.stop())

proc waitForFilterMessages(
    client: RestClientRef, contentTopic: ContentTopic, count: int
): Future[seq[FilterWakuMessage]] {.async.} =
  ## Each GET clears the cache, so the messages of every poll are collected.
  var messages: seq[FilterWakuMessage]
  let deadline = Moment.now() + FUTURE_TIMEOUT_MEDIUM
  while messages.len < count and Moment.now() < deadline:
    let response = await client.filterGetMessagesV1(contentTopic)
    messages.add(response.data)
    await sleepAsync(50.milliseconds)
  return messages

suite "Waku v2 Rest API - Filter V2":
  asyncTest "Subscribe a node to an array of topics - POST /filter/v2/subscriptions":
    # Given
    let restFilterTest = await RestFilterTest.init()
    let subPeerId = restFilterTest.subscriberNode.peerInfo.toRemotePeerInfo().peerId

    # When
    let contentFilters =
      @[DefaultContentTopic, ContentTopic("2"), ContentTopic("3"), ContentTopic("4")]

    let requestBody = FilterSubscribeRequest(
      requestId: "1234",
      contentFilters: contentFilters,
      pubsubTopic: Opt.some(DefaultPubsubTopic),
    )
    let response = await restFilterTest.client.filterPostSubscriptions(requestBody)

    let subscribedPeer1 = restFilterTest.serviceNode.wakuFilter.subscriptions.findSubscribedPeers(
      DefaultPubsubTopic, DefaultContentTopic
    )
    let subscribedPeer2 = restFilterTest.serviceNode.wakuFilter.subscriptions.findSubscribedPeers(
      DefaultPubsubTopic, "2"
    )
    let subscribedPeer3 = restFilterTest.serviceNode.wakuFilter.subscriptions.findSubscribedPeers(
      DefaultPubsubTopic, "3"
    )
    let subscribedPeer4 = restFilterTest.serviceNode.wakuFilter.subscriptions.findSubscribedPeers(
      DefaultPubsubTopic, "4"
    )

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.requestId == "1234"
      subscribedPeer1.len() == 1
      subPeerId in subscribedPeer1
      subPeerId in subscribedPeer2
      subPeerId in subscribedPeer3
      subPeerId in subscribedPeer4

    # When - error case
    let badRequestBody = FilterSubscribeRequest(
      requestId: "4567", contentFilters: @[], pubsubTopic: Opt.none(string)
    )
    let badRequestResp =
      await restFilterTest.client.filterPostSubscriptions(badRequestBody)

    check:
      badRequestResp.status == 400
      $badRequestResp.contentType == $MIMETYPE_JSON
      badRequestResp.data.requestId == "unknown"
      # badRequestResp.data.statusDesc == "*********"
      badRequestResp.data.statusDesc.startsWith("BAD_REQUEST: Failed to decode request")

    await restFilterTest.shutdown()

  asyncTest "Unsubscribe a node from an array of topics - DELETE /filter/v2/subscriptions":
    # Given
    let
      restFilterTest = await RestFilterTest.init()
      subPeerId = restFilterTest.subscriberNode.peerInfo.toRemotePeerInfo().peerId

    # When
    var requestBody = FilterSubscribeRequest(
      requestId: "1234",
      contentFilters:
        @[ContentTopic("1"), ContentTopic("2"), ContentTopic("3"), ContentTopic("4")],
      pubsubTopic: Opt.some(DefaultPubsubTopic),
    )
    discard await restFilterTest.client.filterPostSubscriptions(requestBody)

    let contentFilters = @[
      ContentTopic("1"),
      ContentTopic("2"),
      ContentTopic("3"), # ,ContentTopic("4") # Keep this subscription for check
    ]

    let requestBodyUnsub = FilterUnsubscribeRequest(
      requestId: "4321",
      contentFilters: contentFilters,
      pubsubTopic: Opt.some(DefaultPubsubTopic),
    )
    let response =
      await restFilterTest.client.filterDeleteSubscriptions(requestBodyUnsub)

    let subscribedPeer1 = restFilterTest.serviceNode.wakuFilter.subscriptions.findSubscribedPeers(
      DefaultPubsubTopic, DefaultContentTopic
    )
    let subscribedPeer2 = restFilterTest.serviceNode.wakuFilter.subscriptions.findSubscribedPeers(
      DefaultPubsubTopic, "2"
    )
    let subscribedPeer3 = restFilterTest.serviceNode.wakuFilter.subscriptions.findSubscribedPeers(
      DefaultPubsubTopic, "3"
    )
    let subscribedPeer4 = restFilterTest.serviceNode.wakuFilter.subscriptions.findSubscribedPeers(
      DefaultPubsubTopic, "4"
    )

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.requestId == "4321"
      subscribedPeer1.len() == 0
      subPeerId notin subscribedPeer1
      subPeerId notin subscribedPeer2
      subPeerId notin subscribedPeer3
      subscribedPeer4.len() == 1
      subPeerId in subscribedPeer4

    # When - error case
    let requestBodyUnsubAll = FilterUnsubscribeAllRequest(requestId: "2143")
    let responseUnsubAll =
      await restFilterTest.client.filterDeleteAllSubscriptions(requestBodyUnsubAll)

    let subscribedPeer = restFilterTest.serviceNode.wakuFilter.subscriptions.findSubscribedPeers(
      DefaultPubsubTopic, "4"
    )

    check:
      responseUnsubAll.status == 200
      $responseUnsubAll.contentType == $MIMETYPE_JSON
      responseUnsubAll.data.requestId == "2143"
      subscribedPeer.len() == 0

    await restFilterTest.shutdown()

  asyncTest "ping subscribed node - GET /filter/v2/subscriptions/{requestId}":
    # Given
    let
      restFilterTest = await RestFilterTest.init()
      subPeerId = restFilterTest.subscriberNode.peerInfo.toRemotePeerInfo().peerId

    # When
    var requestBody = FilterSubscribeRequest(
      requestId: "1234",
      contentFilters: @[ContentTopic("1")],
      pubsubTopic: Opt.some(DefaultPubsubTopic),
    )
    discard await restFilterTest.client.filterPostSubscriptions(requestBody)

    let pingResponse = await restFilterTest.client.filterSubscriberPing("9999")

    # Then
    check:
      pingResponse.status == 200
      $pingResponse.contentType == $MIMETYPE_JSON
      pingResponse.data.requestId == "9999"
      pingResponse.data.statusDesc == "OK"

    # When - error case
    let requestBodyUnsubAll = FilterUnsubscribeAllRequest(requestId: "9988")
    discard
      await restFilterTest.client.filterDeleteAllSubscriptions(requestBodyUnsubAll)

    let pingResponseFail = await restFilterTest.client.filterSubscriberPing("9977")

    # Then
    check:
      pingResponseFail.status == 404 # NOT_FOUND
      $pingResponseFail.contentType == $MIMETYPE_JSON
      pingResponseFail.data.requestId == "9977"
      pingResponseFail.data.statusDesc == "NOT_FOUND: peer has no subscriptions"

    await restFilterTest.shutdown()

  asyncTest "push filtered message":
    # Given
    let
      restFilterTest = await RestFilterTest.init()
      subPeerId = restFilterTest.subscriberNode.peerInfo.toRemotePeerInfo().peerId

    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    restFilterTest.messageCache.pubsubSubscribe(DefaultPubsubTopic)

    restFilterTest.serviceNode.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler
    ).isOkOr:
      assert false, "Failed to subscribe to topic: " & $error

    # When
    var requestBody = FilterSubscribeRequest(
      requestId: "1234",
      contentFilters: @[ContentTopic("1")],
      pubsubTopic: Opt.some(DefaultPubsubTopic),
    )
    discard await restFilterTest.client.filterPostSubscriptions(requestBody)

    let pingResponse = await restFilterTest.client.filterSubscriberPing("9999")

    # Then
    check:
      pingResponse.status == 200
      $pingResponse.contentType == $MIMETYPE_JSON
      pingResponse.data.requestId == "9999"
      pingResponse.data.statusDesc == "OK"

    # When - message push
    let testMessage = WakuMessage(
      payload: "TEST-PAYLOAD-MUST-RECEIVE".toBytes(),
      contentTopic: "1",
      timestamp: int64(2022),
      meta: "test-meta".toBytes(),
    )

    let postMsgResponse = await restFilterTest.clientTwdServiceNode.relayPostMessagesV1(
      DefaultPubsubTopic, toRelayWakuMessage(testMessage)
    )
    # Then
    let messages = restFilterTest.messageCache.getAutoMessages("1").tryGet()

    check:
      postMsgResponse.status == 200
      $postMsgResponse.contentType == $MIMETYPE_TEXT
      postMsgResponse.data == "OK"
      messages == @[testMessage]

    await restFilterTest.shutdown()

  asyncTest "duplicate message push to filter subscriber":
    # setup filter service and client node
    let restFilterTest = await RestFilterTest.init()
    let subPeerId = restFilterTest.subscriberNode.peerInfo.toRemotePeerInfo().peerId
    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    restFilterTest.serviceNode.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler
    ).isOkOr:
      assert false, "Failed to subscribe to topic: " & $error

    let requestBody = FilterSubscribeRequest(
      requestId: "1001",
      contentFilters: @[DefaultContentTopic],
      pubsubTopic: Opt.some(DefaultPubsubTopic),
    )
    let response = await restFilterTest.client.filterPostSubscriptions(requestBody)

    # subscribe fiter service
    let subscribedPeer = restFilterTest.serviceNode.wakuFilter.subscriptions.findSubscribedPeers(
      DefaultPubsubTopic, DefaultContentTopic
    )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.requestId == "1001"
      subscribedPeer.len() == 1

    # ping subscriber node
    restFilterTest.messageCache.pubsubSubscribe(DefaultPubsubTopic)

    let pingResponse = await restFilterTest.client.filterSubscriberPing("1002")

    check:
      pingResponse.status == 200
      pingResponse.data.requestId == "1002"
      pingResponse.data.statusDesc == "OK"

    # first - message push from service node to subscriber client
    let testMessage = WakuMessage(
      payload: "TEST-PAYLOAD-MUST-RECEIVE".toBytes(),
      contentTopic: DefaultContentTopic,
      timestamp: int64(2022),
      meta: "test-meta".toBytes(),
    )

    let postMsgResponse1 = await restFilterTest.clientTwdServiceNode.relayPostMessagesV1(
      DefaultPubsubTopic, toRelayWakuMessage(testMessage)
    )

    # check messages received client side or not
    let messages1 = await restFilterTest.client.filterGetMessagesV1(DefaultContentTopic)

    check:
      postMsgResponse1.status == 200
      $postMsgResponse1.contentType == $MIMETYPE_TEXT
      postMsgResponse1.data == "OK"
      len(messages1.data) == 1

    # second - message push from service node to subscriber client
    let postMsgResponse2 = await restFilterTest.clientTwdServiceNode.relayPostMessagesV1(
      DefaultPubsubTopic, toRelayWakuMessage(testMessage)
    )

    # check message received client side or not
    let messages2 = await restFilterTest.client.filterGetMessagesV1(DefaultContentTopic)

    check:
      postMsgResponse2.status == 200
      $postMsgResponse2.contentType == $MIMETYPE_TEXT
      postMsgResponse2.data == "OK"
      len(messages2.data) == 0

    await restFilterTest.shutdown()

  asyncTest "duplicate message push to filter subscriber ( sleep in between )":
    # setup filter service and client node
    let restFilterTest = await RestFilterTest.init()
    let subPeerId = restFilterTest.subscriberNode.peerInfo.toRemotePeerInfo().peerId
    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    restFilterTest.serviceNode.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler
    ).isOkOr:
      assert false, "Failed to subscribe to topic: " & $error

    let requestBody = FilterSubscribeRequest(
      requestId: "1001",
      contentFilters: @[DefaultContentTopic],
      pubsubTopic: Opt.some(DefaultPubsubTopic),
    )
    let response = await restFilterTest.client.filterPostSubscriptions(requestBody)

    # subscribe fiter service
    let subscribedPeer = restFilterTest.serviceNode.wakuFilter.subscriptions.findSubscribedPeers(
      DefaultPubsubTopic, DefaultContentTopic
    )

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.requestId == "1001"
      subscribedPeer.len() == 1

    # ping subscriber node
    restFilterTest.messageCache.pubsubSubscribe(DefaultPubsubTopic)

    let pingResponse = await restFilterTest.client.filterSubscriberPing("1002")

    check:
      pingResponse.status == 200
      pingResponse.data.requestId == "1002"
      pingResponse.data.statusDesc == "OK"

    # first - message push from service node to subscriber client
    let testMessage = WakuMessage(
      payload: "TEST-PAYLOAD-MUST-RECEIVE".toBytes(),
      contentTopic: DefaultContentTopic,
      timestamp: int64(2022),
      meta: "test-meta".toBytes(),
    )

    let postMsgResponse1 = await restFilterTest.clientTwdServiceNode.relayPostMessagesV1(
      DefaultPubsubTopic, toRelayWakuMessage(testMessage)
    )

    # check messages received client side or not
    let messages1 = await restFilterTest.client.filterGetMessagesV1(DefaultContentTopic)

    check:
      postMsgResponse1.status == 200
      $postMsgResponse1.contentType == $MIMETYPE_TEXT
      postMsgResponse1.data == "OK"
      len(messages1.data) == 1

    # Pause execution for 1 seconds to test TimeCache functionality of service node
    await sleepAsync(1.seconds)

    # second - message push from service node to subscriber client
    let postMsgResponse2 = await restFilterTest.clientTwdServiceNode.relayPostMessagesV1(
      DefaultPubsubTopic, toRelayWakuMessage(testMessage)
    )

    # check message received client side or not
    let messages2 = await restFilterTest.client.filterGetMessagesV1(DefaultContentTopic)

    check:
      postMsgResponse2.status == 200
      $postMsgResponse2.contentType == $MIMETYPE_TEXT
      postMsgResponse2.data == "OK"
      len(messages2.data) == 1
    await restFilterTest.shutdown()

  asyncTest "A pushed message is read back field by field - GET /filter/v2/messages/{contentTopic}":
    # Given a subscriber served by a relaying service node
    let restFilterTest = await RestFilterTest.init()
    defer:
      await restFilterTest.shutdown()

    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    restFilterTest.serviceNode.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler
    ).isOkOr:
      assert false, "Failed to subscribe to topic: " & $error

    restFilterTest.messageCache.pubsubSubscribe(DefaultPubsubTopic)

    let subscribeResponse = await restFilterTest.client.filterPostSubscriptions(
      FilterSubscribeRequest(
        requestId: "1234",
        contentFilters: @[DefaultContentTopic],
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      )
    )
    check subscribeResponse.status == 200

    # When a message with every optional field set is published on the service
    let testMessage = WakuMessage(
      payload: "TEST-PAYLOAD-MUST-RECEIVE".toBytes(),
      contentTopic: DefaultContentTopic,
      version: 10,
      timestamp: int64(1700000000000000000),
      meta: "test-meta".toBytes(),
      ephemeral: true,
    )

    let postMsgResponse = await restFilterTest.clientTwdServiceNode.relayPostMessagesV1(
      DefaultPubsubTopic, toRelayWakuMessage(testMessage)
    )
    check postMsgResponse.status == 200

    # Then the subscriber reads every field back
    let messages =
      await restFilterTest.client.waitForFilterMessages(DefaultContentTopic, 1)

    check:
      messages.mapIt(it.payload) == @[base64.encode(testMessage.payload)]
      messages.mapIt(it.contentTopic) == @[Opt.some(testMessage.contentTopic)]
      messages.mapIt(it.version) == @[Opt.some(Natural(testMessage.version))]
      messages.mapIt(it.timestamp) == @[Opt.some(testMessage.timestamp)]
      messages.mapIt(it.meta) == @[Opt.some(base64.encode(testMessage.meta))]
      messages.mapIt(it.ephemeral) == @[Opt.some(testMessage.ephemeral)]

  asyncTest "Subscribe and unsubscribe without a pubsub topic under autosharding - POST and DELETE /filter/v2/subscriptions":
    # Given a subscriber whose node derives the shard from the content topic
    let restFilterTest = await RestFilterTest.init(autoShardCount = 8'u32)
    defer:
      await restFilterTest.shutdown()

    let
      subPeerId = restFilterTest.subscriberNode.peerInfo.toRemotePeerInfo().peerId
      subscriptions = restFilterTest.serviceNode.wakuFilter.subscriptions
      derivedShard = restFilterTest.subscriberNode.wakuAutoSharding
        .get()
        .getShard(DefaultContentTopic).valueOr:
          raiseAssert "Failed to derive the shard: " & error

    # When it subscribes without a pubsubTopic
    let subscribeResponse = await restFilterTest.client.filterPostSubscriptions(
      FilterSubscribeRequest(
        requestId: "1234",
        contentFilters: @[DefaultContentTopic],
        pubsubTopic: Opt.none(string),
      )
    )

    # Then the criterion lands on the derived shard
    check:
      subscribeResponse.status == 200
      subscribeResponse.data.statusDesc == "OK"
      subPeerId in subscriptions.findSubscribedPeers($derivedShard, DefaultContentTopic)

    # When it unsubscribes without a pubsubTopic
    let unsubscribeResponse = await restFilterTest.client.filterDeleteSubscriptions(
      FilterUnsubscribeRequest(
        requestId: "4321",
        contentFilters: @[DefaultContentTopic],
        pubsubTopic: Opt.none(string),
      )
    )

    # Then the criterion leaves the derived shard
    check:
      unsubscribeResponse.status == 200
      unsubscribeResponse.data.statusDesc == "OK"
      subscriptions.findSubscribedPeers($derivedShard, DefaultContentTopic).len() == 0

  asyncTest "Subscribe and unsubscribe without a pubsub topic under static sharding - POST and DELETE /filter/v2/subscriptions":
    # Given a subscriber whose node cannot derive a shard
    let restFilterTest = await RestFilterTest.init()
    defer:
      await restFilterTest.shutdown()

    # When it subscribes without a pubsubTopic
    let subscribeResponse = await restFilterTest.client.filterPostSubscriptions(
      FilterSubscribeRequest(
        requestId: "1234",
        contentFilters: @[DefaultContentTopic],
        pubsubTopic: Opt.none(string),
      )
    )

    # Then the request is answered UNKNOWN and no criterion is registered
    check:
      subscribeResponse.status == 200
      subscribeResponse.data.statusDesc == "UNKNOWN"
      restFilterTest.serviceNode.wakuFilter.subscriptions
        .findSubscribedPeers(DefaultPubsubTopic, DefaultContentTopic)
        .len() == 0

    # And the content topic is in the message cache, so a read answers with an empty list
    let messages = await restFilterTest.client.filterGetMessagesV1(DefaultContentTopic)

    check:
      messages.status == 200
      messages.data.len() == 0

    # When it unsubscribes without a pubsubTopic
    let unsubscribeResponse = await restFilterTest.client.filterDeleteSubscriptions(
      FilterUnsubscribeRequest(
        requestId: "4321",
        contentFilters: @[DefaultContentTopic],
        pubsubTopic: Opt.none(string),
      )
    )

    check:
      unsubscribeResponse.status == 200
      unsubscribeResponse.data.statusDesc == "UNKNOWN"

  asyncTest "Subscribe, update and unsubscribe with an invalid body - POST, PUT and DELETE /filter/v2/subscriptions":
    # Given a subscriber with a service peer, so only the body decides the response
    let restFilterTest = await RestFilterTest.init()
    defer:
      await restFilterTest.shutdown()

    let jsonHeader: seq[HttpHeaderTuple] = @[("Content-Type", "application/json")]

    # When the body does not decode into a subscription request
    let invalidBodies = [
      $ %*{"contentFilters": [DefaultContentTopic], "pubsubTopic": DefaultPubsubTopic},
      $ %*{
        "requestId": 1234,
        "contentFilters": [DefaultContentTopic],
        "pubsubTopic": DefaultPubsubTopic,
      },
      $ %*{"requestId": "1234", "pubsubTopic": DefaultPubsubTopic},
      $ %*{
        "requestId": "1234",
        "contentFilters": DefaultContentTopic,
        "pubsubTopic": DefaultPubsubTopic,
      },
      $ %*{
        "requestId": "1234",
        "contentFilters": [DefaultContentTopic],
        "pubsubTopic": [DefaultPubsubTopic],
      },
      $ %*{
        "requestId": "1234",
        "contentFilters": [{"topic": DefaultContentTopic}],
        "pubsubTopic": DefaultPubsubTopic,
      },
      $ %*{
        "requestId": "1234",
        "contentFilters": [DefaultContentTopic],
        "pubsubTopic": DefaultPubsubTopic,
        "extraField": "extraValue",
      },
    ]

    # Then both endpoints reading it reject the request
    for body in invalidBodies:
      for meth in [MethodPost, MethodDelete]:
        let response = await issueRequest(
          restFilterTest.restServer.getAddress(ROUTE_FILTER_SUBSCRIPTIONS),
          meth,
          jsonHeader,
          body,
        )
        let data = parseJson(response.data)
        check:
          response.status == 400
          data["requestId"].getStr() == "unknown"
          data["statusDesc"].getStr().startsWith(
            "BAD_REQUEST: Failed to decode request"
          )

    # And so does PUT, which shares the subscribe handler
    let putResponse = await issueRequest(
      restFilterTest.restServer.getAddress(ROUTE_FILTER_SUBSCRIPTIONS),
      MethodPut,
      jsonHeader,
      invalidBodies[0],
    )
    let putData = parseJson(putResponse.data)

    check:
      putResponse.status == 400
      putData["requestId"].getStr() == "unknown"
      putData["statusDesc"].getStr().startsWith("BAD_REQUEST: Failed to decode request")

    # When the body does not decode into an unsubscribe-all request
    let invalidAllBodies =
      ["{}", $ %*{"requestId": 1234}, $ %*{"requestId": "1234", "extra": "extraValue"}]

    # Then the request is rejected the same way
    for body in invalidAllBodies:
      let response = await issueRequest(
        restFilterTest.restServer.getAddress(ROUTE_FILTER_ALL_SUBSCRIPTIONS),
        MethodDelete,
        jsonHeader,
        body,
      )
      let data = parseJson(response.data)
      check:
        response.status == 400
        data["requestId"].getStr() == "unknown"
        data["statusDesc"].getStr().startsWith("BAD_REQUEST: Failed to decode request")

  asyncTest "Add, remove and exceed subscription criteria - PUT and DELETE /filter/v2/subscriptions":
    # Given a subscription to one content topic
    let restFilterTest = await RestFilterTest.init()
    defer:
      await restFilterTest.shutdown()

    let
      subPeerId = restFilterTest.subscriberNode.peerInfo.toRemotePeerInfo().peerId
      subscriptions = restFilterTest.serviceNode.wakuFilter.subscriptions

    let postResponse = await restFilterTest.client.filterPostSubscriptions(
      FilterSubscribeRequest(
        requestId: "1234",
        contentFilters: @[ContentTopic("1")],
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      )
    )
    check postResponse.status == 200

    # When a PUT names a second content topic
    let putResponse = await restFilterTest.client.filterPutSubscriptions(
      FilterSubscribeRequest(
        requestId: "2345",
        contentFilters: @[ContentTopic("2")],
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      )
    )

    # Then the service holds both
    check:
      putResponse.status == 200
      putResponse.data.statusDesc == "OK"
      subPeerId in subscriptions.findSubscribedPeers(DefaultPubsubTopic, "1")
      subPeerId in subscriptions.findSubscribedPeers(DefaultPubsubTopic, "2")

    # Given a second peer holding a criterion the subscriber does not
    let otherNode = testWakuNode()
    await otherNode.start()
    defer:
      await otherNode.stop()

    await otherNode.mountFilterClient()
    let servicePeer = restFilterTest.serviceNode.peerInfo.toRemotePeerInfo()
    (
      await otherNode.filterSubscribe(
        Opt.some(DefaultPubsubTopic), @[ContentTopic("3")], servicePeer
      )
    ).isOkOr:
      assert false, "Failed to subscribe the second peer: " & $error

    let otherPeerId = otherNode.peerInfo.toRemotePeerInfo().peerId

    # When a DELETE names that criterion
    let otherResponse = await restFilterTest.client.filterDeleteSubscriptions(
      FilterUnsubscribeRequest(
        requestId: "3456",
        contentFilters: @[ContentTopic("3")],
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      )
    )

    # Then it is answered OK and nothing is removed
    check:
      otherResponse.status == 200
      otherResponse.data.statusDesc == "OK"
      otherPeerId in subscriptions.findSubscribedPeers(DefaultPubsubTopic, "3")
      subPeerId in subscriptions.findSubscribedPeers(DefaultPubsubTopic, "1")
      subPeerId in subscriptions.findSubscribedPeers(DefaultPubsubTopic, "2")

    # When a DELETE names a criterion no peer holds
    let unknownResponse = await restFilterTest.client.filterDeleteSubscriptions(
      FilterUnsubscribeRequest(
        requestId: "4567",
        contentFilters: @[ContentTopic("4")],
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      )
    )

    # Then it is answered "peer has no subscriptions" and the peer keeps its criteria
    check:
      unknownResponse.status == 404
      unknownResponse.data.statusDesc == "NOT_FOUND: peer has no subscriptions"
      subPeerId in subscriptions.findSubscribedPeers(DefaultPubsubTopic, "1")
      subPeerId in subscriptions.findSubscribedPeers(DefaultPubsubTopic, "2")

    # When a request names more content topics than the maximum
    let tooManyTopics = toSeq(0 .. MaxContentTopicsPerRequest).mapIt(ContentTopic($it))

    let tooManyPostResponse = await restFilterTest.client.filterPostSubscriptions(
      FilterSubscribeRequest(
        requestId: "5678",
        contentFilters: tooManyTopics,
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      )
    )
    let tooManyDeleteResponse = await restFilterTest.client.filterDeleteSubscriptions(
      FilterUnsubscribeRequest(
        requestId: "6789",
        contentFilters: tooManyTopics,
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      )
    )

    # Then both carry the service's own reason
    check:
      tooManyPostResponse.status == 400
      tooManyPostResponse.data.statusDesc ==
        "BAD_REQUEST: exceeds maximum content topics: 100"
      tooManyDeleteResponse.status == 400
      tooManyDeleteResponse.data.statusDesc ==
        "BAD_REQUEST: exceeds maximum content topics: 100"

    # When one subscribed content topic is deleted
    let deleteResponse = await restFilterTest.client.filterDeleteSubscriptions(
      FilterUnsubscribeRequest(
        requestId: "7890",
        contentFilters: @[ContentTopic("1")],
        pubsubTopic: Opt.some(DefaultPubsubTopic),
      )
    )

    # Then a read of it is refused
    let messagesAfterDelete =
      await issueRequest(restFilterTest.restServer.getAddress("/filter/v2/messages/1"))

    check:
      deleteResponse.status == 200
      messagesAfterDelete.status == 400
      messagesAfterDelete.data == "Not subscribed to topic: 1"

    # When the remaining subscription is deleted as a whole
    let deleteAllResponse = await restFilterTest.client.filterDeleteAllSubscriptions(
      FilterUnsubscribeAllRequest(requestId: "8901")
    )

    # Then a read of the content topic it held is refused too
    let messagesAfterDeleteAll =
      await issueRequest(restFilterTest.restServer.getAddress("/filter/v2/messages/2"))

    check:
      deleteAllResponse.status == 200
      messagesAfterDeleteAll.status == 400
      messagesAfterDeleteAll.data == "Not subscribed to topic: 2"
