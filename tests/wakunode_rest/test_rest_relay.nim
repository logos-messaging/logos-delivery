{.used.}

import
  std/[sequtils, strformat, tempfiles, osproc],
  stew/byteutils,
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/crypto/crypto
import
  waku/[
    common/base64,
    waku_core,
    waku_node,
    rest_api/message_cache,
    rest_api/endpoint/server,
    rest_api/endpoint/client,
    rest_api/endpoint/responses,
    rest_api/endpoint/relay/types,
    rest_api/endpoint/relay/handlers as relay_rest_interface,
    rest_api/endpoint/relay/client as relay_rest_client,
    waku_relay,
    waku_rln_relay,
  ],
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../resources/payloads,
  ../waku_rln_relay/[rln/waku_rln_relay_utils, utils_onchain]

proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  newTestWakuNode(privkey, bindIp, port, some(extIp), some(port))

suite "Waku v2 Rest API - Relay":
  var anvilProc {.threadVar.}: Process
  var manager {.threadVar.}: OnchainGroupManager

  setup:
    anvilProc = runAnvil(stateFile = some(DEFAULT_ANVIL_STATE_PATH))
    manager = waitFor setupOnchainGroupManager(deployContracts = false)

  teardown:
    stopAnvil(anvilProc)

  asyncTest "Subscribe a node to an array of pubsub topics - POST /relay/v1/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    var restPort = Port(0)

    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let
      shard0 = RelayShard(clusterId: DefaultClusterId, shardId: 0)
      shard1 = RelayShard(clusterId: DefaultClusterId, shardId: 1)
      shard2 = RelayShard(clusterId: DefaultClusterId, shardId: 2)

    let shards = @[$shard0, $shard1, $shard2]

    let invalidTopic = "/test/2/this/is/a/content/topic/1"

    var containsIncorrect = shards
    containsIncorrect.add(invalidTopic)

    # When contains incorrect pubsub topics, subscribe shall fail
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let errorResponse = await client.relayPostSubscriptionsV1(containsIncorrect)

    # Then
    check:
      errorResponse.status == 400
      $errorResponse.contentType == $MIMETYPE_TEXT
      errorResponse.data ==
        "Invalid pubsub topic(s): @[\"/test/2/this/is/a/content/topic/1\"]"

    # when all pubsub topics are correct, subscribe shall succeed
    let response = await client.relayPostSubscriptionsV1(shards)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      cache.isPubsubSubscribed($shard0)
      cache.isPubsubSubscribed($shard1)
      cache.isPubsubSubscribed($shard2)

    check:
      toSeq(node.wakuRelay.subscribedTopics).len == shards.len

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Unsubscribe a node from an array of pubsub topics - DELETE /relay/v1/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()

    let
      shard0 = RelayShard(clusterId: DefaultClusterId, shardId: 0)
      shard1 = RelayShard(clusterId: DefaultClusterId, shardId: 1)
      shard2 = RelayShard(clusterId: DefaultClusterId, shardId: 2)
      shard3 = RelayShard(clusterId: DefaultClusterId, shardId: 3)
      shard4 = RelayShard(clusterId: DefaultClusterId, shardId: 4)

    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    proc simpleHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    for shard in @[$shard0, $shard1, $shard2, $shard3, $shard4]:
      node.subscribe((kind: PubsubSub, topic: shard), simpleHandler).isOkOr:
        assert false, "Failed to subscribe to pubsub topic: " & $error

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()
    cache.pubsubSubscribe($shard0)
    cache.pubsubSubscribe($shard1)
    cache.pubsubSubscribe($shard2)
    cache.pubsubSubscribe($shard3)

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let shards = @[$shard0, $shard1, $shard2, $shard4]

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.relayDeleteSubscriptionsV1(shards)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      not cache.isPubsubSubscribed($shard0)
      not node.wakuRelay.isSubscribed($shard0)
      not cache.isPubsubSubscribed($shard1)
      not node.wakuRelay.isSubscribed($shard1)
      not cache.isPubsubSubscribed($shard2)
      not node.wakuRelay.isSubscribed($shard2)
      cache.isPubsubSubscribed($shard3)
      node.wakuRelay.isSubscribed($shard3)
      not cache.isPubsubSubscribed($shard4)
      not node.wakuRelay.isSubscribed($shard4)

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Get the latest messages for a pubsub topic - GET /relay/v1/messages/{topic}":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let pubSubTopic = "/waku/2/rs/0/0"

    var messages =
      @[
        fakeWakuMessage(
          contentTopic = "content-topic-x",
          payload = toBytes("TEST-1"),
          meta = toBytes("test-meta"),
          ephemeral = true,
        )
      ]

    # Prevent duplicate messages
    for i in 0 ..< 2:
      var msg = fakeWakuMessage(
        contentTopic = "content-topic-x",
        payload = toBytes("TEST-1"),
        meta = toBytes("test-meta"),
        ephemeral = true,
      )

      while msg == messages[i]:
        msg = fakeWakuMessage(
          contentTopic = "content-topic-x",
          payload = toBytes("TEST-1"),
          meta = toBytes("test-meta"),
          ephemeral = true,
        )

      messages.add(msg)

    let cache = MessageCache.init()

    cache.pubsubSubscribe(pubSubTopic)
    for msg in messages:
      cache.addMessage(pubSubTopic, msg)

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.relayGetMessagesV1(pubSubTopic)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.len == 3
      response.data.all do(msg: RelayWakuMessage) -> bool:
        msg.payload == base64.encode("TEST-1") and
          msg.contentTopic.get() == "content-topic-x" and msg.version.get() == 2 and
          msg.timestamp.get() != Timestamp(0) and
          msg.meta.get() == base64.encode("test-meta") and msg.ephemeral.get() == true

    check:
      cache.isPubsubSubscribed(pubSubTopic)
      cache.getMessages(pubSubTopic).tryGet().len == 0

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message to a pubsub topic - POST /relay/v1/messages/{topic}":
    ## "Relay API: publish and subscribe/unsubscribe":
    # Given
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    let wakuRlnConfig = getWakuRlnConfig(manager = manager, index = MembershipIndex(1))

    await node.mountRlnRelay(wakuRlnConfig)
    await node.start()
    # Registration is mandatory before sending messages with rln-relay
    let manager = cast[OnchainGroupManager](node.wakuRlnRelay.groupManager)
    let idCredentials = generateCredentials()

    (waitFor manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register identity credentials" & getCurrentExceptionMsg()

    let rootUpdated = waitFor manager.updateRoots()
    info "Updated root for node", rootUpdated

    let proofRes = waitFor manager.fetchMerkleProofElements()
    if proofRes.isErr():
      assert false, "failed to fetch merkle proof: " & proofRes.error
    manager.merkleProofCache = proofRes.get()

    # RPC server setup
    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic"

    require:
      toSeq(node.wakuRelay.subscribedTopics).len == 1

    # When
    let response = await client.relayPostMessagesV1(
      DefaultPubsubTopic,
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: some(DefaultContentTopic),
        timestamp: some(now()),
      ),
    )

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  # Autosharding API

  asyncTest "Subscribe a node to an array of content topics - POST /relay/v1/auto/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    require node.mountAutoSharding(1, 8).isOk

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let contentTopics =
      @[
        ContentTopic("/app-1/2/default-content/proto"),
        ContentTopic("/app-2/2/default-content/proto"),
        ContentTopic("/app-3/2/default-content/proto"),
      ]

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.relayPostAutoSubscriptionsV1(contentTopics)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      cache.isContentSubscribed(contentTopics[0])
      cache.isContentSubscribed(contentTopics[1])
      cache.isContentSubscribed(contentTopics[2])

    check:
      # Node should be subscribed to all shards
      node.wakuRelay.subscribedTopics ==
        @["/waku/2/rs/1/5", "/waku/2/rs/1/7", "/waku/2/rs/1/2"]

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Unsubscribe a node from an array of content topics - DELETE /relay/v1/auto/subscriptions":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    require node.mountAutoSharding(1, 8).isOk

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restServer.start()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let contentTopics =
      @[
        ContentTopic("/waku/2/default-content1/proto"),
        ContentTopic("/waku/2/default-content2/proto"),
        ContentTopic("/waku/2/default-content3/proto"),
        ContentTopic("/waku/2/default-contentX/proto"),
      ]

    let cache = MessageCache.init()
    cache.contentSubscribe(contentTopics[0])
    cache.contentSubscribe(contentTopics[1])
    cache.contentSubscribe(contentTopics[2])
    cache.contentSubscribe("/waku/2/default-contentY/proto")

    installRelayApiHandlers(restServer.router, node, cache)

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    var response = await client.relayPostAutoSubscriptionsV1(contentTopics)

    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    response = await client.relayDeleteAutoSubscriptionsV1(contentTopics)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      not cache.isContentSubscribed(contentTopics[1])
      not cache.isContentSubscribed(contentTopics[2])
      not cache.isContentSubscribed(contentTopics[3])
      cache.isContentSubscribed("/waku/2/default-contentY/proto")

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Get the latest messages for a content topic - GET /relay/v1/auto/messages/{topic}":
    # Given
    let node = testWakuNode()
    await node.start()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    require node.mountAutoSharding(1, 8).isOk

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let contentTopic = DefaultContentTopic

    var messages =
      @[
        fakeWakuMessage(contentTopic = DefaultContentTopic, payload = toBytes("TEST-1"))
      ]

    # Prevent duplicate messages
    for i in 0 ..< 2:
      var msg =
        fakeWakuMessage(contentTopic = DefaultContentTopic, payload = toBytes("TEST-1"))

      while msg == messages[i]:
        msg = fakeWakuMessage(
          contentTopic = DefaultContentTopic, payload = toBytes("TEST-1")
        )

      messages.add(msg)

    let cache = MessageCache.init()

    cache.contentSubscribe(contentTopic)
    for msg in messages:
      cache.addMessage(DefaultPubsubTopic, msg)

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    # When
    let client = newRestHttpClient(initTAddress(restAddress, restPort))
    let response = await client.relayGetAutoMessagesV1(contentTopic)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_JSON
      response.data.len == 3
      response.data.all do(msg: RelayWakuMessage) -> bool:
        msg.payload == base64.encode("TEST-1") and
          msg.contentTopic.get() == DefaultContentTopic and msg.version.get() == 2 and
          msg.timestamp.get() != Timestamp(0)

    check:
      cache.isContentSubscribed(contentTopic)
      cache.getAutoMessages(contentTopic).tryGet().len == 0
        # The cache is cleared when getMessage is called

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message to a content topic - POST /relay/v1/auto/messages/{topic}":
    ## "Relay API: publish and subscribe/unsubscribe":
    # Given
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    require node.mountAutoSharding(1, 8).isOk

    let wakuRlnConfig = getWakuRlnConfig(manager = manager, index = MembershipIndex(1))

    await node.mountRlnRelay(wakuRlnConfig)
    await node.start()
    # Registration is mandatory before sending messages with rln-relay
    let manager = cast[OnchainGroupManager](node.wakuRlnRelay.groupManager)
    let idCredentials = generateCredentials()

    (waitFor manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register identity credentials" & getCurrentExceptionMsg()

    let rootUpdated = waitFor manager.updateRoots()
    info "Updated root for node", rootUpdated

    let proofRes = waitFor manager.fetchMerkleProofElements()
    if proofRes.isErr():
      assert false, "failed to fetch merkle proof: " & proofRes.error
    manager.merkleProofCache = proofRes.get()

    # RPC server setup
    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()
    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node.subscribe((kind: ContentSub, topic: DefaultContentTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to content topic: " & $error
    require:
      toSeq(node.wakuRelay.subscribedTopics).len == 1

    # When
    let response = await client.relayPostAutoMessagesV1(
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: some(DefaultContentTopic),
        timestamp: some(now()),
      )
    )

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message to an invalid content topic - POST /relay/v1/auto/messages/{topic}":
    ## "Relay API: publish and subscribe/unsubscribe":
    # Given
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    require node.mountAutoSharding(1, 8).isOk

    let wakuRlnConfig = getWakuRlnConfig(manager = manager, index = MembershipIndex(1))
    await node.mountRlnRelay(wakuRlnConfig)
    await node.start()

    # Registration is mandatory before sending messages with rln-relay
    let manager = cast[OnchainGroupManager](node.wakuRlnRelay.groupManager)
    let idCredentials = generateCredentials()

    (waitFor manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register identity credentials" & getCurrentExceptionMsg()

    let rootUpdated = waitFor manager.updateRoots()
    info "Updated root for node", rootUpdated

    let proofRes = waitFor manager.fetchMerkleProofElements()
    if proofRes.isErr():
      assert false, "failed to fetch merkle proof: " & proofRes.error
    manager.merkleProofCache = proofRes.get()

    # RPC server setup
    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()
    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let invalidContentTopic = "invalidContentTopic"
    # When
    let response = await client.relayPostAutoMessagesV1(
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: some(invalidContentTopic),
        timestamp: some(int64(2022)),
      )
    )

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data ==
        "Failed to publish. Autosharding error: invalid format: content-topic '" &
        invalidContentTopic & "' must start with slash"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message larger than maximum size - POST /relay/v1/messages/{topic}":
    # Given
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    let wakuRlnConfig = getWakuRlnConfig(manager = manager, index = MembershipIndex(1))
    await node.mountRlnRelay(wakuRlnConfig)
    await node.start()

    # Registration is mandatory before sending messages with rln-relay
    let manager = cast[OnchainGroupManager](node.wakuRlnRelay.groupManager)
    let idCredentials = generateCredentials()

    (waitFor manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register identity credentials" & getCurrentExceptionMsg()

    let rootUpdated = waitFor manager.updateRoots()
    info "Updated root for node", rootUpdated

    let proofRes = waitFor manager.fetchMerkleProofElements()
    if proofRes.isErr():
      assert false, "failed to fetch merkle proof: " & proofRes.error
    manager.merkleProofCache = proofRes.get()

    # RPC server setup
    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic: " & $error
    require:
      toSeq(node.wakuRelay.subscribedTopics).len == 1

    # When
    let response = await client.relayPostMessagesV1(
      DefaultPubsubTopic,
      RelayWakuMessage(
        payload: base64.encode(getByteSequence(DefaultMaxWakuMessageSize)),
          # Message will be bigger than the max size
        contentTopic: some(DefaultContentTopic),
        timestamp: some(int64(2022)),
      ),
    )

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data ==
        fmt"Failed to publish: Message size exceeded maximum of {DefaultMaxWakuMessageSize} bytes"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "Post a message larger than maximum size - POST /relay/v1/auto/messages/{topic}":
    # Given
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    require node.mountAutoSharding(1, 8).isOk

    let wakuRlnConfig = getWakuRlnConfig(manager = manager, index = MembershipIndex(1))
    await node.mountRlnRelay(wakuRlnConfig)
    await node.start()

    # Registration is mandatory before sending messages with rln-relay
    let manager = cast[OnchainGroupManager](node.wakuRlnRelay.groupManager)
    let idCredentials = generateCredentials()

    (waitFor manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register identity credentials" & getCurrentExceptionMsg()

    let rootUpdated = waitFor manager.updateRoots()
    info "Updated root for node", rootUpdated

    let proofRes = waitFor manager.fetchMerkleProofElements()
    if proofRes.isErr():
      assert false, "failed to fetch merkle proof: " & proofRes.error
    manager.merkleProofCache = proofRes.get()

    # RPC server setup
    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic: " & $error
    require:
      toSeq(node.wakuRelay.subscribedTopics).len == 1

    # When
    let response = await client.relayPostAutoMessagesV1(
      RelayWakuMessage(
        payload: base64.encode(getByteSequence(DefaultMaxWakuMessageSize)),
          # Message will be bigger than the max size
        contentTopic: some(DefaultContentTopic),
        timestamp: some(int64(2022)),
      )
    )

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data ==
        fmt"Failed to publish: Message size exceeded maximum of {DefaultMaxWakuMessageSize} bytes"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()
