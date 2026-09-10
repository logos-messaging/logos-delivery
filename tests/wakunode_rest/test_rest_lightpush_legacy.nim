import results
{.used.}

import
  std/[json, sequtils, sets, strutils],
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
    waku_node,
    node/peer_manager,
    waku_lightpush_legacy/common,
    rest_api/endpoint/server,
    rest_api/endpoint/client,
    rest_api/endpoint/responses,
    rest_api/endpoint/legacy_lightpush/types,
    rest_api/endpoint/legacy_lightpush/handlers as lightpush_rest_interface,
    rest_api/endpoint/legacy_lightpush/client as lightpush_rest_client,
    rest_api/endpoint/relay/handlers as relay_rest_interface,
    rest_api/endpoint/relay/client as relay_rest_client,
    waku_relay,
    common/rate_limit/setting,
  ],
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../testlib/futures,
  ../testlib/rest_requests,
  ../resources/payloads

proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  return newTestWakuNode(privkey, bindIp, port, Opt.some(extIp), Opt.some(port))

type RestLightPushTest = object
  serviceNode: WakuNode
  pushNode: WakuNode
  consumerNode: WakuNode
  restServer: WakuRestServerRef
  restServerForConsumer: WakuRestServerRef
  client: RestClientRef
  clientTwdConsumerNode: RestClientRef

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

  var consumerRestPort = Port(0)
  testSetup.restServerForConsumer =
    WakuRestServerRef.init(restAddress, consumerRestPort).tryGet()
  consumerRestPort = testSetup.restServerForConsumer.httpServer.address.port
    # update with bound port for client use

  installLightPushRequestHandler(testSetup.restServer.router, testSetup.pushNode)
  installRelayApiHandlers(
    testSetup.restServerForConsumer.router, testSetup.consumerNode, MessageCache.init()
  )

  testSetup.restServer.start()
  testSetup.restServerForConsumer.start()

  testSetup.client = newRestHttpClient(initTAddress(restAddress, restPort))
  testSetup.clientTwdConsumerNode =
    newRestHttpClient(initTAddress(restAddress, consumerRestPort))

  return testSetup

proc shutdown(self: RestLightPushTest) {.async.} =
  await self.restServer.stop()
  await self.restServer.closeWait()
  await self.restServerForConsumer.stop()
  await self.restServerForConsumer.closeWait()
  await allFutures(
    self.serviceNode.stop(), self.pushNode.stop(), self.consumerNode.stop()
  )

proc waitForTopicPeer(
    node: WakuNode, topic: PubsubTopic, peer: PeerId, timeout = FUTURE_TIMEOUT_LONG
) {.async.} =
  ## Waits until node's gossipsub has learnt that peer subscribes to topic.
  let deadline = Moment.now() + timeout
  while Moment.now() < deadline:
    for p in node.wakuRelay.gossipsub.getOrDefault(topic):
      if p.peerId == peer:
        return
    await sleepAsync(10.milliseconds)
  raiseAssert $peer & " never announced a subscription to " & topic

proc waitForRelayMessages(
    client: RestClientRef,
    pubsubTopic: PubsubTopic,
    count: int,
    timeout = FUTURE_TIMEOUT_MEDIUM,
): Future[seq[RelayWakuMessage]] {.async.} =
  ## Each GET clears the cache, so the messages of every poll are collected.
  var messages: seq[RelayWakuMessage]
  let deadline = Moment.now() + timeout
  while messages.len < count and Moment.now() < deadline:
    let response = await client.relayGetMessagesV1(pubsubTopic)
    messages.add(response.data)
    await sleepAsync(50.milliseconds)
  return messages

suite "Waku v2 Rest API - legacy lightpush":
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
      PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: message)

    let response = await restLightPushTest.client.sendPushRequest(body = requestBody)

    ## Validate that the push request failed because the node is not
    ## connected to other node but, doesn't fail because of not properly
    ## handling the proof message attribute within the REST request.
    check:
      response.status == 503
      response.data == "Failed to request a message push: not_published_to_any_peer"

    await restLightPushTest.shutdown()

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
    check:
      toSeq(restLightPushTest.serviceNode.wakuRelay.subscribedTopics).len == 1

    # When
    let message: RelayWakuMessage = fakeWakuMessage(
        contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")
      )
      .toRelayWakuMessage()

    let requestBody =
      PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: message)
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
    check:
      toSeq(restLightPushTest.serviceNode.wakuRelay.subscribedTopics).len == 1

    # When
    let badMessage1: RelayWakuMessage = fakeWakuMessage(
        contentTopic = DefaultContentTopic, payload = toBytes("")
      )
      .toRelayWakuMessage()
    let badRequestBody1 =
      PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: badMessage1)

    let badMessage2: RelayWakuMessage =
      fakeWakuMessage(contentTopic = "", payload = toBytes("Sthg")).toRelayWakuMessage()
    let badRequestBody2 =
      PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: badMessage2)

    let badRequestBody3 =
      PushRequest(pubsubTopic: Opt.none(PubsubTopic), message: badMessage2)

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
    check:
      toSeq(restLightPushTest.serviceNode.wakuRelay.subscribedTopics).len == 1

    # When
    let pushProc = proc() {.async.} =
      let message: RelayWakuMessage = fakeWakuMessage(
          contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")
        )
        .toRelayWakuMessage()

      let requestBody =
        PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: message)
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
        PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: message)
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

  asyncTest "A pushed message is read back on the relay peer of the service node - POST /lightpush/v1/message, GET /relay/v1/messages/{topic}":
    # Given the consumer node subscribed over REST and known to the service node
    let restLightPushTest = await RestLightPushTest.init()
    defer:
      await restLightPushTest.shutdown()

    let subscribeResponse = await restLightPushTest.clientTwdConsumerNode.relayPostSubscriptionsV1(
      @[DefaultPubsubTopic]
    )
    check subscribeResponse.status == 200
    await restLightPushTest.serviceNode.waitForTopicPeer(
      DefaultPubsubTopic, restLightPushTest.consumerNode.peerInfo.peerId
    )

    # When a message with every optional field set is pushed
    let sent = RelayWakuMessage(
      payload: base64.encode(EMOJI),
      contentTopic: Opt.some(ContentTopic("/test/1/wäku-lightpush/proto")),
      version: Opt.some(Natural(10)),
      timestamp: Opt.some(now()),
      meta: Opt.some(base64.encode("test-meta")),
      ephemeral: Opt.some(true),
    )
    let pushResponse = await restLightPushTest.client.sendPushRequest(
      PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: sent)
    )
    check:
      pushResponse.status == 200
      pushResponse.data == "OK"

    # Then the relay peer reads it back over REST with every field unchanged
    let received = await restLightPushTest.clientTwdConsumerNode.waitForRelayMessages(
      DefaultPubsubTopic, 1
    )
    check:
      received.mapIt(it.payload) == @[sent.payload]
      received.mapIt(it.contentTopic) == @[sent.contentTopic]
      received.mapIt(it.version) == @[sent.version]
      received.mapIt(it.timestamp) == @[sent.timestamp]
      received.mapIt(it.meta) == @[sent.meta]
      received.mapIt(it.ephemeral) == @[sent.ephemeral]

  asyncTest "Push a message with an invalid body - POST /lightpush/v1/message":
    let restLightPushTest = await RestLightPushTest.init()
    defer:
      await restLightPushTest.shutdown()

    let
      path = "/lightpush/v1/message"
      jsonHeader: seq[HttpHeaderTuple] = @[("Content-Type", "application/json")]
      payload = string(base64.encode("TEST-PAYLOAD"))
      validMessage =
        "{\"payload\": \"" & payload & "\", \"contentTopic\": \"" & DefaultContentTopic &
        "\"}"

    # When the body does not decode into a push request
    let invalidBodies = [
      $ %*{
        "pubsubTopic": DefaultPubsubTopic,
        "message": {"payload": "", "contentTopic": DefaultContentTopic},
      },
      $ %*{
        "pubsubTopic": DefaultPubsubTopic,
        "message": {"payload": payload, "contentTopic": ""},
      },
      $ %*{
        "pubsubTopic": [DefaultPubsubTopic],
        "message": {"payload": payload, "contentTopic": DefaultContentTopic},
      },
      $ %*{"pubsubTopic": DefaultPubsubTopic},
      "{\"pubsubTopic\": \"" & DefaultPubsubTopic & "\", \"message\": " & validMessage &
        ", \"message\": " & validMessage & "}",
      "{\"pubsubTopic\": \"" & DefaultPubsubTopic & "\", \"message\": " & validMessage &
        ", \"extraField\": \"extraValue\"}",
    ]

    # Then each is rejected as an invalid content body
    for body in invalidBodies:
      let response = await issueRequest(
        restLightPushTest.restServer.getAddress(path), MethodPost, jsonHeader, body
      )
      check:
        response.status == 400
        response.data.startsWith("Invalid content body, could not decode: ")

    # When a field that must be base64 is not
    let notBase64Bodies = [
      $ %*{
        "pubsubTopic": DefaultPubsubTopic,
        "message": {"payload": "Hello World!", "contentTopic": DefaultContentTopic},
      },
      $ %*{
        "pubsubTopic": DefaultPubsubTopic,
        "message": {
          "payload": payload,
          "contentTopic": DefaultContentTopic,
          "meta": "Hello World!",
        },
      },
    ]

    # Then the message the handler could not build is rejected
    for body in notBase64Bodies:
      let response = await issueRequest(
        restLightPushTest.restServer.getAddress(path), MethodPost, jsonHeader, body
      )
      check:
        response.status == 400
        response.data == "Invalid message: Incorrect base64 string"
