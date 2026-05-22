{.used.}

import
  std/[options, tables, sequtils, strutils, sets],
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/[peerstore, crypto/crypto]

import
  waku/[
    waku_core,
    node/peer_manager,
    node/waku_node,
    node/kernel_api,
    waku_filter_v2,
    waku_filter_v2/client,
    waku_filter_v2/subscriptions,
    waku_filter_v2/rpc,
  ],
  ../testlib/[common, wakucore, wakunode, testasync, futures, testutils],
  ../waku_filter_v2/waku_filter_utils

proc generateRequestId(rng: ref HmacDrbgContext): string =
  var bytes: array[10, byte]
  hmacDrbgGenerate(rng[], bytes)
  return toHex(bytes)

proc createRequest(
    filterSubscribeType: FilterSubscribeType,
    pubsubTopic = none(PubsubTopic),
    contentTopics = newSeq[ContentTopic](),
): FilterSubscribeRequest =
  let requestId = generateRequestId(rng)

  return FilterSubscribeRequest(
    requestId: requestId,
    filterSubscribeType: filterSubscribeType,
    pubsubTopic: pubsubTopic,
    contentTopics: contentTopics,
  )

suite "Waku Filter - End to End":
  var client {.threadvar.}: WakuNode
  var clientPeerId {.threadvar.}: PeerId
  var clientClone {.threadvar.}: WakuNode
  var server {.threadvar.}: WakuNode
  var serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
  var pubsubTopic {.threadvar.}: PubsubTopic
  var contentTopic {.threadvar.}: ContentTopic
  var contentTopicSeq {.threadvar.}: seq[ContentTopic]
  var pushHandlerFuture {.threadvar.}: Future[(string, WakuMessage)]
  var messagePushHandler {.threadvar.}: FilterPushHandler
  var clientKey {.threadvar.}: PrivateKey
  var serverKey {.threadvar.}: PrivateKey

  asyncSetup:
    pushHandlerFuture = newFuture[(string, WakuMessage)]()
    messagePushHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[void] {.async, closure, gcsafe.} =
      pushHandlerFuture.complete((pubsubTopic, message))

    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic
    contentTopicSeq = @[DefaultContentTopic]

    serverKey = generateSecp256k1Key()
    clientKey = generateSecp256k1Key()

    server = newTestWakuNode(
      serverKey, parseIpAddress("0.0.0.0"), Port(23450), maxConnections = 300
    )
    client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(23451))
    clientClone = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(23451))
      # Used for testing client restarts

    await allFutures(server.start(), client.start())

    await server.mountFilter()
    await client.mountFilterClient()

    client.wakuFilterClient.registerPushHandler(messagePushHandler)
    serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()
    clientPeerId = client.peerInfo.toRemotePeerInfo().peerId

    # Prepare the clone but do not start it
    await clientClone.mountFilterClient()
    clientClone.wakuFilterClient.registerPushHandler(messagePushHandler)

  asyncTeardown:
    await allFutures(client.stop(), clientClone.stop(), server.stop())

  asyncTest "Client Node receives Push from Server Node, via Filter":
    # When a client node subscribes to a filter node
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )

    # Then the subscription is successful
    check:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 1
      server.wakuFilter.subscriptions.isSubscribed(clientPeerId)

    # When sending a message to the subscribed content topic
    let msg1 = fakeWakuMessage(contentTopic = contentTopic)
    await server.filterHandleMessage(pubsubTopic, msg1)

    # Then the message is pushed to the client
    require await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
    let (pushedMsgPubsubTopic1, pushedMsg1) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic1 == pubsubTopic
      pushedMsg1 == msg1

    # When unsubscribing from the subscription
    let unsubscribeResponse = await client.filterUnsubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )

    # Then the unsubscription is successful
    check:
      unsubscribeResponse.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 0

    # When sending a message to the previously subscribed content topic
    pushHandlerFuture = newPushHandlerFuture() # Clear previous future
    let msg2 = fakeWakuMessage(contentTopic = contentTopic)
    await server.filterHandleMessage(pubsubTopic, msg2)

    # Then the message is not pushed to the client
    check:
      not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)

  asyncTest "Client Node can't receive Push from Server Node, via Relay":
    # Given the server node has Relay enabled
    (await server.mountRelay()).isOkOr:
      assert false, "error mounting relay: " & $error

    # And valid filter subscription
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    require:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 1

    # When a server node gets a Relay message
    let msg1 = fakeWakuMessage(contentTopic = contentTopic)
    discard await server.publish(some(pubsubTopic), msg1)

    # Then the message is not sent to the client's filter push handler
    check (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT))

  asyncTest "Client Node can't subscribe to Server Node without Filter":
    # Given a server node with Relay without Filter
    let
      serverKey = generateSecp256k1Key()
      server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))

    await server.start()
    (await server.mountRelay()).isOkOr:
      assert false, "error mounting relay: " & $error

    let serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()

    # When a client node subscribes to the server node
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )

    # Then the subscription is successful
    check (not subscribeResponse.isOk())

  xasyncTest "Filter Client Node can receive messages after subscribing and restarting, via Filter":
    ## connect both switches
    await client.switch.connect(
      server.switch.peerInfo.peerId, server.switch.peerInfo.listenAddrs
    )

    # Given a valid filter subscription
    var subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    require:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 1

    # And the client node reboots
    await client.stop()
    ## This line above causes the test to fail. I think ConnManager
    ## is not prepare for restarts and maybe we don't need that restart feature.

    client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(23451))
    await client.start() # Mimic restart by starting the clone

    # pushHandlerFuture = newFuture[(string, WakuMessage)]()
    await client.mountFilterClient()
    client.wakuFilterClient.registerPushHandler(messagePushHandler)

    ## connect both switches
    await client.switch.connect(
      server.switch.peerInfo.peerId, server.switch.peerInfo.listenAddrs
    )

    # Given a valid filter subscription
    subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    require:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 1

    # When a message is sent to the subscribed content topic, via Filter; without refreshing the subscription
    let msg = fakeWakuMessage(contentTopic = contentTopic)
    await server.filterHandleMessage(pubsubTopic, msg)

    # Then the message is pushed to the client
    check await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT)
    let (pushedMsgPubsubTopic, pushedMsg) = pushHandlerFuture.read()
    check:
      pushedMsgPubsubTopic == pubsubTopic
      pushedMsg == msg

  asyncTest "Filter Client Node can't receive messages after subscribing and restarting, via Relay":
    (await server.mountRelay()).isOkOr:
      assert false, "error mounting relay: " & $error

    # Given a valid filter subscription
    let subscribeResponse = await client.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    require:
      subscribeResponse.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 1

    # And the client node reboots
    await client.stop()
    await clientClone.start() # Mimic restart by starting the clone

    # When a message is sent to the subscribed content topic, via Relay
    let msg = fakeWakuMessage(contentTopic = contentTopic)
    discard await server.publish(some(pubsubTopic), msg)

    # Then the message is not sent to the client's filter push handler
    check (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT))

    # Given the client refreshes the subscription
    let subscribeResponse2 = await clientClone.filterSubscribe(
      some(pubsubTopic), contentTopicSeq, serverRemotePeerInfo
    )
    check:
      subscribeResponse2.isOk()
      server.wakuFilter.subscriptions.subscribedPeerCount() == 1

    # When a message is sent to the subscribed content topic, via Relay
    pushHandlerFuture = newPushHandlerFuture()
    let msg2 = fakeWakuMessage(contentTopic = contentTopic)
    discard await server.publish(some(pubsubTopic), msg2)

    # Then the message is not sent to the client's filter push handler
    check (not await pushHandlerFuture.withTimeout(FUTURE_TIMEOUT))

  asyncTest "ping subscriber":
    # Given
    let
      wakuFilter = server.wakuFilter
      clientPeerId = client.switch.peerInfo.peerId
      serverPeerId = server.switch.peerInfo.peerId
      pingRequest =
        createRequest(filterSubscribeType = FilterSubscribeType.SUBSCRIBER_PING)
      filterSubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )

    ## connect both switches
    await client.switch.connect(serverPeerId, server.switch.peerInfo.listenAddrs)

    # When
    let response1 = await wakuFilter.handleSubscribeRequest(clientPeerId, pingRequest)

    # Then
    check:
      response1.requestId == pingRequest.requestId
      response1.statusCode == FilterSubscribeErrorKind.NOT_FOUND.uint32
      response1.statusDesc.get().contains("peer has no subscriptions")

    # When
    let
      response2 =
        await wakuFilter.handleSubscribeRequest(clientPeerId, filterSubscribeRequest)
      response3 = await wakuFilter.handleSubscribeRequest(clientPeerId, pingRequest)

    # Then
    check:
      response2.requestId == filterSubscribeRequest.requestId
      response2.statusCode == 200
      response2.statusDesc.get() == "OK"
      response3.requestId == pingRequest.requestId
      response3.statusCode == 200
      response3.statusDesc.get() == "OK"

  asyncTest "simple subscribe and unsubscribe request":
    # Given
    let
      wakuFilter = server.wakuFilter
      clientPeerId = client.switch.peerInfo.peerId
      serverPeerId = server.switch.peerInfo.peerId
      filterSubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      filterUnsubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = filterSubscribeRequest.pubsubTopic,
        contentTopics = filterSubscribeRequest.contentTopics,
      )

    ## connect both switches
    await client.switch.connect(serverPeerId, server.switch.peerInfo.listenAddrs)

    # When
    let response =
      await wakuFilter.handleSubscribeRequest(clientPeerId, filterSubscribeRequest)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.peersSubscribed[clientPeerId].criteriaCount == 1
      response.requestId == filterSubscribeRequest.requestId
      response.statusCode == 200
      response.statusDesc.get() == "OK"

    # When
    let response2 =
      await wakuFilter.handleSubscribeRequest(clientPeerId, filterUnsubscribeRequest)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 0
        # peerId is removed from subscriptions
      response2.requestId == filterUnsubscribeRequest.requestId
      response2.statusCode == 200
      response2.statusDesc.get() == "OK"

  asyncTest "simple subscribe and unsubscribe all for multiple content topics":
    # Given
    let
      wakuFilter = server.wakuFilter
      clientPeerId = client.switch.peerInfo.peerId
      serverPeerId = server.switch.peerInfo.peerId
      nonDefaultContentTopic = ContentTopic("/waku/2/non-default-waku/proto")
      filterSubscribeRequest = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic, nonDefaultContentTopic],
      )
      filterUnsubscribeAllRequest =
        createRequest(filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE_ALL)

    ## connect both switches
    await client.switch.connect(serverPeerId, server.switch.peerInfo.listenAddrs)

    # When
    let response =
      await wakuFilter.handleSubscribeRequest(clientPeerId, filterSubscribeRequest)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.peersSubscribed[clientPeerId].criteriaCount == 2
      unorderedCompare(
        wakuFilter.getSubscribedContentTopics(clientPeerId),
        filterSubscribeRequest.contentTopics,
      )
      response.requestId == filterSubscribeRequest.requestId
      response.statusCode == 200
      response.statusDesc.get() == "OK"

    # When
    let response2 =
      await wakuFilter.handleSubscribeRequest(clientPeerId, filterUnsubscribeAllRequest)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 0
        # peerId is removed from subscriptions
      response2.requestId == filterUnsubscribeAllRequest.requestId
      response2.statusCode == 200
      response2.statusDesc.get() == "OK"

  asyncTest "subscribe and unsubscribe to multiple content topics":
    # Given
    let
      wakuFilter = server.wakuFilter
      clientPeerId = client.switch.peerInfo.peerId
      serverPeerId = server.switch.peerInfo.peerId
      nonDefaultContentTopic = ContentTopic("/waku/2/non-default-waku/proto")
      filterSubscribeRequest1 = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      filterSubscribeRequest2 = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = filterSubscribeRequest1.pubsubTopic,
        contentTopics = @[nonDefaultContentTopic],
      )
      filterUnsubscribeRequest1 = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = filterSubscribeRequest1.pubsubTopic,
        contentTopics = filterSubscribeRequest1.contentTopics,
      )
      filterUnsubscribeRequest2 = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = filterSubscribeRequest2.pubsubTopic,
        contentTopics = filterSubscribeRequest2.contentTopics,
      )

    ## connect both switches
    await client.switch.connect(serverPeerId, server.switch.peerInfo.listenAddrs)

    # When
    let response1 =
      await wakuFilter.handleSubscribeRequest(clientPeerId, filterSubscribeRequest1)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.peersSubscribed[clientPeerId].criteriaCount == 1
      unorderedCompare(
        wakuFilter.getSubscribedContentTopics(clientPeerId),
        filterSubscribeRequest1.contentTopics,
      )
      response1.requestId == filterSubscribeRequest1.requestId
      response1.statusCode == 200
      response1.statusDesc.get() == "OK"

    # When
    let response2 =
      await wakuFilter.handleSubscribeRequest(clientPeerId, filterSubscribeRequest2)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.peersSubscribed[clientPeerId].criteriaCount == 2
      unorderedCompare(
        wakuFilter.getSubscribedContentTopics(clientPeerId),
        filterSubscribeRequest1.contentTopics & filterSubscribeRequest2.contentTopics,
      )
      response2.requestId == filterSubscribeRequest2.requestId
      response2.statusCode == 200
      response2.statusDesc.get() == "OK"

    # When
    let response3 =
      await wakuFilter.handleSubscribeRequest(clientPeerId, filterUnsubscribeRequest1)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 1
      wakuFilter.subscriptions.peersSubscribed[clientPeerId].criteriaCount == 1
      unorderedCompare(
        wakuFilter.getSubscribedContentTopics(clientPeerId),
        filterSubscribeRequest2.contentTopics,
      )
      response3.requestId == filterUnsubscribeRequest1.requestId
      response3.statusCode == 200
      response3.statusDesc.get() == "OK"

    # When
    let response4 =
      await wakuFilter.handleSubscribeRequest(clientPeerId, filterUnsubscribeRequest2)

    # Then
    check:
      wakuFilter.subscriptions.subscribedPeerCount() == 0
        # peerId is removed from subscriptions
      response4.requestId == filterUnsubscribeRequest2.requestId
      response4.statusCode == 200
      response4.statusDesc.get() == "OK"

  asyncTest "subscribe errors":
    ## Tests most common error paths while subscribing

    # Given
    let
      wakuFilter = server.wakuFilter
      clientPeerId = client.switch.peerInfo.peerId
      serverPeerId = server.switch.peerInfo.peerId
      peerManager = server.peerManager

    ## connect both switches
    await client.switch.connect(serverPeerId, server.switch.peerInfo.listenAddrs)

    ## Incomplete filter criteria

    # When
    let
      reqNoPubsubTopic = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = none(PubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      reqNoContentTopics = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[],
      )
      response1 =
        await wakuFilter.handleSubscribeRequest(clientPeerId, reqNoPubsubTopic)
      response2 =
        await wakuFilter.handleSubscribeRequest(clientPeerId, reqNoContentTopics)

    # Then
    check:
      response1.requestId == reqNoPubsubTopic.requestId
      response2.requestId == reqNoContentTopics.requestId
      response1.statusCode == FilterSubscribeErrorKind.BAD_REQUEST.uint32
      response2.statusCode == FilterSubscribeErrorKind.BAD_REQUEST.uint32
      response1.statusDesc.get().contains(
        "pubsubTopic and contentTopics must be specified"
      )
      response2.statusDesc.get().contains(
        "pubsubTopic and contentTopics must be specified"
      )

    ## Max content topics per request exceeded

    # When
    let
      contentTopics = toSeq(1 .. MaxContentTopicsPerRequest + 1).mapIt(
          ContentTopic("/waku/2/content-$#/proto" % [$it])
        )
      reqTooManyContentTopics = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = contentTopics,
      )
      response3 =
        await wakuFilter.handleSubscribeRequest(clientPeerId, reqTooManyContentTopics)

    # Then
    check:
      response3.requestId == reqTooManyContentTopics.requestId
      response3.statusCode == FilterSubscribeErrorKind.BAD_REQUEST.uint32
      response3.statusDesc.get().contains("exceeds maximum content topics")

    ## Max filter criteria exceeded

    # When
    let filterCriteria = toSeq(1 .. MaxFilterCriteriaPerPeer).mapIt(
        (DefaultPubsubTopic, ContentTopic("/waku/2/content-$#/proto" % [$it]))
      )

    discard await wakuFilter.subscriptions.addSubscription(
      clientPeerId, filterCriteria.toHashSet()
    )

    let
      reqTooManyFilterCriteria = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      response4 =
        await wakuFilter.handleSubscribeRequest(clientPeerId, reqTooManyFilterCriteria)

    # Then
    check:
      response4.requestId == reqTooManyFilterCriteria.requestId
      response4.statusCode == FilterSubscribeErrorKind.SERVICE_UNAVAILABLE.uint32
      response4.statusDesc.get().contains(
        "peer has reached maximum number of filter criteria"
      )

    ## Max subscriptions exceeded

    # When
    await wakuFilter.subscriptions.removePeer(clientPeerId)
    wakuFilter.subscriptions.cleanUp()

    var peers = newSeq[WakuNode](MaxFilterPeers)

    for index in 0 ..< MaxFilterPeers:
      peers[index] = newTestWakuNode(
        generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(23551 + index)
      )

      await peers[index].start()
      await peers[index].mountFilterClient()

      ## connect switches
      info "establish connection", peerId = peers[index].peerInfo.peerId

      await server.switch.connect(
        peers[index].switch.peerInfo.peerId, peers[index].switch.peerInfo.listenAddrs
      )

      info "adding subscription"

      (
        await wakuFilter.subscriptions.addSubscription(
          peers[index].switch.peerInfo.peerId,
          @[(DefaultPubsubTopic, DefaultContentTopic)].toHashSet(),
        )
      ).isOkOr:
        assert false, $error

    let
      reqTooManySubscriptions = createRequest(
        filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      response5 =
        await wakuFilter.handleSubscribeRequest(clientPeerId, reqTooManySubscriptions)

    # Then
    check:
      response5.requestId == reqTooManySubscriptions.requestId
      response5.statusCode == FilterSubscribeErrorKind.SERVICE_UNAVAILABLE.uint32
      response5.statusDesc.get().contains(
        "node has reached maximum number of subscriptions"
      )

    ## stop the peers
    for index in 0 ..< MaxFilterPeers:
      await peers[index].stop()

  asyncTest "unsubscribe errors":
    ## Tests most common error paths while unsubscribing

    # Given
    let
      wakuFilter = server.wakuFilter
      clientPeerId = client.switch.peerInfo.peerId
      serverPeerId = server.switch.peerInfo.peerId

    ## connect both switches
    await client.switch.connect(serverPeerId, server.switch.peerInfo.listenAddrs)

    ## Incomplete filter criteria

    # When
    let
      reqNoPubsubTopic = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = none(PubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      reqNoContentTopics = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[],
      )
      response1 =
        await wakuFilter.handleSubscribeRequest(clientPeerId, reqNoPubsubTopic)
      response2 =
        await wakuFilter.handleSubscribeRequest(clientPeerId, reqNoContentTopics)

    # Then
    check:
      response1.requestId == reqNoPubsubTopic.requestId
      response2.requestId == reqNoContentTopics.requestId
      response1.statusCode == FilterSubscribeErrorKind.BAD_REQUEST.uint32
      response2.statusCode == FilterSubscribeErrorKind.BAD_REQUEST.uint32
      response1.statusDesc.get().contains(
        "pubsubTopic and contentTopics must be specified"
      )
      response2.statusDesc.get().contains(
        "pubsubTopic and contentTopics must be specified"
      )

    ## Max content topics per request exceeded

    # When
    let
      contentTopics = toSeq(1 .. MaxContentTopicsPerRequest + 1).mapIt(
          ContentTopic("/waku/2/content-$#/proto" % [$it])
        )
      reqTooManyContentTopics = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = contentTopics,
      )
      response3 =
        await wakuFilter.handleSubscribeRequest(clientPeerId, reqTooManyContentTopics)

    # Then
    check:
      response3.requestId == reqTooManyContentTopics.requestId
      response3.statusCode == FilterSubscribeErrorKind.BAD_REQUEST.uint32
      response3.statusDesc.get().contains("exceeds maximum content topics")

    ## Subscription not found - unsubscribe

    # When
    let
      reqSubscriptionNotFound = createRequest(
        filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE,
        pubsubTopic = some(DefaultPubsubTopic),
        contentTopics = @[DefaultContentTopic],
      )
      response4 =
        await wakuFilter.handleSubscribeRequest(clientPeerId, reqSubscriptionNotFound)

    # Then
    check:
      response4.requestId == reqSubscriptionNotFound.requestId
      response4.statusCode == FilterSubscribeErrorKind.NOT_FOUND.uint32
      response4.statusDesc.get().contains("peer has no subscriptions")

    ## Subscription not found - unsubscribe all

    # When
    let
      reqUnsubscribeAll =
        createRequest(filterSubscribeType = FilterSubscribeType.UNSUBSCRIBE_ALL)
      response5 =
        await wakuFilter.handleSubscribeRequest(clientPeerId, reqUnsubscribeAll)

    # Then
    check:
      response5.requestId == reqUnsubscribeAll.requestId
      response5.statusCode == FilterSubscribeErrorKind.NOT_FOUND.uint32
      response5.statusDesc.get().contains("peer has no subscriptions")

  suite "Waku Filter - subscription maintenance":
    asyncTest "simple maintenance":
      # Given
      let
        wakuFilter = server.wakuFilter
        clientPeerId = client.switch.peerInfo.peerId
        serverPeerId = server.switch.peerInfo.peerId
        peerManager = server.peerManager

      let
        client1 = newTestWakuNode(
          generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(23552)
        )
        client2 = newTestWakuNode(
          generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(23553)
        )
        client3 = newTestWakuNode(
          generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(23554)
        )
        filterSubscribeRequest = createRequest(
          filterSubscribeType = FilterSubscribeType.SUBSCRIBE,
          pubsubTopic = some(DefaultPubsubTopic),
          contentTopics = @[DefaultContentTopic],
        )

      ## connect both switches
      await client1.switch.connect(serverPeerId, server.switch.peerInfo.listenAddrs)
      await client2.switch.connect(serverPeerId, server.switch.peerInfo.listenAddrs)
      await client3.switch.connect(serverPeerId, server.switch.peerInfo.listenAddrs)

      await client1.start()
      await client2.start()
      await client3.start()

      defer:
        await client1.stop()
        await client2.stop()
        await client3.stop()

      await client1.mountFilterClient()
      await client2.mountFilterClient()
      await client3.mountFilterClient()

      # When
      server.switch.peerStore[ProtoBook][client1.switch.peerInfo.peerId] =
        @[WakuFilterPushCodec]
      server.switch.peerStore[ProtoBook][client2.switch.peerInfo.peerId] =
        @[WakuFilterPushCodec]
      server.switch.peerStore[ProtoBook][client3.switch.peerInfo.peerId] =
        @[WakuFilterPushCodec]

      check:
        (
          await wakuFilter.handleSubscribeRequest(
            client1.switch.peerInfo.peerId, filterSubscribeRequest
          )
        ).statusCode == 200

        (
          await wakuFilter.handleSubscribeRequest(
            client2.switch.peerInfo.peerId, filterSubscribeRequest
          )
        ).statusCode == 200

        (
          await wakuFilter.handleSubscribeRequest(
            client3.switch.peerInfo.peerId, filterSubscribeRequest
          )
        ).statusCode == 200

      # Then
      check:
        wakuFilter.subscriptions.subscribedPeerCount() == 3
        wakuFilter.subscriptions.isSubscribed(client1.switch.peerInfo.peerId)
        wakuFilter.subscriptions.isSubscribed(client2.switch.peerInfo.peerId)
        wakuFilter.subscriptions.isSubscribed(client1.switch.peerInfo.peerId)

      # When
      # Maintenance loop should leave all peers in peer store intact
      await wakuFilter.maintainSubscriptions()

      # Then
      check:
        wakuFilter.subscriptions.subscribedPeerCount() == 3
        wakuFilter.subscriptions.isSubscribed(client1.switch.peerInfo.peerId)
        wakuFilter.subscriptions.isSubscribed(client2.switch.peerInfo.peerId)
        wakuFilter.subscriptions.isSubscribed(client1.switch.peerInfo.peerId)

      # When
      # Remove peerId1 and peerId3 from peer store
      server.switch.peerStore.del(client1.switch.peerInfo.peerId)
      server.switch.peerStore.del(client3.switch.peerInfo.peerId)
      await wakuFilter.maintainSubscriptions()

      # Then
      check:
        wakuFilter.subscriptions.subscribedPeerCount() == 1
        wakuFilter.subscriptions.isSubscribed(client2.switch.peerInfo.peerId)

      # When
      # Remove peerId2 from peer store
      server.switch.peerStore.del(client2.switch.peerInfo.peerId)
      await wakuFilter.maintainSubscriptions()

      # Then
      check:
        wakuFilter.subscriptions.subscribedPeerCount() == 0
