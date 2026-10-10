{.used.}

import
  results,
  std/[json, sequtils, strformat, strutils, tempfiles, osproc, uri],
  stew/byteutils,
  testutils/unittests,
  presto,
  presto/client as presto_client,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/pubsub
import brokers/broker_context
import
  rest/message_cache,
  rest/server,
  rest/client,
  rest/responses,
  rest/kernel_api/relay/types,
  rest/kernel_api/relay/handlers as relay_rest_interface,
  rest/kernel_api/relay/client as relay_rest_client
import
  logos_delivery/waku/[
    common/base64,
    waku_core,
    waku_node,
    waku_relay,
    rln,
    rln/rln_plugin,
    rln/types as rln_types,
    waku_archive,
    waku_archive/archive_metrics,
  ],
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../testlib/testasync,
  ../testlib/rest_requests,
  ../resources/payloads,
  ../waku_archive/archive_utils,
  ../waku_rln_relay/[rln/waku_rln_relay_utils, utils_onchain]

proc testWakuNode(): WakuNode =
  let
    privkey = generateSecp256k1Key()
    bindIp = parseIpAddress("0.0.0.0")
    extIp = parseIpAddress("127.0.0.1")
    port = Port(0)

  newTestWakuNode(privkey, bindIp, port, Opt.some(extIp), Opt.some(port))

proc rejectFirstMessageAsRlnInvalid(node: WakuNode) =
  ## Registers a relay validator that rejects the first message it sees with
  ## the RLN validator's error marker, then accepts everything.
  var rejected = false
  node.wakuRelay.addValidator(
    proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[pubsub.ValidationResult] {.async.} =
      if rejected:
        return pubsub.ValidationResult.Accept
      rejected = true
      return pubsub.ValidationResult.Reject,
    RlnValidatorErrorMsg & ": simulated",
  )

type StubRlnCalls = ref object
  ## How often the node asked the stub RLN backend for a proof or a refresh.
  generateCalls: int
  refreshCalls: int

proc mountStubRln(node: WakuNode, validProof: seq[byte]): StubRlnCalls =
  ## Mounts an RLN backend that accepts only `validProof` and cannot generate
  ## proofs, like a node without a usable membership.
  let calls = StubRlnCalls()

  proc validate(
      message: WakuMessage
  ): Future[Result[rln_types.ValidationResult, RlnError]] {.async.} =
    if message.proof == validProof:
      return ok(rln_types.ValidationResult(verdict: ProofVerdict.Valid))
    return ok(rln_types.ValidationResult(verdict: ProofVerdict.Invalid))

  proc generate(message: WakuMessage): Future[Result[seq[byte], RlnError]] {.async.} =
    calls.generateCalls.inc()
    return err(RlnError.notReady("no usable RLN membership"))

  proc refresh() {.gcsafe, raises: [].} =
    calls.refreshCalls.inc()

  node.mountRln(
    RlnPlugin(
      name: "stub",
      validateProof: validate,
      generateProof: generate,
      onProofRejected: refresh,
    ),
    RlnCommonConf(),
  )
  return calls

suite "Waku v2 Rest API - Relay":
  var anvilProc {.threadVar.}: Process
  var manager {.threadVar.}: RlnEvmGroupManager

  setup:
    anvilProc = runAnvil(stateFile = Opt.some(DEFAULT_ANVIL_STATE_PATH))
    manager = waitFor setupRlnEvm(deployContracts = false)

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

    var messages = @[
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

    let rln = await node.mountOnchainRln(wakuRlnConfig)
    await node.start()
    # Registration is mandatory before sending messages with rln-relay
    let manager = cast[RlnEvmGroupManager](rln.groupManager)
    let idCredentials = generateCredentials()

    (await manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register identity credentials" & getCurrentExceptionMsg()

    let rootUpdated = await manager.updateRoots()
    info "Updated root for node", rootUpdated

    let proofRes = await manager.fetchMerkleProofElements()
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
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
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

  asyncTest "Post a message to a not subscribed pubsub topic - POST /relay/v1/messages/{topic}":
    # Given
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await node.start()

    # RPC server setup
    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let cache = MessageCache.init()

    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()
    defer:
      await restServer.stop()
      await restServer.closeWait()
      await node.stop()

    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    check node.wakuRelay.subscribedTopics.toSeq().len == 0

    # When
    let response = await client.relayPostMessagesV1(
      DefaultPubsubTopic,
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
      ),
    )

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data ==
        "Failed to publish: Node not subscribed to topic: " & DefaultPubsubTopic

  asyncTest "A message posted twice is stored once and counted once as written - POST /relay/v1/messages/{topic}":
    # Given a relay node with a sqlite archive, subscribed to a pubsub topic
    let node = testWakuNode()
    let driver = newSqliteArchiveDriver()
    check:
      (await node.mountRelay()).isOk()
      node.mountArchive(driver).isOk()
    await node.start()
    defer:
      await node.stop()

    let restServer = WakuRestServerRef.init(parseIpAddress("0.0.0.0"), Port(0)).tryGet()
    installRelayApiHandlers(restServer.router, node, MessageCache.init())
    restServer.start()
    defer:
      await restServer.stop()
      await restServer.closeWait()

    let client = newRestHttpClient(restServer.localAddress())
    let subscribeResponse = await client.relayPostSubscriptionsV1(@[DefaultPubsubTopic])
    check subscribeResponse.status == 200

    let
      insertsBefore = insertCount(relayIngress)
      failuresBefore = errorCount(insertFailure)
      shardBefore = messagesPerShard("0")
      message = RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
      )

    # When the same message is posted twice
    let firstResponse = await client.relayPostMessagesV1(DefaultPubsubTopic, message)
    let secondResponse = await client.relayPostMessagesV1(DefaultPubsubTopic, message)

    # Then
    check:
      firstResponse.status == 200
      secondResponse.status == 200
      (await driver.getMessagesCount()) == ArchiveDriverResult[int64].ok(1)
      insertCount(relayIngress) == insertsBefore + 1
      messagesPerShard("0") == shardBefore + 1
      errorCount(insertFailure) == failuresBefore

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

    let contentTopics = @[
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
    check node.mountAutoSharding(1, 8).isOk

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restServer.start()

    restPort = restServer.httpServer.address.port # update with bound port for client use

    let contentTopics = @[
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
      node.wakuRelay.subscribedTopics.toSeq().len == 1

    response = await client.relayDeleteAutoSubscriptionsV1(contentTopics)

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"

    check:
      not cache.isContentSubscribed(contentTopics[0])
      not cache.isContentSubscribed(contentTopics[1])
      not cache.isContentSubscribed(contentTopics[2])
      not cache.isContentSubscribed(contentTopics[3])
      cache.isContentSubscribed("/waku/2/default-contentY/proto")
      node.wakuRelay.subscribedTopics.toSeq().len == 0

    # When unsubscribing from a content topic never subscribed
    response = await client.relayDeleteAutoSubscriptionsV1(
      @[ContentTopic("/waku/2/default-contentZ/proto")]
    )

    # Then
    check:
      response.status == 200
      $response.contentType == $MIMETYPE_TEXT
      response.data == "OK"
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

    var messages = @[
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
    var meshNode: WakuNode
    lockNewGlobalBrokerContext:
      meshNode = testWakuNode()
      (await meshNode.mountRelay()).isOkOr:
        assert false, "Failed to mount relay"
      require meshNode.mountAutoSharding(1, 8).isOk

      let wakuRlnConfig =
        getWakuRlnConfig(manager = manager, index = MembershipIndex(1))

      discard await meshNode.mountOnchainRln(wakuRlnConfig)
      await meshNode.start()
      const testPubsubTopic = PubsubTopic("/waku/2/rs/1/0")
      proc dummyHandler(
          topic: PubsubTopic, msg: WakuMessage
      ): Future[void] {.async, gcsafe.} =
        discard

      meshNode.subscribe((kind: ContentSub, topic: DefaultContentTopic), dummyHandler).isOkOr:
        raiseAssert "Failed to subscribe meshNode: " & error

    var node: WakuNode
    var rln: RlnEvm
    lockNewGlobalBrokerContext:
      node = testWakuNode()
      (await node.mountRelay()).isOkOr:
        assert false, "Failed to mount relay"
      require node.mountAutoSharding(1, 8).isOk

      let wakuRlnConfig =
        getWakuRlnConfig(manager = manager, index = MembershipIndex(1))

      rln = await node.mountOnchainRln(wakuRlnConfig)
      await node.start()
      await node.connectToNodes(@[meshNode.peerInfo.toRemotePeerInfo()])

    # Registration is mandatory before sending messages with rln-relay
    let manager = cast[RlnEvmGroupManager](rln.groupManager)
    let idCredentials = generateCredentials()

    (await manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register identity credentials" & getCurrentExceptionMsg()

    let rootUpdated = await manager.updateRoots()
    info "Updated root for node", rootUpdated

    let proofRes = await manager.fetchMerkleProofElements()
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
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
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
    let rln = await node.mountOnchainRln(wakuRlnConfig)
    await node.start()

    # Registration is mandatory before sending messages with rln-relay
    let manager = cast[RlnEvmGroupManager](rln.groupManager)
    let idCredentials = generateCredentials()

    (await manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register identity credentials" & getCurrentExceptionMsg()

    let rootUpdated = await manager.updateRoots()
    info "Updated root for node", rootUpdated

    let proofRes = await manager.fetchMerkleProofElements()
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
        contentTopic: Opt.some(invalidContentTopic),
        timestamp: Opt.some(now()),
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
    let rln = await node.mountOnchainRln(wakuRlnConfig)
    await node.start()

    # Registration is mandatory before sending messages with rln-relay
    let manager = cast[RlnEvmGroupManager](rln.groupManager)
    let idCredentials = generateCredentials()

    (await manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register identity credentials" & getCurrentExceptionMsg()

    let rootUpdated = await manager.updateRoots()
    info "Updated root for node", rootUpdated

    let proofRes = await manager.fetchMerkleProofElements()
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
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
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
    let rln = await node.mountOnchainRln(wakuRlnConfig)
    await node.start()

    # Registration is mandatory before sending messages with rln-relay
    let manager = cast[RlnEvmGroupManager](rln.groupManager)
    let idCredentials = generateCredentials()

    (await manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register identity credentials" & getCurrentExceptionMsg()

    let rootUpdated = await manager.updateRoots()
    info "Updated root for node", rootUpdated

    let proofRes = await manager.fetchMerkleProofElements()
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
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
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

  asyncTest "Post a message timestamped outside the RLN bound returns 400 - POST /relay/v1/messages/{topic}":
    ## Proof generation refuses a timestamp further from the clock than the
    ## validators accept. The fault is in the request, so the handler answers
    ## 400 like a validator rejection, not 500.
    # Given
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    let wakuRlnConfig = getWakuRlnConfig(manager = manager, index = MembershipIndex(1))
    let rln = await node.mountOnchainRln(wakuRlnConfig)
    await node.start()

    # Registration is mandatory before sending messages with rln-relay
    let manager = cast[RlnEvmGroupManager](rln.groupManager)
    let idCredentials = generateCredentials()

    (await manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register identity credentials" & getCurrentExceptionMsg()

    let rootUpdated = await manager.updateRoots()
    info "Updated root for node", rootUpdated

    let proofRes = await manager.fetchMerkleProofElements()
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
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(int64(2022)), # nanoseconds: the start of 1970
      ),
    )

    # Then
    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.startsWith(
        "Failed to publish: error appending RLN proof to message:"
      )
      "beyond the accepted" in response.data

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "RLN rejection returns 503 and schedules a refresh - POST /relay/v1/messages/{topic}":
    ## When the local validator rejects the published message as RLN-invalid,
    ## the handler must detect the RlnValidatorErrorMsg, schedule a background
    ## merkle proof refresh, and fail early with 503 +
    ## RlnProofRefreshScheduledMsg. A client retry then succeeds. The proof
    ## generator repairs a stale cached path before validation, so the
    ## rejection is injected with a one-shot validator.
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    let wakuRlnConfig = getWakuRlnConfig(
      manager = manager,
      index = MembershipIndex(1),
      epochSizeSec = 600,
      userMessageLimit = 20,
    )
    let rln = await node.mountOnchainRln(wakuRlnConfig)
    await node.start()

    let manager = cast[RlnEvmGroupManager](rln.groupManager)
    let idCredentials = generateCredentials()
    (await manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register: " & getCurrentExceptionMsg()

    let rootUpdated = await manager.updateRoots()
    info "Updated root", rootUpdated

    let proofRes = await manager.fetchMerkleProofElements()
    assert proofRes.isOk(), "failed to fetch merkle proof: " & proofRes.error
    let goodCache = proofRes.get()
    manager.merkleProofCache = goodCache

    node.rejectFirstMessageAsRlnInvalid()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port
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

    let response = await client.relayPostMessagesV1(
      DefaultPubsubTopic,
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
      ),
    )

    # The handler fails early with the retry signal; the refresh runs detached.
    check:
      response.status == 503
      $response.contentType == $MIMETYPE_TEXT
      response.data.contains(RlnProofRefreshScheduledMsg)

    let inFlight = manager.proofPathRefreshInFlightFut
    if not inFlight.isNil():
      await inFlight.join()
    check manager.merkleProofCache == goodCache # refresh restored the correct path

    # A client retry now succeeds against the refreshed path.
    let retryResponse = await client.relayPostMessagesV1(
      DefaultPubsubTopic,
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
      ),
    )

    check:
      retryResponse.status == 200
      retryResponse.data == "OK"

    await restServer.stop()
    await restServer.closeWait()
    await node.stop()

  asyncTest "RLN rejection returns 503 and schedules a refresh - POST /relay/v1/auto/messages/{topic}":
    ## Same fail-fast behavior as the static-sharding handler, exercised via
    ## the auto-sharding endpoint. A relay-only mesh node is connected so that
    ## node.publish() has a gossipsub peer and the client retry can return
    ## success.

    # Relay-only mesh node — no RLN needed, just provides a gossipsub peer.
    let meshNode = testWakuNode()
    (await meshNode.mountRelay()).isOkOr:
      assert false, "Failed to mount relay on mesh node"
    require meshNode.mountAutoSharding(1, 8).isOk
    await meshNode.start()
    let meshHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      discard
    meshNode.subscribe((kind: ContentSub, topic: DefaultContentTopic), meshHandler).isOkOr:
      assert false, "Failed to subscribe mesh node"

    var node: WakuNode
    var rln: RlnEvm
    lockNewGlobalBrokerContext:
      node = testWakuNode()
      (await node.mountRelay()).isOkOr:
        assert false, "Failed to mount relay"
      require node.mountAutoSharding(1, 8).isOk

      let wakuRlnConfig = getWakuRlnConfig(
        manager = manager,
        index = MembershipIndex(1),
        epochSizeSec = 600,
        userMessageLimit = 20,
      )
      rln = await node.mountOnchainRln(wakuRlnConfig)
      await node.start()
      await node.connectToNodes(@[meshNode.peerInfo.toRemotePeerInfo()])

    let manager = cast[RlnEvmGroupManager](rln.groupManager)
    let idCredentials = generateCredentials()
    (await manager.register(idCredentials, UserMessageLimit(20))).isOkOr:
      assert false, "Failed to register: " & getCurrentExceptionMsg()

    let rootUpdated = await manager.updateRoots()
    info "Updated root", rootUpdated

    let proofRes = await manager.fetchMerkleProofElements()
    assert proofRes.isOk(), "failed to fetch merkle proof: " & proofRes.error
    let goodCache = proofRes.get()
    manager.merkleProofCache = goodCache

    node.rejectFirstMessageAsRlnInvalid()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port
    let cache = MessageCache.init()
    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()
    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node.subscribe((kind: ContentSub, topic: DefaultContentTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to content topic"

    let response = await client.relayPostAutoMessagesV1(
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
      )
    )

    # The handler fails early with the retry signal; the refresh runs detached.
    check:
      response.status == 503
      $response.contentType == $MIMETYPE_TEXT
      response.data.contains(RlnProofRefreshScheduledMsg)

    let inFlight = manager.proofPathRefreshInFlightFut
    if not inFlight.isNil():
      await inFlight.join()
    check manager.merkleProofCache == goodCache

    # A client retry now succeeds against the refreshed path.
    let retryResponse = await client.relayPostAutoMessagesV1(
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
      )
    )

    check:
      retryResponse.status == 200
      retryResponse.data == "OK"

    await restServer.stop()
    await restServer.closeWait()
    await allFutures(node.stop(), meshNode.stop())

  asyncTest "A client-supplied RLN proof is published without generating one - POST /relay/v1/messages/{topic}":
    ## The node keeps the proof the client sent, so it spends none of its own
    ## quota and publishes even without a usable membership.
    let clientProof = @[1'u8, 2, 3]
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    let rlnCalls = node.mountStubRln(validProof = clientProof)
    await node.start()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port
    let cache = MessageCache.init()
    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()
    defer:
      await restServer.stop()
      await restServer.closeWait()
      await node.stop()
    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic"

    let response = await client.relayPostMessagesV1(
      DefaultPubsubTopic,
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
        proof: Opt.some(base64.encode(clientProof)),
      ),
    )

    # The stub validator accepts only the client's proof, so a 200 means it
    # was published as sent.
    check:
      response.status == 200
      response.data == "OK"
      rlnCalls.generateCalls == 0

  asyncTest "An RLN-invalid client proof returns 400 and schedules no refresh - POST /relay/v1/messages/{topic}":
    ## A refresh of the node's own proof state cannot make a client's proof
    ## valid, so the rejection is final instead of a retry signal.
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    let rlnCalls = node.mountStubRln(validProof = @[1'u8, 2, 3])
    await node.start()

    var restPort = Port(0)
    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, restPort).tryGet()
    restPort = restServer.httpServer.address.port
    let cache = MessageCache.init()
    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()
    defer:
      await restServer.stop()
      await restServer.closeWait()
      await node.stop()
    let client = newRestHttpClient(initTAddress(restAddress, restPort))

    let simpleHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic"

    let response = await client.relayPostMessagesV1(
      DefaultPubsubTopic,
      RelayWakuMessage(
        payload: base64.encode("TEST-PAYLOAD"),
        contentTopic: Opt.some(DefaultContentTopic),
        timestamp: Opt.some(now()),
        proof: Opt.some(base64.encode(@[9'u8, 9, 9])),
      ),
    )

    check:
      response.status == 400
      $response.contentType == $MIMETYPE_TEXT
      response.data.contains(RlnValidatorErrorMsg)
      not response.data.contains(RlnProofRefreshScheduledMsg)
      rlnCalls.generateCalls == 0
      rlnCalls.refreshCalls == 0

  asyncTest "A message published on one node is read back on its relay peer - POST /relay/v1/messages/{topic}, GET /relay/v1/messages/{topic}":
    # Given two relay nodes, each behind its own REST server
    let publisher = testWakuNode()
    (await publisher.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await publisher.start()
    defer:
      await publisher.stop()

    var receiver: WakuNode
    lockNewGlobalBrokerContext:
      receiver = testWakuNode()
      (await receiver.mountRelay()).isOkOr:
        assert false, "Failed to mount relay"
      await receiver.start()
    defer:
      await receiver.stop()

    let restAddress = parseIpAddress("0.0.0.0")
    let
      publisherServer = WakuRestServerRef.init(restAddress, Port(0)).tryGet()
      receiverServer = WakuRestServerRef.init(restAddress, Port(0)).tryGet()
    installRelayApiHandlers(publisherServer.router, publisher, MessageCache.init())
    installRelayApiHandlers(receiverServer.router, receiver, MessageCache.init())
    publisherServer.start()
    receiverServer.start()
    defer:
      await allFutures(publisherServer.stop(), receiverServer.stop())
      await allFutures(publisherServer.closeWait(), receiverServer.closeWait())

    let
      publisherClient = newRestHttpClient(publisherServer.localAddress())
      receiverClient = newRestHttpClient(receiverServer.localAddress())
      otherTopic = $RelayShard(clusterId: DefaultClusterId, shardId: 1)

    # Given both nodes subscribed over REST to two pubsub topics and connected
    for client in [publisherClient, receiverClient]:
      let response =
        await client.relayPostSubscriptionsV1(@[DefaultPubsubTopic, otherTopic])
      require response.status == 200
    await publisher.connectToNodes(@[receiver.peerInfo.toRemotePeerInfo()])
    checkUntilTimeout:
      publisher.hasGossipsubPeer(DefaultPubsubTopic, receiver.peerInfo.peerId)

    # When a message with every optional field set is published on one node
    let sent = RelayWakuMessage(
      payload: base64.encode(EMOJI),
      contentTopic: Opt.some(ContentTopic("/test/1/wäku-relay/proto")),
      version: Opt.some(Natural(10)),
      timestamp: Opt.some(now()),
      meta: Opt.some(base64.encode("test-meta")),
      ephemeral: Opt.some(true),
    )
    let postResponse =
      await publisherClient.relayPostMessagesV1(DefaultPubsubTopic, sent)
    check:
      postResponse.status == 200
      postResponse.data == "OK"

    # Then the peer reads it back over REST with every field unchanged
    let received = await receiverClient.waitForRelayMessages(DefaultPubsubTopic, 1)
    check:
      received.mapIt(it.payload) == @[sent.payload]
      received.mapIt(it.contentTopic) == @[sent.contentTopic]
      received.mapIt(it.version) == @[sent.version]
      received.mapIt(it.timestamp) == @[sent.timestamp]
      received.mapIt(it.meta) == @[sent.meta]
      received.mapIt(it.ephemeral) == @[sent.ephemeral]

    # Then nothing arrives on the other subscribed topic
    let otherResponse = await receiverClient.relayGetMessagesV1(otherTopic)
    check:
      otherResponse.status == 200
      otherResponse.data.len == 0

    # When a message without a timestamp is published
    let untimed = RelayWakuMessage(
      payload: base64.encode("TEST-PAYLOAD"),
      contentTopic: Opt.some(DefaultContentTopic),
    )
    let before = now()
    let untimedResponse =
      await publisherClient.relayPostMessagesV1(DefaultPubsubTopic, untimed)
    check untimedResponse.status == 200

    # Then the peer reads it back with a timestamp the publishing node assigned
    let untimedReceived =
      await receiverClient.waitForRelayMessages(DefaultPubsubTopic, 1)
    check:
      untimedReceived.mapIt(it.payload) == @[untimed.payload]
      untimedReceived.mapIt(it.timestamp.get(0) >= before) == @[true]

  asyncTest "Get messages of a not subscribed topic returns 404 - GET /relay/v1/messages/{topic}, GET /relay/v1/auto/messages/{topic}":
    # Given
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await node.start()
    defer:
      await node.stop()

    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, Port(0)).tryGet()
    installRelayApiHandlers(restServer.router, node, MessageCache.init())
    restServer.start()
    defer:
      await restServer.stop()
      await restServer.closeWait()

    # When getting messages of a pubsub topic
    let staticResponse = await issueRequest(
      restServer.getAddress("/relay/v1/messages/" & encodeUrl(DefaultPubsubTopic))
    )

    # Then the response has an empty body
    check:
      staticResponse.status == 404
      staticResponse.data == ""

    # When getting messages of a content topic
    let autoResponse = await issueRequest(
      restServer.getAddress("/relay/v1/auto/messages/" & encodeUrl(DefaultContentTopic))
    )

    # Then the response body is the content topic
    check:
      autoResponse.status == 404
      autoResponse.data == DefaultContentTopic

  asyncTest "Post a message with an invalid body - POST /relay/v1/messages/{topic}":
    # Given a node subscribed to the topic, so only the body decides the response
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await node.start()
    defer:
      await node.stop()

    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, Port(0)).tryGet()
    installRelayApiHandlers(restServer.router, node, MessageCache.init())
    restServer.start()
    defer:
      await restServer.stop()
      await restServer.closeWait()

    let client = newRestHttpClient(restServer.localAddress())
    require (await client.relayPostSubscriptionsV1(@[DefaultPubsubTopic])).status == 200

    let
      path = "/relay/v1/messages/" & encodeUrl(DefaultPubsubTopic)
      jsonHeader: seq[HttpHeaderTuple] = @[("Content-Type", "application/json")]
      payload = string(base64.encode("TEST-PAYLOAD"))
      validFields =
        "\"payload\": \"" & payload & "\", \"contentTopic\": \"" & DefaultContentTopic &
        "\""

    # When the body does not decode into a message
    let invalidBodies = [
      $ %*{"contentTopic": DefaultContentTopic},
      $ %*{"payload": "", "contentTopic": DefaultContentTopic},
      $ %*{"payload": {"key": "YWFh"}, "contentTopic": DefaultContentTopic},
      $ %*{"payload": 1234567890, "contentTopic": DefaultContentTopic},
      $ %*{"payload": ["YWFh"], "contentTopic": DefaultContentTopic},
      $ %*{"payload": true, "contentTopic": DefaultContentTopic},
      "{" & validFields & ", \"payload\": \"" & payload & "\"}",
      $ %*{"payload": payload},
      $ %*{"payload": payload, "contentTopic": ""},
      $ %*{"payload": payload, "contentTopic": 1234567890},
      $ %*{
        "payload": payload,
        "contentTopic": DefaultContentTopic,
        "timestamp": "1700000000000000000",
      },
      $ %*{"payload": payload, "contentTopic": DefaultContentTopic, "timestamp": 1.7e18},
      $ %*{
        "payload": payload,
        "contentTopic": DefaultContentTopic,
        "timestamp": [1700000000000000000],
      },
      $ %*{
        "payload": payload,
        "contentTopic": DefaultContentTopic,
        "timestamp": {"time": 1700000000000000000},
      },
      "{" & validFields & ", \"timestamp\": null}",
      "{" & validFields & ", \"timestamp\": 9223372036854775808}",
      $ %*{"payload": payload, "contentTopic": DefaultContentTopic, "version": 2.1},
    ]

    # Then each is rejected as an invalid content body
    for body in invalidBodies:
      let response =
        await issueRequest(restServer.getAddress(path), MethodPost, jsonHeader, body)
      check:
        response.status == 400
        response.data.startsWith(
          "Invalid content body, could not decode: Unable to deserialize data: body("
        )

    # When a field that must be base64 is not
    let notBase64Bodies = [
      $ %*{"payload": "Hello World!", "contentTopic": DefaultContentTopic},
      $ %*{
        "payload": payload, "contentTopic": DefaultContentTopic, "meta": "Hello World!"
      },
    ]

    # Then it is rejected as an incorrect base64 string
    for body in notBase64Bodies:
      let response =
        await issueRequest(restServer.getAddress(path), MethodPost, jsonHeader, body)
      check:
        response.status == 400
        response.data == "Incorrect base64 string"

  asyncTest "Post a message with an invalid body - POST /relay/v1/auto/messages":
    # Given a node with relay mounted
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await node.start()
    defer:
      await node.stop()

    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, Port(0)).tryGet()
    installRelayApiHandlers(restServer.router, node, MessageCache.init())
    restServer.start()
    defer:
      await restServer.stop()
      await restServer.closeWait()

    # When the body has no payload
    let response = await issueRequest(
      restServer.getAddress("/relay/v1/auto/messages"),
      MethodPost,
      @[("Content-Type", "application/json")],
      $ %*{"contentTopic": "/app/1/chat/proto"},
    )

    # Then the answer carries the decoder's reason
    check:
      response.status == 400
      response.data.startsWith(
        "Invalid content body, could not decode: Unable to deserialize data: body("
      )
      response.data.contains("Field `payload` is missing or empty")

  asyncTest "Post a message with unknown fields - POST /relay/v1/messages/{topic}":
    # Given a node subscribed to the topic
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await node.start()
    defer:
      await node.stop()

    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, Port(0)).tryGet()
    installRelayApiHandlers(restServer.router, node, MessageCache.init())
    restServer.start()
    defer:
      await restServer.stop()
      await restServer.closeWait()

    let client = newRestHttpClient(restServer.localAddress())
    require (await client.relayPostSubscriptionsV1(@[DefaultPubsubTopic])).status == 200

    let
      path = "/relay/v1/messages/" & encodeUrl(DefaultPubsubTopic)
      jsonHeader: seq[HttpHeaderTuple] = @[("Content-Type", "application/json")]
      payload = string(base64.encode("TEST-PAYLOAD"))

    # When the body carries fields the node does not know
    let bodies = [
      $ %*{
        "extraField": {"nested": [1, {"a": "b"}]},
        "payload": payload,
        "contentTopic": DefaultContentTopic,
      },
      $ %*{
        "payload": payload,
        "contentTopic": DefaultContentTopic,
        "extraField": "extraValue",
      },
    ]

    # Then the body still decodes into a message
    for body in bodies:
      let response =
        await issueRequest(restServer.getAddress(path), MethodPost, jsonHeader, body)
      check:
        not response.data.startsWith("Invalid content body, could not decode: ")
        response.status != 400

  asyncTest "Subscribe and unsubscribe with an empty list, a repeated topic, an invalid topic and a shard of another cluster - POST and DELETE /relay/v1/subscriptions":
    # Given
    let node = testWakuNode()
    (await node.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await node.start()
    defer:
      await node.stop()

    let restAddress = parseIpAddress("0.0.0.0")
    let restServer = WakuRestServerRef.init(restAddress, Port(0)).tryGet()
    let cache = MessageCache.init()
    installRelayApiHandlers(restServer.router, node, cache)
    restServer.start()
    defer:
      await restServer.stop()
      await restServer.closeWait()

    let client = newRestHttpClient(restServer.localAddress())
    let noTopics = newSeq[PubsubTopic]()

    # When subscribing and unsubscribing with an empty list
    let emptyPost = await client.relayPostSubscriptionsV1(noTopics)
    let emptyDelete = await client.relayDeleteSubscriptionsV1(noTopics)

    # Then both succeed and nothing is subscribed
    check:
      emptyPost.status == 200
      emptyDelete.status == 200
      toSeq(node.wakuRelay.subscribedTopics).len == 0

    # When subscribing to the same topic twice
    let firstPost = await client.relayPostSubscriptionsV1(@[DefaultPubsubTopic])
    let secondPost = await client.relayPostSubscriptionsV1(@[DefaultPubsubTopic])

    # Then both succeed and the topic is subscribed once
    check:
      firstPost.status == 200
      secondPost.status == 200
      toSeq(node.wakuRelay.subscribedTopics) == @[DefaultPubsubTopic]

    # When unsubscribing with an invalid topic in the list
    let invalidTopic = "/test/2/this/is/a/content/topic/1"
    let invalidDelete =
      await client.relayDeleteSubscriptionsV1(@[DefaultPubsubTopic, invalidTopic])

    # Then the request fails and the valid topic stays subscribed
    check:
      invalidDelete.status == 400
      $invalidDelete.contentType == $MIMETYPE_TEXT
      invalidDelete.data ==
        "Invalid pubsub topic(s): @[\"/test/2/this/is/a/content/topic/1\"]"
      node.wakuRelay.isSubscribed(DefaultPubsubTopic)
      cache.isPubsubSubscribed(DefaultPubsubTopic)

    # When subscribing to a shard of another cluster
    let otherClusterShard = $RelayShard(clusterId: 199, shardId: 0)
    let otherClusterPost = await client.relayPostSubscriptionsV1(@[otherClusterShard])

    # Then it is subscribed although the node is on cluster 0
    check:
      otherClusterPost.status == 200
      node.wakuRelay.isSubscribed(otherClusterShard)
      cache.isPubsubSubscribed(otherClusterShard)
