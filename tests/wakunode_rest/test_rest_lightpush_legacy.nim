{.used.}

import
  std/sequtils,
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
    waku_lightpush_legacy/common,
    rest_api/endpoint/server,
    rest_api/endpoint/client,
    rest_api/endpoint/responses,
    rest_api/endpoint/legacy_lightpush/types,
    rest_api/endpoint/legacy_lightpush/handlers as lightpush_rest_interface,
    rest_api/endpoint/legacy_lightpush/client as lightpush_rest_client,
    waku_relay,
    common/rate_limit/setting,
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

type RestLightPushTest = object
  serviceNode: WakuNode
  pushNode: WakuNode
  consumerNode: WakuNode
  restServer: WakuRestServerRef
  client: RestClientRef

proc init(
    T: type RestLightPushTest, rateLimit: RateLimitSetting = (0, 0.millis)
): Future[T] {.async.} =
  var testSetup = RestLightPushTest()
  testSetup.serviceNode = testWakuNode()
  testSetup.pushNode = testWakuNode()
  testSetup.consumerNode = testWakuNode()

  await allFutures(
    testSetup.serviceNode.start(),
    testSetup.pushNode.start(),
    testSetup.consumerNode.start(),
  )

  (await testSetup.consumerNode.mountRelay()).isOkOr:
    assert false, "Failed to mount relay"
  (await testSetup.serviceNode.mountRelay()).isOkOr:
    assert false, "Failed to mount relay"
  check (await testSetup.serviceNode.mountLegacyLightPush(rateLimit)).isOk()
  testSetup.pushNode.mountLegacyLightPushClient()

  testSetup.serviceNode.peerManager.addServicePeer(
    testSetup.consumerNode.peerInfo.toRemotePeerInfo(), WakuRelayCodec
  )

  await testSetup.serviceNode.connectToNodes(
    @[testSetup.consumerNode.peerInfo.toRemotePeerInfo()]
  )

  testSetup.pushNode.peerManager.addServicePeer(
    testSetup.serviceNode.peerInfo.toRemotePeerInfo(), WakuLegacyLightPushCodec
  )

  var restPort = Port(0)
  let restAddress = parseIpAddress("127.0.0.1")
  testSetup.restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
  restPort = testSetup.restServer.httpServer.address.port
    # update with bound port for client use

  installLightPushRequestHandler(testSetup.restServer.router, testSetup.pushNode)

  testSetup.restServer.start()

  testSetup.client = newRestHttpClient(initTAddress(restAddress, restPort))

  return testSetup

proc shutdown(self: RestLightPushTest) {.async.} =
  await self.restServer.stop()
  await self.restServer.closeWait()
  await allFutures(self.serviceNode.stop(), self.pushNode.stop())

suite "Waku v2 Rest API - lightpush":
  asyncTest "Push message with proof":
    let restLightPushTest = await RestLightPushTest.init()

    let message: RelayWakuMessage = fakeWakuMessage(
        contentTopic = DefaultContentTopic,
        payload = toBytes("TEST-1"),
        proof = toBytes("proof-test"),
      )
      .toRelayWakuMessage()

    check message.proof.isSome()

    let requestBody =
      PushRequest(pubsubTopic: some(DefaultPubsubTopic), message: message)

    let response = await restLightPushTest.client.sendPushRequest(body = requestBody)

    ## Validate that the push request failed because the node is not
    ## connected to other node but, doesn't fail because of not properly
    ## handling the proof message attribute within the REST request.
    check:
      response.data == "Failed to request a message push: not_published_to_any_peer"

  asyncTest "Push message request":
    # Given
    let restLightPushTest = await RestLightPushTest.init()
    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    restLightPushTest.consumerNode.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler
    ).isOkOr:
      assert false, "Failed to subscribe to topic"

    restLightPushTest.serviceNode.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler
    ).isOkOr:
      assert false, "Failed to subscribe to topic"
    require:
      toSeq(restLightPushTest.serviceNode.wakuRelay.subscribedTopics).len == 1

    # When
    let message: RelayWakuMessage = fakeWakuMessage(
        contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")
      )
      .toRelayWakuMessage()

    let requestBody =
      PushRequest(pubsubTopic: some(DefaultPubsubTopic), message: message)
    let response = await restLightPushTest.client.sendPushRequest(requestBody)

    echo "response", $response

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT

    await restLightPushTest.shutdown()

  asyncTest "Push message bad-request":
    # Given
    let restLightPushTest = await RestLightPushTest.init()
    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    restLightPushTest.serviceNode.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler
    ).isOkOr:
      assert false, "Failed to subscribe to topic"
    require:
      toSeq(restLightPushTest.serviceNode.wakuRelay.subscribedTopics).len == 1

    # When
    let badMessage1: RelayWakuMessage = fakeWakuMessage(
        contentTopic = DefaultContentTopic, payload = toBytes("")
      )
      .toRelayWakuMessage()
    let badRequestBody1 =
      PushRequest(pubsubTopic: some(DefaultPubsubTopic), message: badMessage1)

    let badMessage2: RelayWakuMessage =
      fakeWakuMessage(contentTopic = "", payload = toBytes("Sthg")).toRelayWakuMessage()
    let badRequestBody2 =
      PushRequest(pubsubTopic: some(DefaultPubsubTopic), message: badMessage2)

    let badRequestBody3 =
      PushRequest(pubsubTopic: none(PubsubTopic), message: badMessage2)

    var response: RestResponse[string]

    response = await restLightPushTest.client.sendPushRequest(badRequestBody1)

    echo "response", $response

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.startsWith("Invalid content body")

    # when
    response = await restLightPushTest.client.sendPushRequest(badRequestBody2)

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.startsWith("Invalid content body")

    # when
    response = await restLightPushTest.client.sendPushRequest(badRequestBody3)

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.startsWith("Invalid content body")

    await restLightPushTest.shutdown()

  asyncTest "Request rate limit push message":
    # Given
    let budgetCap = 3
    let tokenPeriod = 500.millis
    let restLightPushTest = await RestLightPushTest.init((budgetCap, tokenPeriod))
    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    restLightPushTest.consumerNode.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler
    ).isOkOr:
      assert false, "Failed to subscribe to topic"

    restLightPushTest.serviceNode.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler
    ).isOkOr:
      assert false, "Failed to subscribe to topic"
    require:
      toSeq(restLightPushTest.serviceNode.wakuRelay.subscribedTopics).len == 1

    # When
    let pushProc = proc() {.async.} =
      let message: RelayWakuMessage = fakeWakuMessage(
          contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")
        )
        .toRelayWakuMessage()

      let requestBody =
        PushRequest(pubsubTopic: some(DefaultPubsubTopic), message: message)
      let response = await restLightPushTest.client.sendPushRequest(requestBody)

      echo "response", $response

      # Then
      check:
        response.status == 200
        $response.contentType == $MIMETYPE_TEXT

    let pushRejectedProc = proc() {.async.} =
      let message: RelayWakuMessage = fakeWakuMessage(
          contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")
        )
        .toRelayWakuMessage()

      let requestBody =
        PushRequest(pubsubTopic: some(DefaultPubsubTopic), message: message)
      let response = await restLightPushTest.client.sendPushRequest(requestBody)

      echo "response", $response

      # Then
      check:
        response.status == 429

    await pushProc()
    await pushProc()
    await pushProc()
    await pushRejectedProc()

    await sleepAsync(tokenPeriod)

    for runCnt in 0 ..< 3:
      let startTime = Moment.now()
      for sendCnt in 0 ..< budgetCap:
        await pushProc()

      let endTime = Moment.now()
      let elapsed: Duration = (endTime - startTime)
      await sleepAsync(tokenPeriod - elapsed + 10.millis)

    await restLightPushTest.shutdown()
