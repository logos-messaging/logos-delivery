{.used.}

import
  std/[options, tempfiles, osproc, strutils],
  testutils/unittests,
  chronos,
  std/strformat,
  libp2p/crypto/crypto

import
  logos_delivery/waku/[waku_core, node/peer_manager, waku_node, waku_lightpush, rln],
  ../testlib/[wakucore, wakunode, testasync, futures],
  ../resources/payloads,
  ../waku_rln_relay/[rln/waku_rln_relay_utils, utils_onchain]

const PublishedToOnePeer = 1

suite "Waku Lightpush - End To End":
  var
    handlerFuture {.threadvar.}: Future[(PubsubTopic, WakuMessage)]
    handler {.threadvar.}: PushMessageHandler

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
    check (await server.mountLightpush()).isOk() # without rln-relay
    client.mountLightpushClient()

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
      lightpushClient.mountLightpushClient()

      # When the client publishes a message
      let publishResponse = await lightpushClient.lightpushPublish(
        some(pubsubTopic), message, some(serverRemotePeerInfo)
      )

      if not publishResponse.isOk():
        echo "Publish failed: ", publishResponse.error.code

      # Then the message is not relayed but not due to RLN
      assert publishResponse.isErr(), "We expect an error response"

      assert (publishResponse.error.code == LightPushErrorCode.NO_PEERS_TO_RELAY),
        "incorrect error response"

  suite "Waku LightPush Validation Tests":
    asyncTest "Validate message size exceeds limit":
      let msgOverLimit = fakeWakuMessage(
        contentTopic = contentTopic,
        payload = getByteSequence(DefaultMaxWakuMessageSize + 64 * 1024),
      )

      # When the client publishes an over-limit message
      let publishResponse = await client.lightpushPublish(
        some(pubsubTopic), msgOverLimit, some(serverRemotePeerInfo)
      )

      check:
        publishResponse.isErr()
        publishResponse.error.code == LightPushErrorCode.INVALID_MESSAGE
        publishResponse.error.desc ==
          some(fmt"Message size exceeded maximum of {DefaultMaxWakuMessageSize} bytes")

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
    check (await server.mountLightPush()).isOk()
    client.mountLightPushClient()

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
      lightpushClient.mountLightPushClient()

      # Attach the RLN proof. In production the client mounts RLN and generates the
      # proof in lightpushPublish; here we generate it using the server's RLN instance
      # since both ends share group state via the in-memory manager.
      let msgWithProof =
        (await checkAndGenerateRLNProof(some(server.rln), message)).get()

      # When the client publishes a message
      let publishResponse = await lightpushClient.lightpushPublish(
        some(pubsubTopic), msgWithProof, some(serverRemotePeerInfo)
      )

      if not publishResponse.isOk():
        echo "Publish failed: ", publishResponse.error()

      # Then the message is not relayed but not due to RLN
      assert publishResponse.isErr(), "We expect an error response"
      check publishResponse.error.code == LightPushErrorCode.NO_PEERS_TO_RELAY

    asyncTest "invalidate + regenerate refetches merkle path and rebuilds proof":
      # Exercises the primitive pair that lightpushPublish leans on after a
      # 420 (INVALID_MESSAGE) or 504 (OUT_OF_RLN_PROOF) rejection: calling
      # invalidateMerkleProofCache empties the cached path so the next
      # proof-gen refetches from chain, and attachRLNProof rebuilds the proof
      # even though the message already carries one.
      let firstMsg = (await checkAndGenerateRLNProof(some(server.rln), message)).get()
      check firstMsg.proof.len > 0

      # Corrupt the cache to model a stale/invalid witness — the same state a
      # 420/504 rejection would leave us in.
      let manager = cast[OnchainGroupManager](server.rln.groupManager)
      let goodCache = manager.merkleProofCache
      manager.merkleProofCache = newSeq[byte](goodCache.len)
      check manager.merkleProofCache != goodCache

      # Retry path: invalidate the cache so the next proof-gen refetches from
      # chain, then regenerate the proof.
      manager.invalidateMerkleProofCache()
      let secondMsg = (await attachRLNProof(server.rln, firstMsg)).get()

      check:
        secondMsg.proof.len > 0
        # Regenerated, not passed through — Groth16 proofs carry random
        # blinding, so a fresh call produces different bytes.
        secondMsg.proof != firstMsg.proof
        # Cache was refetched from chain, overwriting the corruption.
        manager.merkleProofCache == goodCache

    # The tests below drive `server.lightpushPublish(...)` directly against the
    # server node. Because `server.wakuLightPush` is mounted (and no lightpush
    # client is), lightpushPublish takes the self-request path — it still runs
    # the full client-side flow (proof gen, RLN-rejection classification), but
    # the request lands in the local pushHandler instead of going over the
    # wire. Swapping in a stub pushHandler lets each test control exactly what
    # each attempt sees.

    asyncTest "RLN-related 420 surfaces as 504 and schedules a merkle proof refresh":
      var callCount = 0
      let stub: PushMessageHandler = proc(
          pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[WakuLightPushResult] {.async.} =
        inc callCount
        return
          lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, RlnValidatorErrorMsg)
      server.wakuLightPush.pushHandler = stub

      let manager = cast[OnchainGroupManager](server.rln.groupManager)
      let goodCache = manager.merkleProofCache
      check goodCache.len > 0

      let response = await server.lightpushPublish(some(pubsubTopic), message)

      check:
        # The rejection is surfaced immediately — no internal republish — and
        # normalized to 504 so callers can key their retry on it.
        callCount == 1
        response.isErr()
        response.error.code == LightPushErrorCode.OUT_OF_RLN_PROOF
        response.error.desc.get("").contains(RlnProofRefreshScheduledMsg)

      # The refresh runs detached from the publish call: the cache was
      # dropped and a refetch is in flight. Once it settles the path is
      # fresh again.
      let inFlight = manager.proofPathRefreshInFlightFut
      if not inFlight.isNil():
        await inFlight.join()
      check manager.merkleProofCache == goodCache

    asyncTest "504 (OUT_OF_RLN_PROOF) from the service passes through without republish":
      var callCount = 0
      let stub: PushMessageHandler = proc(
          pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[WakuLightPushResult] {.async.} =
        inc callCount
        return lighpushErrorResult(
          LightPushErrorCode.OUT_OF_RLN_PROOF, "simulated out-of-proof"
        )
      server.wakuLightPush.pushHandler = stub

      let response = await server.lightpushPublish(some(pubsubTopic), message)

      check:
        callCount == 1
        response.isErr()
        response.error.code == LightPushErrorCode.OUT_OF_RLN_PROOF

    asyncTest "caller retry after 504 lands on the refreshed merkle path":
      var callCount = 0
      let stub: PushMessageHandler = proc(
          pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[WakuLightPushResult] {.async.} =
        inc callCount
        if callCount == 1:
          return lighpushErrorResult(
            LightPushErrorCode.INVALID_MESSAGE, RlnValidatorErrorMsg
          )
        return lightpushSuccessResult(1)
      server.wakuLightPush.pushHandler = stub

      let firstResponse = await server.lightpushPublish(some(pubsubTopic), message)

      check:
        firstResponse.isErr()
        firstResponse.error.code == LightPushErrorCode.OUT_OF_RLN_PROOF

      # Model the caller-level retry (send service next round, REST handler):
      # a second publish regenerates the proof against the refreshed cache.
      let secondResponse = await server.lightpushPublish(some(pubsubTopic), message)

      check:
        callCount == 2
        secondResponse.isOk()
        secondResponse.get() == 1

    asyncTest "420 without the RLN error text passes through unchanged":
      var callCount = 0
      let stub: PushMessageHandler = proc(
          pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[WakuLightPushResult] {.async.} =
        inc callCount
        return
          lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, "unrelated rejection")
      server.wakuLightPush.pushHandler = stub

      let response = await server.lightpushPublish(some(pubsubTopic), message)

      check:
        callCount == 1
        response.isErr()
        response.error.code == LightPushErrorCode.INVALID_MESSAGE

    asyncTest "error codes outside 420/504 pass through unchanged":
      var callCount = 0
      let stub: PushMessageHandler = proc(
          pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[WakuLightPushResult] {.async.} =
        inc callCount
        return lighpushErrorResult(
          LightPushErrorCode.INTERNAL_SERVER_ERROR, "unrelated failure"
        )
      server.wakuLightPush.pushHandler = stub

      let response = await server.lightpushPublish(some(pubsubTopic), message)

      check:
        callCount == 1
        response.isErr()
        response.error.code == LightPushErrorCode.INTERNAL_SERVER_ERROR

    asyncTest "rejection passes through unchanged when node.rln is nil":
      # Detach RLN so the RLN-rejection branch short-circuits on rln.isNone()
      # even for a 420. Restore before teardown so server.stop() sees the same
      # object graph it was constructed with.
      let savedRln = server.rln
      server.rln = nil

      var callCount = 0
      let stub: PushMessageHandler = proc(
          pubsubTopic: PubsubTopic, message: WakuMessage
      ): Future[WakuLightPushResult] {.async.} =
        inc callCount
        return lighpushErrorResult(
          LightPushErrorCode.INVALID_MESSAGE, "simulated stale merkle path"
        )
      server.wakuLightPush.pushHandler = stub

      let response = await server.lightpushPublish(some(pubsubTopic), message)

      server.rln = savedRln

      check:
        callCount == 1
        response.isErr()
        response.error.code == LightPushErrorCode.INVALID_MESSAGE

suite "Waku Lightpush message delivery":
  asyncTest "lightpush message flow succeed":
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
    check (await bridgeNode.mountLightPush()).isOk()
    lightNode.mountLightPushClient()

    discard await lightNode.peerManager.dialPeer(
      bridgeNode.peerInfo.toRemotePeerInfo(), WakuLightPushCodec
    )
    await sleepAsync(100.milliseconds)
    await destNode.connectToNodes(@[bridgeNode.peerInfo.toRemotePeerInfo()])

    ## Given
    const CustomPubsubTopic = "/waku/2/rs/0/1"
    let message = fakeWakuMessage()

    var completionFutRelay = newFuture[bool]()
    proc relayHandler(envelope: WakuEnvelope): Future[void] {.async, gcsafe.} =
      check:
        envelope.pubsubTopic == CustomPubsubTopic
        envelope.msg == message
      completionFutRelay.complete(true)

    destNode.subscribe((kind: PubsubSub, topic: CustomPubsubTopic), relayHandler).isOkOr:
      assert false, "Failed to subscribe to relay"

    # Wait for subscription to take effect
    await sleepAsync(100.millis)

    ## When
    let res = await lightNode.lightpushPublish(some(CustomPubsubTopic), message)
    assert res.isOk(), $res.error
    assert res.get() == 1, "Expected to relay the message to 1 node"

    ## Then
    check await completionFutRelay.withTimeout(5.seconds)

    ## Cleanup
    await allFutures(lightNode.stop(), bridgeNode.stop(), destNode.stop())

suite "Waku Lightpush mounting behavior":
  asyncTest "fails to mount when relay is not mounted":
    ## Given a node without Relay mounted
    let
      key = generateSecp256k1Key()
      node = newTestWakuNode(key)

    # Do not mount Relay on purpose
    check node.wakuRelay.isNil()

    ## Then mounting Lightpush must fail
    let res = await node.mountLightPush()
    check:
      res.isErr()
      res.error == MountWithoutRelayError
