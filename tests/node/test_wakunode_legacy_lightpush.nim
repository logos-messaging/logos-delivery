{.used.}

import
  std/[options, tempfiles, net, osproc, strutils],
  testutils/unittests,
  chronos,
  std/strformat,
  libp2p/crypto/crypto

import
  logos_delivery/waku/[
    waku_core,
    node/peer_manager,
    waku_node,
    waku_lightpush_legacy,
    waku_lightpush_legacy/common,
    waku_lightpush_legacy/protocol_metrics,
    rln,
    rln/constants,
  ],
  ../testlib/[wakucore, wakunode, testasync, futures, testutils],
  ../resources/payloads,
  ../waku_rln_relay/[rln/waku_rln_relay_utils, utils_onchain]

suite "Waku Legacy Lightpush - End To End":
  var
    server {.threadvar.}: WakuNode
    client {.threadvar.}: WakuNode

    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic
    message {.threadvar.}: WakuMessage

  asyncSetup:
    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey)
    client = newTestWakuNode(clientKey)

    await allFutures(server.start(), client.start())
    await server.start()

    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    check (await server.mountLegacyLightpush()).isOk() # without rln-relay
    client.mountLegacyLightpushClient()

    serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic
    message = fakeWakuMessage()

  asyncTeardown:
    await server.stop()

  suite "Assessment of Message Relaying Mechanisms":
    asyncTest "Via 11/WAKU2-RELAY from Relay/Full Node":
      # Given a light lightpush client
      let lightpushClient = newTestWakuNode(generateSecp256k1Key())
      lightpushClient.mountLegacyLightpushClient()

      # When the client publishes a message
      let publishResponse = await lightpushClient.legacyLightpushPublish(
        some(pubsubTopic), message, serverRemotePeerInfo
      )

      if not publishResponse.isOk():
        echo "Publish failed: ", publishResponse.error()

      # Then the message is not relayed but not due to RLN
      assert publishResponse.isErr(), "We expect an error response"

      assert (publishResponse.error == protocol_metrics.notPublishedAnyPeer),
        "incorrect error response"

  suite "Waku LightPush Validation Tests":
    asyncTest "Validate message size exceeds limit":
      let msgOverLimit = fakeWakuMessage(
        contentTopic = contentTopic,
        payload = getByteSequence(DefaultMaxWakuMessageSize + 64 * 1024),
      )

      # When the client publishes an over-limit message
      let publishResponse = await client.legacyLightpushPublish(
        some(pubsubTopic), msgOverLimit, serverRemotePeerInfo
      )

      check:
        publishResponse.isErr()
        publishResponse.error ==
          fmt"Message size exceeded maximum of {DefaultMaxWakuMessageSize} bytes"

suite "RLN Proofs as a Lightpush Service":
  var
    server {.threadvar.}: WakuNode
    client {.threadvar.}: WakuNode
    anvilProc {.threadvar.}: Process
    manager {.threadvar.}: OnchainGroupManager
    wakuRlnConfig {.threadvar.}: WakuRlnConfig

    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic
    message {.threadvar.}: WakuMessage

  asyncSetup:
    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey)
    client = newTestWakuNode(clientKey)

    anvilProc = runAnvil(stateFile = some(DEFAULT_ANVIL_STATE_PATH))
    manager = waitFor setupOnchainGroupManager(deployContracts = false)

    # mount rln-relay
    # match prod epoch window to reduce test flake
    wakuRlnConfig = getWakuRlnConfig(
      manager = manager,
      userMessageLimit = 20,
      index = MembershipIndex(1),
      epochSizeSec = 600,
    )

    await allFutures(server.start(), client.start())
    await server.start()

    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await server.setRlnValidator(wakuRlnConfig)
    check (await server.mountLegacyLightPush()).isOk()
    client.mountLegacyLightPushClient()

    let manager1 = cast[OnchainGroupManager](server.rln.groupManager)
    let idCredentials1 = generateCredentials()

    (waitFor manager1.register(idCredentials1, UserMessageLimit(20))).isOkOr:
      assert false, "error returned when calling register: " & error

    let rootUpdated1 = waitFor manager1.updateRoots()
    info "Updated root for node1", rootUpdated1

    if rootUpdated1:
      let proofResult = waitFor manager1.fetchMerkleProofElements()
      if proofResult.isErr():
        error "Failed to fetch Merkle proof", error = proofResult.error
      manager1.merkleProofCache = proofResult.get()

    serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()
    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic
    message = fakeWakuMessage()

  asyncTeardown:
    await server.stop()
    stopAnvil(anvilProc)

  suite "Lightpush attaching RLN proofs":
    asyncTest "Message is published when RLN enabled":
      # Given a light lightpush client
      let lightpushClient = newTestWakuNode(generateSecp256k1Key())
      lightpushClient.mountLegacyLightPushClient()

      # Attach the RLN proof. In production the client mounts RLN and generates the
      # proof in legacyLightpushPublish; here we generate it using the server's RLN
      # instance since both ends share group state via the in-memory manager.
      let msgWithProof =
        (await checkAndGenerateRLNProof(some(server.rln), message)).get()

      # When the client publishes a message
      let publishResponse = await lightpushClient.legacyLightpushPublish(
        some(pubsubTopic), msgWithProof, serverRemotePeerInfo
      )

      if not publishResponse.isOk():
        echo "Publish failed: ", publishResponse.error()

      # Then the message is not relayed but not due to RLN
      assert publishResponse.isErr(), "We expect an error response"
      check publishResponse.error == protocol_metrics.notPublishedAnyPeer

    # The tests below drive `server.legacyLightpushPublish(...)` against the
    # server node. Because `server.wakuLegacyLightPush` is mounted (and no
    # legacy client is), the call takes the self-request path — it still runs
    # the full client-side flow (proof gen, retry on RlnValidatorErrorMsg
    # substring, one-retry cap), but the request lands in the local
    # pushHandler. Swapping in a stub pushHandler lets each test control what
    # attempt N sees.

    asyncTest "retry fires on RlnValidatorErrorMsg substring and second attempt succeeds":
      var callCount = 0
      let stub: PushMessageHandler = proc(
          pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[WakuLightPushResult[void]] {.async.} =
        inc callCount
        if callCount == 1:
          return err(RlnValidatorErrorMsg & ": simulated stale merkle path")
        return ok()
      server.wakuLegacyLightPush.pushHandler = stub

      let response = await server.legacyLightpushPublish(
        some(pubsubTopic), message, server.peerInfo.toRemotePeerInfo()
      )

      check:
        callCount == 2
        response.isOk()

    asyncTest "no retry when error does not contain RlnValidatorErrorMsg":
      var callCount = 0
      let stub: PushMessageHandler = proc(
          pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[WakuLightPushResult[void]] {.async.} =
        inc callCount
        return err("unrelated failure")
      server.wakuLegacyLightPush.pushHandler = stub

      let response = await server.legacyLightpushPublish(
        some(pubsubTopic), message, server.peerInfo.toRemotePeerInfo()
      )

      check:
        callCount == 1
        response.isErr()
        response.error == "unrelated failure"

    asyncTest "retry cap: two consecutive RLN errors surface the second":
      var callCount = 0
      let stub: PushMessageHandler = proc(
          pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[WakuLightPushResult[void]] {.async.} =
        inc callCount
        return err(RlnValidatorErrorMsg & ": still stale")
      server.wakuLegacyLightPush.pushHandler = stub

      let response = await server.legacyLightpushPublish(
        some(pubsubTopic), message, server.peerInfo.toRemotePeerInfo()
      )

      check:
        callCount == 2
        response.isErr()
        response.error.contains(RlnValidatorErrorMsg)

    asyncTest "no retry when node.rln is nil":
      # Detach RLN so the retry branch short-circuits on rln.isNone() even
      # when the error string carries RlnValidatorErrorMsg. Restore before
      # teardown so server.stop() sees the same object graph it was
      # constructed with.
      let savedRln = server.rln
      server.rln = nil

      var callCount = 0
      let stub: PushMessageHandler = proc(
          pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[WakuLightPushResult[void]] {.async.} =
        inc callCount
        return err(RlnValidatorErrorMsg & ": simulated")
      server.wakuLegacyLightPush.pushHandler = stub

      let response = await server.legacyLightpushPublish(
        some(pubsubTopic), message, server.peerInfo.toRemotePeerInfo()
      )

      server.rln = savedRln

      check:
        callCount == 1
        response.isErr()

suite "Waku Legacy Lightpush message delivery":
  asyncTest "Legacy lightpush message flow succeed":
    ## Setup
    let
      lightNodeKey = generateSecp256k1Key()
      lightNode = newTestWakuNode(lightNodeKey)
      bridgeNodeKey = generateSecp256k1Key()
      bridgeNode = newTestWakuNode(bridgeNodeKey)
      destNodeKey = generateSecp256k1Key()
      destNode = newTestWakuNode(destNodeKey)

    await allFutures(destNode.start(), bridgeNode.start(), lightNode.start())

    (await destNode.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    (await bridgeNode.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    check (await bridgeNode.mountLegacyLightPush()).isOk()
    lightNode.mountLegacyLightPushClient()

    discard await lightNode.peerManager.dialPeer(
      bridgeNode.peerInfo.toRemotePeerInfo(), WakuLegacyLightPushCodec
    )
    await sleepAsync(100.milliseconds)
    await destNode.connectToNodes(@[bridgeNode.peerInfo.toRemotePeerInfo()])

    ## Given
    const CustomPubsubTopic = "/waku/2/rs/0/1"
    let message = fakeWakuMessage()
    var completionFutRelay = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      check:
        topic == CustomPubsubTopic
        msg == message
      completionFutRelay.complete(true)

    destNode.subscribe((kind: PubsubSub, topic: CustomPubsubTopic), relayHandler).isOkOr:
      assert false, "Failed to subscribe to topic:" & $error

    # Wait for subscription to take effect
    await sleepAsync(100.millis)

    ## When
    let res = await lightNode.legacyLightpushPublish(some(CustomPubsubTopic), message)
    assert res.isOk(), $res.error

    ## Then
    check await completionFutRelay.withTimeout(5.seconds)

    ## Cleanup
    await allFutures(lightNode.stop(), bridgeNode.stop(), destNode.stop())

suite "Waku Legacy Lightpush mounting behavior":
  asyncTest "fails to mount when relay is not mounted":
    ## Given a node without Relay mounted
    let
      key = generateSecp256k1Key()
      node = newTestWakuNode(key)

    # Do not mount Relay on purpose
    check node.wakuRelay.isNil()

    ## Then mounting Legacy Lightpush must fail
    let res = await node.mountLegacyLightPush()
    check:
      res.isErr()
      res.error == MountWithoutRelayError
