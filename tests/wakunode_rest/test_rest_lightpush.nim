import results
{.used.}

import
  std/[json, sequtils, strformat, strutils],
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
    waku_lightpush/common,
    rest_api/endpoint/server,
    rest_api/endpoint/client,
    rest_api/endpoint/responses,
    rest_api/endpoint/lightpush/types,
    rest_api/endpoint/lightpush/handlers as lightpush_rest_interface,
    rest_api/endpoint/lightpush/client as lightpush_rest_client,
    rest_api/endpoint/relay/handlers as relay_rest_interface,
    rest_api/endpoint/relay/client as relay_rest_client,
    waku_relay,
    common/rate_limit/setting,
  ],
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../testlib/testasync,
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
  restClient: RestClientRef

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
    assert false, "Failed to mount relay: " & $error
  (await testSetup.serviceNode.mountRelay()).isOkOr:
    assert false, "Failed to mount relay: " & $error
  check (await testSetup.serviceNode.mountLightPush(rateLimit)).isOk()
  testSetup.pushNode.mountLightPushClient()

  testSetup.serviceNode.peerManager.addServicePeer(
    testSetup.consumerNode.peerInfo.toRemotePeerInfo(), WakuRelayCodec
  )

  await testSetup.serviceNode.connectToNodes(
    @[testSetup.consumerNode.peerInfo.toRemotePeerInfo()]
  )

  testSetup.pushNode.peerManager.addServicePeer(
    testSetup.serviceNode.peerInfo.toRemotePeerInfo(), WakuLightPushCodec
  )

  var restPort = Port(0)
  let restAddress = parseIpAddress("127.0.0.1")
  testSetup.restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
  restPort = testSetup.restServer.httpServer.address.port
    # update with bound port for restClient use

  installLightPushRequestHandler(testSetup.restServer.router, testSetup.pushNode)

  testSetup.restServer.start()

  testSetup.restClient = newRestHttpClient(initTAddress(restAddress, restPort))

  return testSetup

proc shutdown(self: RestLightPushTest) {.async.} =
  await self.restServer.stop()
  await self.restServer.closeWait()
  await allFutures(
    self.serviceNode.stop(), self.pushNode.stop(), self.consumerNode.stop()
  )

suite "Waku v2 Rest API - lightpush":
  asyncTest "Push message with proof":
    let restLightPushTest = await RestLightPushTest.init()
    defer:
      await restLightPushTest.shutdown()

    let message: RelayWakuMessage = fakeWakuMessage(
        contentTopic = DefaultContentTopic,
        payload = toBytes("TEST-1"),
        proof = toBytes("proof-test"),
      )
      .toRelayWakuMessage()

    check message.proof.isSome()

    let requestBody =
      PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: message)

    let response =
      await restLightPushTest.restClient.sendPushRequest(body = requestBody)

    ## Validate that the push request failed because the node is not
    ## connected to other node but, doesn't fail because of not properly
    ## handling the proof message attribute within the REST request.
    check:
      response.status == 505
      response.data.statusDesc == Opt.some("No peers for topic, skipping publish")
      response.data.relayPeerCount == Opt.none(uint32)

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
      assert false, "Failed to subscribe to relay: " & $error

    restLightPushTest.serviceNode.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler
    ).isOkOr:
      assert false, "Failed to subscribe to relay: " & $error
    check:
      toSeq(restLightPushTest.serviceNode.wakuRelay.subscribedTopics).len == 1

    # When
    let message: RelayWakuMessage = fakeWakuMessage(
        contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")
      )
      .toRelayWakuMessage()

    let requestBody =
      PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: message)
    let response = await restLightPushTest.restClient.sendPushRequest(requestBody)

    echo "response", $response

    # Then
    check:
      response.status == 200
      response.data.relayPeerCount == Opt.some(1.uint32)

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
      assert false, "Failed to subscribe to relay: " & $error
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

    # var response: RestResponse[PushResponse]

    var response = await restLightPushTest.restClient.sendPushRequest(badRequestBody1)

    # Then
    check:
      response.status == 400
      response.data.statusDesc.isSome()
      response.data.statusDesc.get().startsWith("Invalid push request")

    # when
    response = await restLightPushTest.restClient.sendPushRequest(badRequestBody2)

    # Then
    check:
      response.status == 400
      response.data.statusDesc.isSome()
      response.data.statusDesc.get().startsWith("Invalid push request")

    # when
    response = await restLightPushTest.restClient.sendPushRequest(badRequestBody3)

    # Then
    check:
      response.data.statusDesc.isSome()
      response.data.statusDesc.get().startsWith("Invalid push request")

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
      assert false, "Failed to subscribe to relay: " & $error

    restLightPushTest.serviceNode.subscribe(
      (kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler
    ).isOkOr:
      assert false, "Failed to subscribe to relay: " & $error
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
      let response = await restLightPushTest.restClient.sendPushRequest(requestBody)

      echo "response", $response

      # Then
      check:
        response.status == 200
        response.data.relayPeerCount == Opt.some(1.uint32)

    let pushRejectedProc = proc() {.async.} =
      let message: RelayWakuMessage = fakeWakuMessage(
          contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")
        )
        .toRelayWakuMessage()

      let requestBody =
        PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: message)
      let response = await restLightPushTest.restClient.sendPushRequest(requestBody)

      echo "response", $response

      # Then
      check:
        response.status == 429
        response.data.statusDesc.isSome() # Ensure error status description is present
        response.data.statusDesc.get().startsWith(
          "Request rejected due to too many requests"
        ) # Check specific error message

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

  asyncTest "A pushed message is read back on the relay peer of the service node - POST /lightpush/v3/message, GET /relay/v1/messages/{topic}":
    # Given the consumer node subscribed over REST and known to the service node
    let restLightPushTest = await RestLightPushTest.init()
    defer:
      await restLightPushTest.shutdown()

    let restServerForConsumer =
      WakuRestServerRef.init(parseIpAddress("127.0.0.1"), Port(0)).tryGet()
    installRelayApiHandlers(
      restServerForConsumer.router, restLightPushTest.consumerNode, MessageCache.init()
    )
    restServerForConsumer.start()
    defer:
      await restServerForConsumer.stop()
      await restServerForConsumer.closeWait()

    let clientTwdConsumerNode = newRestHttpClient(restServerForConsumer.localAddress())

    let subscribeResponse =
      await clientTwdConsumerNode.relayPostSubscriptionsV1(@[DefaultPubsubTopic])
    check subscribeResponse.status == 200
    checkUntilTimeout:
      restLightPushTest.serviceNode.hasGossipsubPeer(
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
      proof: Opt.some(base64.encode("test-proof")),
    )
    let pushResponse = await restLightPushTest.restClient.sendPushRequest(
      PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: sent)
    )
    check:
      pushResponse.status == 200
      pushResponse.data.relayPeerCount == Opt.some(1.uint32)

    # Then the relay peer reads it back over REST with every field unchanged
    let received =
      await clientTwdConsumerNode.waitForRelayMessages(DefaultPubsubTopic, 1)
    check:
      received.mapIt(it.payload) == @[sent.payload]
      received.mapIt(it.contentTopic) == @[sent.contentTopic]
      received.mapIt(it.version) == @[sent.version]
      received.mapIt(it.timestamp) == @[sent.timestamp]
      received.mapIt(it.meta) == @[sent.meta]
      received.mapIt(it.ephemeral) == @[sent.ephemeral]
      received.mapIt(it.proof) == @[sent.proof]

  asyncTest "Push a message with an invalid body - POST /lightpush/v3/message":
    let restLightPushTest = await RestLightPushTest.init()
    defer:
      await restLightPushTest.shutdown()

    let
      path = "/lightpush/v3/message"
      jsonHeader: seq[HttpHeaderTuple] = @[("Content-Type", "application/json")]
      payload = string(base64.encode("TEST-PAYLOAD"))
      validMessage =
        "{\"payload\": \"" & payload & "\", \"contentTopic\": \"" & DefaultContentTopic &
        "\"}"

    # When the body does not decode into a push request
    let invalidBodies = [
      $ %*{
        "pubsubTopic": [DefaultPubsubTopic],
        "message": {"payload": payload, "contentTopic": DefaultContentTopic},
      },
      $ %*{"pubsubTopic": DefaultPubsubTopic},
      "{\"pubsubTopic\": \"" & DefaultPubsubTopic & "\", \"message\": " & validMessage &
        ", \"message\": " & validMessage & "}",
    ]

    # Then each is rejected as an invalid push request
    for body in invalidBodies:
      let response = await issueRequest(
        restLightPushTest.restServer.getAddress(path), MethodPost, jsonHeader, body
      )
      let data = parseJson(response.data)
      # The answer carries the printed response object that wraps the decode error.
      check:
        response.status == 400
        data["statusDesc"].getStr().startsWith(
          "Invalid push request! (status: 400 Bad Request, "
        )

    # An unknown field is rejected although the decoder sets allowUnknownFields.
    let unknownFieldResponse = await issueRequest(
      restLightPushTest.restServer.getAddress(path),
      MethodPost,
      jsonHeader,
      "{\"pubsubTopic\": \"" & DefaultPubsubTopic & "\", \"message\": " & validMessage &
        ", \"extraField\": \"extraValue\"}",
    )
    let unknownFieldData = parseJson(unknownFieldResponse.data)
    check:
      unknownFieldResponse.status == 400
      unknownFieldData["statusDesc"].getStr().startsWith(
        "Invalid push request! (status: 400 Bad Request, "
      )

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

    # Then the request is rejected as an invalid message
    for body in notBase64Bodies:
      let response = await issueRequest(
        restLightPushTest.restServer.getAddress(path), MethodPost, jsonHeader, body
      )
      let data = parseJson(response.data)
      check:
        response.status == 400
        data["statusDesc"].getStr() == "Invalid message! Incorrect base64 string"

  asyncTest "Push a message over the size limit - POST /lightpush/v3/message":
    # Given
    let restLightPushTest = await RestLightPushTest.init()
    defer:
      await restLightPushTest.shutdown()

    # When
    let message: RelayWakuMessage = fakeWakuMessage(
        contentTopic = DefaultContentTopic,
        payload = getByteSequence(DefaultMaxWakuMessageSize + 64 * 1024),
      )
      .toRelayWakuMessage()

    let response = await restLightPushTest.restClient.sendPushRequest(
      PushRequest(pubsubTopic: Opt.some(DefaultPubsubTopic), message: message)
    )

    # Then
    # The lightpush code INVALID_MESSAGE (420) has no HTTP status, so REST answers 500.
    check:
      response.status == 500
      response.data.statusDesc ==
        Opt.some(
          fmt"Message size exceeded maximum of {DefaultMaxWakuMessageSize} bytes"
        )
