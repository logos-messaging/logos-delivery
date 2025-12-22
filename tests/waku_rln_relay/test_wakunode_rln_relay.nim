{.used.}

import
  std/[options, os, sequtils, tempfiles, strutils, osproc],
  stew/byteutils,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub
import
  waku/[waku_core, waku_node, waku_rln_relay],
  ../testlib/[wakucore, futures, wakunode, testutils],
  ./utils_onchain,
  ./rln/waku_rln_relay_utils

from std/times import epochTime

proc waitForNullifierLog(node: WakuNode, expectedLen: int): Future[bool] {.async.} =
  ## Helper function
  for i in 0 .. 100: # Try for up to 50 seconds (100 * 500ms)
    if node.wakuRlnRelay.nullifierLog.len() == expectedLen:
      return true
    await sleepAsync(500.millis)
  return false

procSuite "WakuNode - RLN relay":
  # NOTE: we set the rlnRelayUserMessageLimit to 1 to make the tests easier to reason about
  var anvilProc {.threadVar.}: Process
  var manager {.threadVar.}: OnchainGroupManager

  setup:
    anvilProc = runAnvil(stateFile = some(DEFAULT_ANVIL_STATE_PATH))
    manager = waitFor setupOnchainGroupManager(deployContracts = false)

  teardown:
    stopAnvil(anvilProc)

  asyncTest "testing rln-relay with valid proof":
    let
      # publisher node
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
      # Relay node
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))
      # Subscriber
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, parseIpAddress("0.0.0.0"), Port(0))

      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    # mount rlnrelay in off-chain mode
    let wakuRlnConfig1 = getWakuRlnConfig(manager = manager, index = MembershipIndex(1))

    await node1.mountRlnRelay(wakuRlnConfig1)
    await node1.start()

    # Registration is mandatory before sending messages with rln-relay 
    let manager1 = cast[OnchainGroupManager](node1.wakuRlnRelay.groupManager)
    let idCredentials1 = generateCredentials()

    try:
      waitFor manager1.register(idCredentials1, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    let rootUpdated1 = waitFor manager1.updateRoots()
    info "Updated root for node1", rootUpdated1

    # node 2
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    # mount rlnrelay in off-chain mode
    let wakuRlnConfig2 = getWakuRlnConfig(manager = manager, index = MembershipIndex(2))

    await node2.mountRlnRelay(wakuRlnConfig2)
    await node2.start()

    let manager2 = cast[OnchainGroupManager](node2.wakuRlnRelay.groupManager)
    let rootUpdated2 = waitFor manager2.updateRoots()
    info "Updated root for node2", rootUpdated2

    # node 3
    (await node3.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    let wakuRlnConfig3 = getWakuRlnConfig(manager = manager, index = MembershipIndex(3))

    await node3.mountRlnRelay(wakuRlnConfig3)
    await node3.start()

    let manager3 = cast[OnchainGroupManager](node3.wakuRlnRelay.groupManager)
    let rootUpdated3 = waitFor manager3.updateRoots()
    info "Updated root for node3", rootUpdated3

    # connect them together
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      info "The received topic:", topic
      if topic == DefaultPubsubTopic:
        completionFut.complete(true)

    proc simpleHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node1.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in node1: " & $error
    node2.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in node2: " & $error

    ## Subscribe to the relay topic to add the custom relay handler defined above
    node3.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), relayHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic: " & $error
    await sleepAsync(2000.millis)

    # prepare the message payload
    let payload = "Hello".toBytes()

    # prepare the epoch
    var message =
      WakuMessage(payload: @payload, contentTopic: contentTopic, timestamp: now())
    doAssert(
      node1.wakuRlnRelay
      .unsafeAppendRLNProof(message, node1.wakuRlnRelay.getCurrentEpoch(), MessageId(0))
      .isOk()
    )

    info " Nodes participating in the test",
      node1 = shortLog(node1.switch.peerInfo.peerId),
      node2 = shortLog(node2.switch.peerInfo.peerId),
      node3 = shortLog(node3.switch.peerInfo.peerId)

    ## node1 publishes a message with a rate limit proof, the message is then relayed to node2 which in turn
    ## verifies the rate limit proof of the message and relays the message to node3
    ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
    discard await node1.publish(some(DefaultPubsubTopic), message)
    assert (await completionFut.withTimeout(15.seconds)), "completionFut timed out"

    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "testing rln-relay is applied in all rln shards/content topics":
    # create 3 nodes
    let nodes = toSeq(0 ..< 3).mapIt(
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      )
    await allFutures(nodes.mapIt(it.start()))

    let shards =
      @[RelayShard(clusterId: 0, shardId: 0), RelayShard(clusterId: 0, shardId: 1)]
    let contentTopics =
      @[
        ContentTopic("/waku/2/content-topic-a/proto"),
        ContentTopic("/waku/2/content-topic-b/proto"),
      ]

    # set up three nodes
    await allFutures(nodes.mapIt(it.mountRelay()))

    # mount rlnrelay in off-chain mode
    for index, node in nodes:
      let wakuRlnConfig =
        getWakuRlnConfig(manager = manager, index = MembershipIndex(index + 1))

      await node.mountRlnRelay(wakuRlnConfig)
      await node.start()
      let manager = cast[OnchainGroupManager](node.wakuRlnRelay.groupManager)
      let idCredentials = generateCredentials()

      try:
        waitFor manager.register(idCredentials, UserMessageLimit(20))
      except Exception, CatchableError:
        assert false,
          "exception raised when calling register: " & getCurrentExceptionMsg()

      let rootUpdated = waitFor manager.updateRoots()
      info "Updated root for node", node = index + 1, rootUpdated = rootUpdated

    # connect them together
    await nodes[0].connectToNodes(@[nodes[1].switch.peerInfo.toRemotePeerInfo()])
    await nodes[2].connectToNodes(@[nodes[1].switch.peerInfo.toRemotePeerInfo()])

    var rxMessagesTopic1 = 0
    var rxMessagesTopic2 = 0
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      info "relayHandler. The received topic:", topic
      if topic == $shards[0]:
        rxMessagesTopic1 = rxMessagesTopic1 + 1
      elif topic == $shards[1]:
        rxMessagesTopic2 = rxMessagesTopic2 + 1

    proc simpleHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    nodes[0].subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in nodes[0]: " & $error
    nodes[1].subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in nodes[1]: " & $error

    # mount the relay handlers
    nodes[2].subscribe((kind: PubsubSub, topic: $shards[0]), relayHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic: " & $error
    nodes[2].subscribe((kind: PubsubSub, topic: $shards[1]), relayHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic: " & $error
    await sleepAsync(1000.millis)

    # generate some messages with rln proofs first. generating
    # the proof takes some time, so this is done before publishing
    # to avoid blocking the test
    var messages1: seq[WakuMessage] = @[]
    var messages2: seq[WakuMessage] = @[]

    for i in 0 ..< 3:
      var message = WakuMessage(
        payload: ("Payload_" & $i).toBytes(),
        timestamp: now(),
        contentTopic: contentTopics[0],
      )

      nodes[0].wakuRlnRelay.unsafeAppendRLNProof(
        message, nodes[0].wakuRlnRelay.getCurrentEpoch(), MessageId(i.uint8)
      ).isOkOr:
        raiseAssert $error
      messages1.add(message)

    for i in 0 ..< 3:
      var message = WakuMessage(
        payload: ("Payload_" & $i).toBytes(),
        timestamp: now(),
        contentTopic: contentTopics[1],
      )

      nodes[1].wakuRlnRelay.unsafeAppendRLNProof(
        message, nodes[1].wakuRlnRelay.getCurrentEpoch(), MessageId(i.uint8)
      ).isOkOr:
        raiseAssert $error
      messages2.add(message)

    # publish 3 messages from node[0] (last 2 are spam, window is 10 secs)
    # publish 3 messages from node[1] (last 2 are spam, window is 10 secs)
    for msg in messages1:
      discard await nodes[0].publish(some($shards[0]), msg)
    for msg in messages2:
      discard await nodes[1].publish(some($shards[1]), msg)

    # wait for gossip to propagate
    await sleepAsync(5000.millis)

    # check that node[2] got messages from both topics
    # and that rln was applied (just 1 msg is rx, rest are spam)
    check:
      rxMessagesTopic1 == 3
      rxMessagesTopic2 == 3

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "testing rln-relay with invalid proof":
    let
      # publisher node
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
      # Relay node
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))
      # Subscriber
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, parseIpAddress("0.0.0.0"), Port(0))

      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    # mount rlnrelay in off-chain mode
    let wakuRlnConfig1 = getWakuRlnConfig(manager = manager, index = MembershipIndex(1))

    await node1.mountRlnRelay(wakuRlnConfig1)
    await node1.start()

    let manager1 = cast[OnchainGroupManager](node1.wakuRlnRelay.groupManager)
    let idCredentials1 = generateCredentials()

    try:
      waitFor manager1.register(idCredentials1, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    let rootUpdated1 = waitFor manager1.updateRoots()
    info "Updated root for node1", rootUpdated1

    # node 2
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    # mount rlnrelay in off-chain mode
    let wakuRlnConfig2 = getWakuRlnConfig(manager = manager, index = MembershipIndex(2))

    await node2.mountRlnRelay(wakuRlnConfig2)
    await node2.start()

    let manager2 = cast[OnchainGroupManager](node2.wakuRlnRelay.groupManager)
    let rootUpdated2 = waitFor manager2.updateRoots()
    info "Updated root for node2", rootUpdated2

    # node 3
    (await node3.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    let wakuRlnConfig3 = getWakuRlnConfig(manager = manager, index = MembershipIndex(3))

    await node3.mountRlnRelay(wakuRlnConfig3)
    await node3.start()

    let manager3 = cast[OnchainGroupManager](node3.wakuRlnRelay.groupManager)
    let rootUpdated3 = waitFor manager3.updateRoots()
    info "Updated root for node3", rootUpdated3

    # connect them together
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # define a custom relay handler
    var completionFut = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      info "The received topic:", topic
      if topic == DefaultPubsubTopic:
        completionFut.complete(true)

    proc simpleHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node1.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in node1: " & $error
    node2.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in node2: " & $error

    # mount the relay handler
    node3.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), relayHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic: " & $error
    await sleepAsync(2000.millis)

    # prepare the message payload
    let payload = "valid".toBytes()
    # prepare the epoch
    let epoch = node1.wakuRlnRelay.getCurrentEpoch()

    var message =
      WakuMessage(payload: @payload, contentTopic: DefaultPubsubTopic, timestamp: now())

    node1.wakuRlnRelay.unsafeAppendRLNProof(message, epoch, MessageId(0)).isOkOr:
      assert false, "Failed to append rln proof: " & $error

    # message.payload = "Invalid".toBytes()
    message.proof[0] = message.proof[0] xor 0x01

    discard await node1.publish(some(DefaultPubsubTopic), message)
    await sleepAsync(2000.millis)

    check:
      # the relayHandler of node3 never gets called
      (await completionFut.withTimeout(10.seconds)) == false

    await node1.stop()
    await node2.stop()
    await node3.stop()

  asyncTest "testing rln-relay double-signaling detection":
    let
      # publisher node
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
      # Relay node
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))
      # Subscriber
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, parseIpAddress("0.0.0.0"), Port(0))

      contentTopic = ContentTopic("/waku/2/default-content/proto")

    # set up three nodes
    # node1
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    # mount rlnrelay in off-chain mode
    let wakuRlnConfig1 = getWakuRlnConfig(manager = manager, index = MembershipIndex(1))

    await node1.mountRlnRelay(wakuRlnConfig1)
    await node1.start()

    # Registration is mandatory before sending messages with rln-relay 
    let manager1 = cast[OnchainGroupManager](node1.wakuRlnRelay.groupManager)
    let idCredentials1 = generateCredentials()

    try:
      waitFor manager1.register(idCredentials1, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    let rootUpdated1 = waitFor manager1.updateRoots()
    info "Updated root for node1", rootUpdated1

    # node 2
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    # mount rlnrelay in off-chain mode
    let wakuRlnConfig2 = getWakuRlnConfig(manager = manager, index = MembershipIndex(2))

    await node2.mountRlnRelay(wakuRlnConfig2)
    await node2.start()

    # Registration is mandatory before sending messages with rln-relay 
    let manager2 = cast[OnchainGroupManager](node2.wakuRlnRelay.groupManager)
    let rootUpdated2 = waitFor manager2.updateRoots()
    info "Updated root for node2", rootUpdated2

    # node 3
    (await node3.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    # mount rlnrelay in off-chain mode
    let wakuRlnConfig3 = getWakuRlnConfig(manager = manager, index = MembershipIndex(3))

    await node3.mountRlnRelay(wakuRlnConfig3)
    await node3.start()

    # Registration is mandatory before sending messages with rln-relay 
    let manager3 = cast[OnchainGroupManager](node3.wakuRlnRelay.groupManager)
    let rootUpdated3 = waitFor manager3.updateRoots()
    info "Updated root for node3", rootUpdated3

    # connect the nodes together node1 <-> node2 <-> node3
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node3.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # get the current epoch time
    let epoch_1 = node1.wakuRlnRelay.getCurrentEpoch()

    #  create some messages with rate limit proofs
    var
      wm1 = WakuMessage(
        payload: "message 1".toBytes(),
        timestamp: now(),
        contentTopic: DefaultPubsubTopic,
      )
      # another message in the same epoch as wm1, it will break the messaging rate limit
      wm2 = WakuMessage(
        payload: "message 2".toBytes(),
        timestamp: now(),
        contentTopic: DefaultPubsubTopic,
      )
      #  wm3 points to the next epoch

    await sleepAsync(1000.millis)
    let epoch_2 = node1.wakuRlnRelay.getCurrentEpoch()

    var
      wm3 = WakuMessage(
        payload: "message 3".toBytes(),
        timestamp: now(),
        contentTopic: DefaultPubsubTopic,
      )
      wm4 = WakuMessage(
        payload: "message 4".toBytes(),
        timestamp: now(),
        contentTopic: DefaultPubsubTopic,
      )

    node1.wakuRlnRelay.unsafeAppendRLNProof(wm1, epoch_1, MessageId(0)).isOkOr:
      raiseAssert $error
    node1.wakuRlnRelay.unsafeAppendRLNProof(wm2, epoch_1, MessageId(0)).isOkOr:
      raiseAssert $error

    node1.wakuRlnRelay.unsafeAppendRLNProof(wm3, epoch_2, MessageId(2)).isOkOr:
      raiseAssert $error

    #  relay handler for node3
    var completionFut1 = newFuture[bool]()
    var completionFut2 = newFuture[bool]()
    var completionFut3 = newFuture[bool]()
    var completionFut4 = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      info "The received topic:", topic
      if topic == DefaultPubsubTopic:
        if msg == wm1:
          completionFut1.complete(true)
        if msg == wm2:
          completionFut2.complete(true)
        if msg.payload == wm3.payload:
          completionFut3.complete(true)
        if msg.payload == wm4.payload:
          completionFut4.complete(true)

    proc simpleHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      await sleepAsync(0.milliseconds)

    node1.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in node1: " & $error
    node2.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), simpleHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic in node2: " & $error

    # mount the relay handler for node3
    node3.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), relayHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic: " & $error
    await sleepAsync(2000.millis)

    ## node1 publishes and relays 4 messages to node2
    ## verification at node2 occurs inside a topic validator which is installed as part of the waku-rln-relay mount proc
    ## node2 relays either of wm1 or wm2 to node3, depending on which message arrives at node2 first
    ## node2 should detect either of wm1 or wm2 as spam and not relay it
    ## node2 should relay wm3 to node3
    ## node2 should not relay wm4 because it has no valid rln proof
    discard await node1.publish(some(DefaultPubsubTopic), wm1)
    discard await node1.publish(some(DefaultPubsubTopic), wm2)
    discard await node1.publish(some(DefaultPubsubTopic), wm3)
    discard await node1.publish(some(DefaultPubsubTopic), wm4)
    await sleepAsync(2000.millis)

    let
      res1 = await completionFut1.withTimeout(10.seconds)
      res2 = await completionFut2.withTimeout(10.seconds)

    check:
      (res1 and res2) == false
        # either of the wm1 and wm2 is found as spam hence not relayed
      (await completionFut3.withTimeout(10.seconds)) == true
      (await completionFut4.withTimeout(10.seconds)) == false

    await node1.stop()
    await node2.stop()
    await node3.stop()

  xasyncTest "clearNullifierLog: should clear epochs > MaxEpochGap":
    ## This is skipped because is flaky and made CI randomly fail but is useful to run manually
    # Given two nodes
    let
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      shardSeq = @[DefaultRelayShard]
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, parseIpAddress("0.0.0.0"), Port(0))
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, parseIpAddress("0.0.0.0"), Port(0))
      epochSizeSec: uint64 = 5 # This means rlnMaxEpochGap = 4

    # Given both nodes mount relay and rlnrelay
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    let wakuRlnConfig1 = getWakuRlnConfig(manager = manager, index = MembershipIndex(1))
    await node1.mountRlnRelay(wakuRlnConfig1)
    await node1.start()

    # Registration is mandatory before sending messages with rln-relay 
    let manager1 = cast[OnchainGroupManager](node1.wakuRlnRelay.groupManager)
    let idCredentials1 = generateCredentials()

    try:
      waitFor manager1.register(idCredentials1, UserMessageLimit(20))
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    let rootUpdated1 = waitFor manager1.updateRoots()
    info "Updated root for node1", rootUpdated1

    # Mount rlnrelay in node2 in off-chain mode
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    let wakuRlnConfig2 = getWakuRlnConfig(manager = manager, index = MembershipIndex(2))
    await node2.mountRlnRelay(wakuRlnConfig2)
    await node2.start()

    # Registration is mandatory before sending messages with rln-relay 
    let manager2 = cast[OnchainGroupManager](node2.wakuRlnRelay.groupManager)
    let rootUpdated2 = waitFor manager2.updateRoots()
    info "Updated root for node2", rootUpdated2

    # Given the two nodes are started and connected
    waitFor allFutures(node1.start(), node2.start())
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    # Given some messages
    var
      wm1 =
        WakuMessage(payload: "message 1".toBytes(), contentTopic: DefaultPubsubTopic)
      wm2 =
        WakuMessage(payload: "message 2".toBytes(), contentTopic: DefaultPubsubTopic)
      wm3 =
        WakuMessage(payload: "message 3".toBytes(), contentTopic: DefaultPubsubTopic)
      wm4 =
        WakuMessage(payload: "message 4".toBytes(), contentTopic: DefaultPubsubTopic)
      wm5 =
        WakuMessage(payload: "message 5".toBytes(), contentTopic: DefaultPubsubTopic)
      wm6 =
        WakuMessage(payload: "message 6".toBytes(), contentTopic: DefaultPubsubTopic)

    # And node2 mounts a relay handler that completes the respective future when a message is received
    var
      completionFut1 = newFuture[bool]()
      completionFut2 = newFuture[bool]()
      completionFut3 = newFuture[bool]()
      completionFut4 = newFuture[bool]()
      completionFut5 = newFuture[bool]()
      completionFut6 = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      info "The received topic:", topic
      if topic == DefaultPubsubTopic:
        if msg == wm1:
          completionFut1.complete(true)
        if msg == wm2:
          completionFut2.complete(true)
        if msg == wm3:
          completionFut3.complete(true)
        if msg == wm4:
          completionFut4.complete(true)
        if msg == wm5:
          completionFut5.complete(true)
        if msg == wm6:
          completionFut6.complete(true)

    node2.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), relayHandler).isOkOr:
      assert false, "Failed to subscribe to pubsub topic: " & $error

    # Given all messages have an rln proof and are published by the node 1
    let publishSleepDuration: Duration = 5000.millis
    let epoch_1 = node1.wakuRlnRelay.calcEpoch(epochTime().float64)
    let epoch_2 = node1.wakuRlnRelay.calcEpoch(
      epochTime().float64 + node1.wakuRlnRelay.rlnEpochSizeSec.float64 * 1
    )
    let epoch_3 = node1.wakuRlnRelay.calcEpoch(
      epochTime().float64 + node1.wakuRlnRelay.rlnEpochSizeSec.float64 * 2
    )
    let epoch_4 = node1.wakuRlnRelay.calcEpoch(
      epochTime().float64 + node1.wakuRlnRelay.rlnEpochSizeSec.float64 * 3
    )
    let epoch_5 = node1.wakuRlnRelay.calcEpoch(
      epochTime().float64 + node1.wakuRlnRelay.rlnEpochSizeSec.float64 * 4
    )

    # Epoch 1
    node1.wakuRlnRelay.unsafeAppendRLNProof(wm1, epoch_1, MessageId(0)).isOkOr:
      raiseAssert $error

    # Message wm2 is published in the same epoch as wm1, so it'll be considered spam
    node1.wakuRlnRelay.unsafeAppendRLNProof(wm2, epoch_1, MessageId(0)).isOkOr:
      raiseAssert $error

    discard await node1.publish(some(DefaultPubsubTopic), wm1)
    discard await node1.publish(some(DefaultPubsubTopic), wm2)
    await sleepAsync(publishSleepDuration)
    check:
      await node1.waitForNullifierLog(0)
      await node2.waitForNullifierLog(1)

    # Epoch 2

    node1.wakuRlnRelay.unsafeAppendRLNProof(wm3, epoch_2, MessageId(0)).isOkOr:
      raiseAssert $error

    discard await node1.publish(some(DefaultPubsubTopic), wm3)

    await sleepAsync(publishSleepDuration)

    check:
      await node1.waitForNullifierLog(0)
      await node2.waitForNullifierLog(2)

    # Epoch 3
    node1.wakuRlnRelay.unsafeAppendRLNProof(wm4, epoch_3, MessageId(0)).isOkOr:
      raiseAssert $error

    discard await node1.publish(some(DefaultPubsubTopic), wm4)
    await sleepAsync(publishSleepDuration)
    check:
      await node1.waitForNullifierLog(0)
      await node2.waitForNullifierLog(3)

    # Epoch 4
    node1.wakuRlnRelay.unsafeAppendRLNProof(wm5, epoch_4, MessageId(0)).isOkOr:
      raiseAssert $error

    discard await node1.publish(some(DefaultPubsubTopic), wm5)
    await sleepAsync(publishSleepDuration)
    check:
      await node1.waitForNullifierLog(0)
      await node2.waitForNullifierLog(4)

    # Epoch 5
    node1.wakuRlnRelay.unsafeAppendRLNProof(wm6, epoch_5, MessageId(0)).isOkOr:
      raiseAssert $error

    discard await node1.publish(some(DefaultPubsubTopic), wm6)
    await sleepAsync(publishSleepDuration)
    check:
      await node1.waitForNullifierLog(0)
      await node2.waitForNullifierLog(4)

    # Then the node 2 should have cleared the nullifier log for epochs > MaxEpochGap
    # Therefore, with 4 max epochs, the first 4 messages will be published (except wm2, which shares epoch with wm1)
    check:
      (await completionFut1.waitForResult()).value() == true
      (await completionFut2.waitForResult()).isErr()
      (await completionFut3.waitForResult()).value() == true
      (await completionFut4.waitForResult()).value() == true
      (await completionFut5.waitForResult()).value() == true
      (await completionFut6.waitForResult()).value() == true

    # Cleanup
    waitFor allFutures(node1.stop(), node2.stop())
