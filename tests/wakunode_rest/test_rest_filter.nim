{.used.}

import
  chronos/timer,
  stew/byteutils,
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/crypto/crypto
import
  waku/[
    rest_api/message_cache,
    waku_core,
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
    rest_api/endpoint/relay/handlers as relay_rest_interface,
    rest_api/endpoint/relay/client as relay_rest_client,
  ],
  ../testlib/wakucore,
  ../testlib/wakunode

proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  return newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))

type RestFilterTest = object
  serviceNode: WakuNode
  subscriberNode: WakuNode
  restServer: WakuRestServerRef
  restServerForService: WakuRestServerRef
  messageCache: MessageCache
  client: RestClientRef
  clientTwdServiceNode: RestClientRef

proc init(T: type RestFilterTest): Future[T] {.async.} =
  var testSetup = RestFilterTest()
  testSetup.serviceNode = testWakuNode()
  testSetup.subscriberNode = testWakuNode()

  await allFutures(testSetup.serviceNode.start(), testSetup.subscriberNode.start())

  (await testSetup.serviceNode.mountRelay()).isOkOr:
    assert false, "Failed to mount relay: " & $error

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
      pubsubTopic: some(DefaultPubsubTopic),
    )
    let response = await restFilterTest.client.filterPostSubscriptions(requestBody)

    echo "response", $response

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
      requestId: "4567", contentFilters: @[], pubsubTopic: none(string)
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
      pubsubTopic: some(DefaultPubsubTopic),
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
      pubsubTopic: some(DefaultPubsubTopic),
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
      pubsubTopic: some(DefaultPubsubTopic),
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
      pubsubTopic: some(DefaultPubsubTopic),
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
      pubsubTopic: some(DefaultPubsubTopic),
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
      pubsubTopic: some(DefaultPubsubTopic),
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
