{.used.}

import
  std/[options, tempfiles, net, osproc],
  testutils/unittests,
  chronos,
  std/strformat,
  libp2p/crypto/crypto

import
  waku/[
    waku_core,
    node/peer_manager,
    node/waku_node,
    node/kernel_api,
    node/kernel_api/lightpush,
    waku_lightpush_legacy,
    waku_lightpush_legacy/common,
    waku_lightpush_legacy/protocol_metrics,
    waku_rln_relay,
  ],
  ../testlib/[wakucore, wakunode, testasync, futures, testutils],
  ../resources/payloads,
  ../waku_rln_relay/[rln/waku_rln_relay_utils, utils_onchain]

suite "Waku Legacy Lightpush - End To End":
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
    handlerFuture = newPushHandlerFuture()
    handler = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult[void]] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return ok()

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

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
      let lightpushClient =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
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
    handlerFuture {.threadvar.}: Future[(PubsubTopic, WakuMessage)]
    handler {.threadvar.}: PushMessageHandler

    server {.threadvar.}: WakuNode
    client {.threadvar.}: WakuNode
    anvilProc {.threadvar.}: Process
    manager {.threadvar.}: OnchainGroupManager

    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    pubsubTopic {.threadvar.}: PubsubTopic
    contentTopic {.threadvar.}: ContentTopic
    message {.threadvar.}: WakuMessage

  asyncSetup:
    handlerFuture = newPushHandlerFuture()
    handler = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult[void]] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return ok()

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, parseIpAddress("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, parseIpAddress("0.0.0.0"), Port(0))

    anvilProc = runAnvil(stateFile = some(DEFAULT_ANVIL_STATE_PATH))
    manager = waitFor setupOnchainGroupManager(deployContracts = false)

    # mount rln-relay
    let wakuRlnConfig = getWakuRlnConfig(manager = manager, index = MembershipIndex(1))

    await allFutures(server.start(), client.start())
    await server.start()

    (await server.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    await server.mountRlnRelay(wakuRlnConfig)
    check (await server.mountLegacyLightPush()).isOk()
    client.mountLegacyLightPushClient()

    let manager1 = cast[OnchainGroupManager](server.wakuRlnRelay.groupManager)
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
      let lightpushClient =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      lightpushClient.mountLegacyLightPushClient()

      # When the client publishes a message
      let publishResponse = await lightpushClient.legacyLightpushPublish(
        some(pubsubTopic), message, serverRemotePeerInfo
      )

      if not publishResponse.isOk():
        echo "Publish failed: ", publishResponse.error()

      # Then the message is not relayed but not due to RLN
      assert publishResponse.isErr(), "We expect an error response"
      check publishResponse.error == protocol_metrics.notPublishedAnyPeer

suite "Waku Legacy Lightpush message delivery":
  asyncTest "Legacy lightpush message flow succeed":
    ## Setup
    let
      lightNodeKey = generateSecp256k1Key()
      lightNode = newTestWakuNode(lightNodeKey, parseIpAddress("0.0.0.0"), Port(0))
      bridgeNodeKey = generateSecp256k1Key()
      bridgeNode = newTestWakuNode(bridgeNodeKey, parseIpAddress("0.0.0.0"), Port(0))
      destNodeKey = generateSecp256k1Key()
      destNode = newTestWakuNode(destNodeKey, parseIpAddress("0.0.0.0"), Port(0))

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
      node = newTestWakuNode(key, parseIpAddress("0.0.0.0"), Port(0))

    # Do not mount Relay on purpose
    check node.wakuRelay.isNil()

    ## Then mounting Legacy Lightpush must fail
    let res = await node.mountLegacyLightPush()
    check:
      res.isErr()
      res.error == MountWithoutRelayError
