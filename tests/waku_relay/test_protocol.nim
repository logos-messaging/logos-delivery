{.used.}

import
  std/[options, strformat, sets, tables],
  testutils/unittests,
  chronos,
  libp2p/protocols/pubsub/[pubsub, gossipsub],
  libp2p/[stream/connection, switch],
  ./crypto_utils,
  std/json

import
  logos_delivery/waku/[
    node/peer_manager,
    waku_relay/protocol,
    waku_relay,
    waku_core,
    waku_core/message/codec,
  ],
  ../testlib/[wakucore, testasync, futures, sequtils],
  ./utils,
  ../resources/payloads

proc hasMeshPeer(relay: WakuRelay, topic: PubsubTopic, peer: PeerId): bool =
  for p in relay.mesh.getOrDefault(topic):
    if p.peerId == peer:
      return true
  false

proc waitForMeshPeer(
    relay: WakuRelay, topic: PubsubTopic, peer: PeerId, timeout = 10.seconds
): Future[bool] {.async.} =
  ## Wait until `relay`'s gossipsub mesh for `topic` has GRAFTed `peer`.
  let deadline = Moment.now() + timeout
  while Moment.now() < deadline:
    if relay.hasMeshPeer(topic, peer):
      return true
    await sleepAsync(50.milliseconds)
  false

suite "Waku Relay":
  var messageSeq {.threadvar.}: seq[(PubsubTopic, WakuMessage)]
  var handlerFuture {.threadvar.}: Future[(PubsubTopic, WakuMessage)]
  var simpleFutureHandler {.threadvar.}: WakuRelayHandler

  var switch {.threadvar.}: Switch
  var peerManager {.threadvar.}: PeerManager
  var node {.threadvar.}: WakuRelay

  var remotePeerInfo {.threadvar.}: RemotePeerInfo
  var peerId {.threadvar.}: PeerId

  var contentTopic {.threadvar.}: ContentTopic
  var pubsubTopic {.threadvar.}: PubsubTopic
  var pubsubTopicSeq {.threadvar.}: seq[PubsubTopic]
  var testMessage {.threadvar.}: string
  var wakuMessage {.threadvar.}: WakuMessage

  asyncSetup:
    messageSeq = @[]
    handlerFuture = newPushHandlerFuture()
    simpleFutureHandler = proc(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, closure, gcsafe.} =
      messageSeq.add((topic, msg))
      handlerFuture.complete((topic, msg))

    switch = newTestSwitch()
    peerManager = PeerManager.new(switch)
    node = await newTestWakuRelay(switch)

    testMessage = "test-message"
    contentTopic = DefaultContentTopic
    pubsubTopic = DefaultPubsubTopic
    pubsubTopicSeq = @[pubsubTopic]
    wakuMessage = fakeWakuMessage(testMessage, pubsubTopic)

    await allFutures(switch.start())

    remotePeerInfo = switch.peerInfo.toRemotePeerInfo()
    peerId = remotePeerInfo.peerId

  asyncTeardown:
    await allFutures(switch.stop())

  suite "Subscribe":
    asyncTest "Publish without Subscription":
      # When publishing a message without being subscribed
      discard await node.publish(pubsubTopic, wakuMessage)

      # Then the message is not published
      check:
        not await handlerFuture.withTimeout(FUTURE_TIMEOUT)

    asyncTest "Publish with Subscription (Network Size: 1)":
      # When subscribing to a Pubsub Topic

      node.subscribe(pubsubTopic, simpleFutureHandler)

      # Then the node is subscribed
      check:
        node.isSubscribed(pubsubTopic)
        node.subscribedTopics == pubsubTopicSeq

      # When publishing a message
      discard await node.publish(pubsubTopic, wakuMessage)

      # Then the message is published
      assert (await handlerFuture.withTimeout(FUTURE_TIMEOUT))
      let (topic, msg) = handlerFuture.read()
      check:
        topic == pubsubTopic
        msg == wakuMessage

    asyncTest "Pubsub Topic Subscription (Network Size: 2, only one subscribed)":
      # Given a second node connected to the first one
      let
        otherSwitch = newTestSwitch()
        otherNode = await newTestWakuRelay(otherSwitch)

      await allFutures(otherSwitch.start(), otherNode.start())
      let otherRemotePeerInfo = otherSwitch.peerInfo.toRemotePeerInfo()
      check await peerManager.connectPeer(otherRemotePeerInfo)

      var otherHandlerFuture = newPushHandlerFuture()
      proc otherSimpleFutureHandler(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        otherHandlerFuture.complete((topic, message))

      # When subscribing the second node to the Pubsub Topic
      otherNode.subscribe(pubsubTopic, otherSimpleFutureHandler)

      # Then the second node is subscribed, but not the first one
      check:
        not node.isSubscribed(pubsubTopic)
        node.subscribedTopics != pubsubTopicSeq
        otherNode.isSubscribed(pubsubTopic)
        otherNode.subscribedTopics == pubsubTopicSeq

      await sleepAsync(500.millis)

      # When publishing a message in the subscribed node
      let fromOtherWakuMessage = fakeWakuMessage("fromOther")
      discard await otherNode.publish(pubsubTopic, fromOtherWakuMessage)

      # Then the message is published only in the subscribed node
      check:
        not await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)

      let (otherTopic1, otherMessage1) = otherHandlerFuture.read()
      check:
        otherTopic1 == pubsubTopic
        otherMessage1 == fromOtherWakuMessage

      # When publishing a message in the other node
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      let fromNodeWakuMessage = fakeWakuMessage("fromNode")
      discard await node.publish(pubsubTopic, fromNodeWakuMessage)

      # Then the message is published only in the subscribed node
      check:
        not await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)

      let (otherTopic2, otherMessage2) = otherHandlerFuture.read()
      check:
        otherTopic2 == pubsubTopic
        otherMessage2 == fromNodeWakuMessage

      # Finally stop the other node
      await allFutures(otherSwitch.stop(), otherNode.stop())

    asyncTest "Pubsub Topic Subscription (Network Size: 2, both subscribed to same pubsub topic)":
      # Given a second node connected to the first one
      let
        otherSwitch = newTestSwitch()
        otherNode = await newTestWakuRelay(otherSwitch)

      await allFutures(otherSwitch.start(), otherNode.start())
      let otherRemotePeerInfo = otherSwitch.peerInfo.toRemotePeerInfo()
      check await peerManager.connectPeer(otherRemotePeerInfo)

      var otherHandlerFuture = newPushHandlerFuture()
      proc otherSimpleFutureHandler(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        otherHandlerFuture.complete((topic, message))

      # When subscribing both nodes to the same Pubsub Topic
      node.subscribe(pubsubTopic, simpleFutureHandler)
      otherNode.subscribe(pubsubTopic, otherSimpleFutureHandler)

      # Then both nodes are subscribed
      check:
        node.isSubscribed(pubsubTopic)
        node.subscribedTopics == pubsubTopicSeq
        otherNode.isSubscribed(pubsubTopic)
        otherNode.subscribedTopics == pubsubTopicSeq

      await sleepAsync(500.millis)

      # When publishing a message in node
      let fromOtherWakuMessage = fakeWakuMessage("fromOther")
      discard await node.publish(pubsubTopic, fromOtherWakuMessage)

      # Then the message is published in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)

      let
        (topic1, message1) = handlerFuture.read()
        (otherTopic1, otherMessage1) = otherHandlerFuture.read()
      check:
        topic1 == pubsubTopic
        message1 == fromOtherWakuMessage
        otherTopic1 == pubsubTopic
        otherMessage1 == fromOtherWakuMessage

      # When publishing a message in the other node
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      let fromNodeWakuMessage = fakeWakuMessage("fromNode")
      discard await node.publish(pubsubTopic, fromNodeWakuMessage)
      discard await otherNode.publish(pubsubTopic, fromNodeWakuMessage)

      # Then the message is published in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)

      let
        (topic2, message2) = handlerFuture.read()
        (otherTopic2, otherMessage2) = otherHandlerFuture.read()
      check:
        topic2 == pubsubTopic
        message2 == fromNodeWakuMessage
        otherTopic2 == pubsubTopic
        otherMessage2 == fromNodeWakuMessage

      # Finally stop the other node
      await allFutures(otherSwitch.stop(), otherNode.stop())

    asyncTest "Refreshing subscription":
      # Given a subscribed node
      node.subscribe(pubsubTopic, simpleFutureHandler)
      check:
        node.isSubscribed(pubsubTopic)
        node.subscribedTopics == pubsubTopicSeq
      let otherWakuMessage = fakeWakuMessage("fromOther")
      discard await node.publish(pubsubTopic, otherWakuMessage)
      check:
        messageSeq == @[(pubsubTopic, otherWakuMessage)]

      # Given the subscription is refreshed
      var otherHandlerFuture = newPushHandlerFuture()
      proc otherSimpleFutureHandler(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        otherHandlerFuture.complete((topic, message))

      node.subscribe(pubsubTopic, otherSimpleFutureHandler)
      check:
        node.isSubscribed(pubsubTopic)
        node.subscribedTopics == pubsubTopicSeq
        messageSeq == @[(pubsubTopic, otherWakuMessage)]

      # When publishing a message with the refreshed subscription
      handlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, wakuMessage)

      # Then the message is published
      check (await handlerFuture.withTimeout(FUTURE_TIMEOUT))
      let (topic, msg) = handlerFuture.read()
      check:
        topic == pubsubTopic
        msg == wakuMessage
        messageSeq == @[(pubsubTopic, otherWakuMessage), (pubsubTopic, wakuMessage)]

    asyncTest "With additional validator":
      # Given a simple validator
      var validatorFuture = newBoolFuture()
      let len4Validator = proc(
          pubsubTopic: string, message: WakuMessage
      ): Future[ValidationResult] {.async.} =
        if message.payload.len() == 8:
          validatorFuture.complete(true)
          return ValidationResult.Accept
        else:
          validatorFuture.complete(false)
          return ValidationResult.Reject

      # And a second node connected to the first one
      let
        otherSwitch = newTestSwitch()
        otherNode = await newTestWakuRelay(otherSwitch)

      await allFutures(otherSwitch.start(), otherNode.start())
      let otherRemotePeerInfo = otherSwitch.peerInfo.toRemotePeerInfo()
      check await peerManager.connectPeer(otherRemotePeerInfo)

      var otherHandlerFuture = newPushHandlerFuture()
      proc otherSimpleFutureHandler(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        otherHandlerFuture.complete((topic, message))

      otherNode.addValidator(len4Validator)
      otherNode.subscribe(pubsubTopic, otherSimpleFutureHandler)
      await sleepAsync(500.millis)
      check:
        otherNode.isSubscribed(pubsubTopic)

      # Given a subscribed node with a validator
      node.addValidator(len4Validator)
      node.subscribe(pubsubTopic, simpleFutureHandler)
      await sleepAsync(500.millis)
      check:
        node.isSubscribed(pubsubTopic)
        node.subscribedTopics == pubsubTopicSeq
        otherNode.isSubscribed(pubsubTopic)
        otherNode.subscribedTopics == pubsubTopicSeq

      # When publishing a message that doesn't match the validator
      discard await node.publish(pubsubTopic, wakuMessage)

      # Then the validator is ran in the other node, and fails
      # Not run in the self node
      check:
        await validatorFuture.withTimeout(FUTURE_TIMEOUT)
        validatorFuture.read() == false

      # And the message is published in the self node, but not in the other node, 
      # because it doesn't pass the validator check.
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        not await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
      let (topic1, msg1) = handlerFuture.read()
      # let (otherTopic1, otherMsg1) = otherHandlerFuture.read()
      check:
        topic1 == pubsubTopic
        msg1 == wakuMessage
        # otherTopic1 == pubsubTopic
        # otherMsg1 == wakuMessage

      # When publishing a message that matches the validator
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      validatorFuture = newBoolFuture()
      let wakuMessage2 = fakeWakuMessage("12345678", pubsubTopic)
      discard await node.publish(pubsubTopic, wakuMessage2)

      # Then the validator is ran in the other node, and succeeds
      # Not run in the self node
      check:
        await validatorFuture.withTimeout(FUTURE_TIMEOUT)
        validatorFuture.read() == true

      # And the message is published in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
      let (topic2, msg2) = handlerFuture.read()
      let (otherTopic2, otherMsg2) = otherHandlerFuture.read()
      check:
        topic2 == pubsubTopic
        msg2 == wakuMessage2
        otherTopic2 == pubsubTopic
        otherMsg2 == wakuMessage2

      # Finally stop the other node
      await allFutures(otherSwitch.stop(), otherNode.stop())

    asyncTest "Max Topic Size":
      # NOT FOUND
      discard

    asyncTest "Max subscriptions":
      # NOT FOUND
      discard

    asyncTest "Message encryption/decryption":
      # Given a second node connected to the first one, both subscribed to the same Pubsub Topic
      let
        otherSwitch = newTestSwitch()
        otherNode = await newTestWakuRelay(otherSwitch)

      await allFutures(otherSwitch.start(), otherNode.start())
      let otherRemotePeerInfo = otherSwitch.peerInfo.toRemotePeerInfo()
      check await peerManager.connectPeer(otherRemotePeerInfo)

      var otherHandlerFuture = newPushHandlerFuture()
      proc otherSimpleFutureHandler(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        otherHandlerFuture.complete((topic, message))

      node.subscribe(pubsubTopic, simpleFutureHandler)
      otherNode.subscribe(pubsubTopic, otherSimpleFutureHandler)
      check:
        node.isSubscribed(pubsubTopic)
        node.subscribedTopics == pubsubTopicSeq
        otherNode.isSubscribed(pubsubTopic)
        otherNode.subscribedTopics == pubsubTopicSeq

      await sleepAsync(500.millis)

      # Given some crypto info
      var key = "My fancy key"
      var data = "Hello, Crypto!"
      var iv = "0123456789ABCDEF"

      # When publishing an encrypted message
      let encodedText = cfbEncode(key, iv, data)
      let encodedWakuMessage = fakeWakuMessage(encodedText, pubsubTopic)
      discard await node.publish(pubsubTopic, encodedWakuMessage)

      # Then the message is published in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
      let (topic1, msg1) = handlerFuture.read()
      let (otherTopic1, otherMsg1) = otherHandlerFuture.read()
      check:
        topic1 == pubsubTopic
        msg1 == encodedWakuMessage
        otherTopic1 == pubsubTopic
        otherMsg1 == encodedWakuMessage

      # When decoding the message
      let
        decodedText = cfbDecode(key, iv, msg1.payload)
        otherDecodedText = cfbDecode(key, iv, otherMsg1.payload)

      # Then the message is decrypted in both nodes
      check:
        decodedText.toString() == data
        otherDecodedText.toString() == data

      # Finally stop the other node
      await allFutures(otherSwitch.stop(), otherNode.stop())

    asyncTest "How multiple interconnected nodes work":
      # Given two other pubsub topics
      let
        pubsubTopicB = "/waku/2/rs/0/1"
        pubsubTopicC = "/waku/2/rs/0/2"

      # Given two other nodes connected to the first one
      let
        otherSwitch = newTestSwitch()
        otherPeerManager = PeerManager.new(otherSwitch)
        otherNode = await newTestWakuRelay(otherSwitch)
        anotherSwitch = newTestSwitch()
        anotherPeerManager = PeerManager.new(anotherSwitch)
        anotherNode = await newTestWakuRelay(anotherSwitch)

      await allFutures(
        otherSwitch.start(),
        otherNode.start(),
        anotherSwitch.start(),
        anotherNode.start(),
      )

      let
        otherRemotePeerInfo = otherSwitch.peerInfo.toRemotePeerInfo()
        otherPeerId = otherRemotePeerInfo.peerId
        anotherRemotePeerInfo = anotherSwitch.peerInfo.toRemotePeerInfo()
        anotherPeerId = anotherRemotePeerInfo.peerId

      check:
        await peerManager.connectPeer(otherRemotePeerInfo)
        await peerManager.connectPeer(anotherRemotePeerInfo)

      # Given the first node is subscribed to two pubsub topics
      var handlerFuture2 = newPushHandlerFuture()
      proc simpleFutureHandler2(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        handlerFuture2.complete((topic, message))

      node.subscribe(pubsubTopic, simpleFutureHandler)
      node.subscribe(pubsubTopicB, simpleFutureHandler2)

      # Given the other nodes are subscribed to two pubsub topics
      var otherHandlerFuture1 = newPushHandlerFuture()
      proc otherSimpleFutureHandler1(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        otherHandlerFuture1.complete((topic, message))

      var otherHandlerFuture2 = newPushHandlerFuture()
      proc otherSimpleFutureHandler2(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        otherHandlerFuture2.complete((topic, message))

      var anotherHandlerFuture1 = newPushHandlerFuture()
      proc anotherSimpleFutureHandler1(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        anotherHandlerFuture1.complete((topic, message))

      var anotherHandlerFuture2 = newPushHandlerFuture()
      proc anotherSimpleFutureHandler2(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        anotherHandlerFuture2.complete((topic, message))

      otherNode.subscribe(pubsubTopic, otherSimpleFutureHandler1)
      otherNode.subscribe(pubsubTopicC, otherSimpleFutureHandler2)
      anotherNode.subscribe(pubsubTopicB, anotherSimpleFutureHandler1)
      anotherNode.subscribe(pubsubTopicC, anotherSimpleFutureHandler2)
      await sleepAsync(500.millis)

      # When publishing a message in node for each of the pubsub topics
      let
        fromNodeWakuMessage1 = fakeWakuMessage("fromNode1")
        fromNodeWakuMessage2 = fakeWakuMessage("fromNode2")
        fromNodeWakuMessage3 = fakeWakuMessage("fromNode3")

      discard await node.publish(pubsubTopic, fromNodeWakuMessage1)
      discard await node.publish(pubsubTopicB, fromNodeWakuMessage2)
      discard await node.publish(pubsubTopicC, fromNodeWakuMessage3)

      # Then the messages are published in all nodes (because it's published in the center node)
      # Center meaning that all other nodes are connected to this one
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await handlerFuture2.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture1.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture2.withTimeout(FUTURE_TIMEOUT)
        await anotherHandlerFuture1.withTimeout(FUTURE_TIMEOUT)
        await anotherHandlerFuture2.withTimeout(FUTURE_TIMEOUT)

      let
        (topic1, msg1) = handlerFuture.read()
        (topic2, msg2) = handlerFuture2.read()
        (otherTopic1, otherMsg1) = otherHandlerFuture1.read()
        (otherTopic2, otherMsg2) = otherHandlerFuture2.read()
        (anotherTopic1, anotherMsg1) = anotherHandlerFuture1.read()
        (anotherTopic2, anotherMsg2) = anotherHandlerFuture2.read()

      check:
        topic1 == pubsubTopic
        msg1 == fromNodeWakuMessage1
        topic2 == pubsubTopicB
        msg2 == fromNodeWakuMessage2
        otherTopic1 == pubsubTopic
        otherMsg1 == fromNodeWakuMessage1
        otherTopic2 == pubsubTopicC
        otherMsg2 == fromNodeWakuMessage3
        anotherTopic1 == pubsubTopicB
        anotherMsg1 == fromNodeWakuMessage2
        anotherTopic2 == pubsubTopicC
        anotherMsg2 == fromNodeWakuMessage3

      # Given anotherNode is completely disconnected from the first one
      await anotherPeerManager.switch.disconnect(peerId)
      await peerManager.switch.disconnect(anotherPeerId)
      check:
        not anotherPeerManager.switch.isConnected(peerId)
        not peerManager.switch.isConnected(anotherPeerId)

      # When publishing a message in node for each of the pubsub topics
      handlerFuture = newPushHandlerFuture()
      handlerFuture2 = newPushHandlerFuture()
      otherHandlerFuture1 = newPushHandlerFuture()
      otherHandlerFuture2 = newPushHandlerFuture()
      anotherHandlerFuture1 = newPushHandlerFuture()
      anotherHandlerFuture2 = newPushHandlerFuture()

      let
        fromNodeWakuMessage4 = fakeWakuMessage("fromNode4")
        fromNodeWakuMessage5 = fakeWakuMessage("fromNode5")
        fromNodeWakuMessage6 = fakeWakuMessage("fromNode6")

      discard await node.publish(pubsubTopic, fromNodeWakuMessage4)
      discard await node.publish(pubsubTopicB, fromNodeWakuMessage5)
      discard await node.publish(pubsubTopicC, fromNodeWakuMessage6)

      # Then the message is published in node and otherNode, 
      # but not in anotherNode because it is not connected anymore
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await handlerFuture2.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture1.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture2.withTimeout(FUTURE_TIMEOUT)
        not await anotherHandlerFuture1.withTimeout(FUTURE_TIMEOUT)
        not await anotherHandlerFuture2.withTimeout(FUTURE_TIMEOUT)

      let
        (topic3, msg3) = handlerFuture.read()
        (topic4, msg4) = handlerFuture2.read()
        (otherTopic3, otherMsg3) = otherHandlerFuture1.read()
        (otherTopic4, otherMsg4) = otherHandlerFuture2.read()

      check:
        topic3 == pubsubTopic
        msg3 == fromNodeWakuMessage4
        topic4 == pubsubTopicB
        msg4 == fromNodeWakuMessage5
        otherTopic3 == pubsubTopic
        otherMsg3 == fromNodeWakuMessage4
        otherTopic4 == pubsubTopicC
        otherMsg4 == fromNodeWakuMessage6

      # When publishing a message in anotherNode for each of the pubsub topics
      handlerFuture = newPushHandlerFuture()
      handlerFuture2 = newPushHandlerFuture()
      otherHandlerFuture1 = newPushHandlerFuture()
      otherHandlerFuture2 = newPushHandlerFuture()
      anotherHandlerFuture1 = newPushHandlerFuture()
      anotherHandlerFuture2 = newPushHandlerFuture()

      let
        fromAnotherNodeWakuMessage1 = fakeWakuMessage("fromAnotherNode1")
        fromAnotherNodeWakuMessage2 = fakeWakuMessage("fromAnotherNode2")
        fromAnotherNodeWakuMessage3 = fakeWakuMessage("fromAnotherNode3")

      discard await anotherNode.publish(pubsubTopic, fromAnotherNodeWakuMessage1)
      discard await anotherNode.publish(pubsubTopicB, fromAnotherNodeWakuMessage2)
      discard await anotherNode.publish(pubsubTopicC, fromAnotherNodeWakuMessage3)

      # Then the messages are only published in anotherNode because it's disconnected from
      # the rest of the network
      check:
        not await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        not await handlerFuture2.withTimeout(FUTURE_TIMEOUT)
        not await otherHandlerFuture1.withTimeout(FUTURE_TIMEOUT)
        not await otherHandlerFuture2.withTimeout(FUTURE_TIMEOUT)
        await anotherHandlerFuture1.withTimeout(FUTURE_TIMEOUT)
        await anotherHandlerFuture2.withTimeout(FUTURE_TIMEOUT)

      let
        (anotherTopic3, anotherMsg3) = anotherHandlerFuture1.read()
        (anotherTopic4, anotherMsg4) = anotherHandlerFuture2.read()

      check:
        anotherTopic3 == pubsubTopicB
        anotherMsg3 == fromAnotherNodeWakuMessage2
        anotherTopic4 == pubsubTopicC
        anotherMsg4 == fromAnotherNodeWakuMessage3

      # When publishing a message in otherNode for each of the pubsub topics
      handlerFuture = newPushHandlerFuture()
      handlerFuture2 = newPushHandlerFuture()
      otherHandlerFuture1 = newPushHandlerFuture()
      otherHandlerFuture2 = newPushHandlerFuture()
      anotherHandlerFuture1 = newPushHandlerFuture()
      anotherHandlerFuture2 = newPushHandlerFuture()

      let
        fromOtherNodeWakuMessage1 = fakeWakuMessage("fromOtherNode1")
        fromOtherNodeWakuMessage2 = fakeWakuMessage("fromOtherNode2")
        fromOtherNodeWakuMessage3 = fakeWakuMessage("fromOtherNode3")

      discard await otherNode.publish(pubsubTopic, fromOtherNodeWakuMessage1)
      discard await otherNode.publish(pubsubTopicB, fromOtherNodeWakuMessage2)
      discard await otherNode.publish(pubsubTopicC, fromOtherNodeWakuMessage3)

      # Then the messages are only published in otherNode and node, but not in anotherNode
      # because it's disconnected from the rest of the network
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await handlerFuture2.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture1.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture2.withTimeout(FUTURE_TIMEOUT)
        not await anotherHandlerFuture1.withTimeout(FUTURE_TIMEOUT)
        not await anotherHandlerFuture2.withTimeout(FUTURE_TIMEOUT)

      let
        (topic5, msg5) = handlerFuture.read()
        (topic6, msg6) = handlerFuture2.read()
        (otherTopic5, otherMsg5) = otherHandlerFuture1.read()
        (otherTopic6, otherMsg6) = otherHandlerFuture2.read()

      check:
        topic5 == pubsubTopic
        msg5 == fromOtherNodeWakuMessage1
        topic6 == pubsubTopicB
        msg6 == fromOtherNodeWakuMessage2
        otherTopic5 == pubsubTopic
        otherMsg5 == fromOtherNodeWakuMessage1
        otherTopic6 == pubsubTopicC
        otherMsg6 == fromOtherNodeWakuMessage3

      # Given anotherNode is reconnected, but to otherNode
      check await anotherPeerManager.connectPeer(otherRemotePeerInfo)
      check:
        anotherPeerManager.switch.isConnected(otherPeerId)
        otherPeerManager.switch.isConnected(anotherPeerId)

      # Wait for the mesh to re-form before publishing (else it races the 1s FUTURE_TIMEOUT).
      check:
        await otherNode.waitForMeshPeer(pubsubTopicC, anotherPeerId)
        await anotherNode.waitForMeshPeer(pubsubTopicC, otherPeerId)

      # When publishing a message in anotherNode for each of the pubsub topics
      handlerFuture = newPushHandlerFuture()
      handlerFuture2 = newPushHandlerFuture()
      otherHandlerFuture1 = newPushHandlerFuture()
      otherHandlerFuture2 = newPushHandlerFuture()
      anotherHandlerFuture1 = newPushHandlerFuture()
      anotherHandlerFuture2 = newPushHandlerFuture()

      let
        fromAnotherNodeWakuMessage4 = fakeWakuMessage("fromAnotherNode4")
        fromAnotherNodeWakuMessage5 = fakeWakuMessage("fromAnotherNode5")
        fromAnotherNodeWakuMessage6 = fakeWakuMessage("fromAnotherNode6")

      discard await anotherNode.publish(pubsubTopic, fromAnotherNodeWakuMessage4)
      discard await anotherNode.publish(pubsubTopicB, fromAnotherNodeWakuMessage5)
      discard await anotherNode.publish(pubsubTopicC, fromAnotherNodeWakuMessage6)

      # Then the messages are published in all nodes except in node's B topic, because
      # even if they're connected like so AnotherNode <-> OtherNode <-> Node,
      # otherNode doesn't broadcast B topic messages because it's not subscribed to it
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        not await handlerFuture2.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture1.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture2.withTimeout(FUTURE_TIMEOUT)
        await anotherHandlerFuture1.withTimeout(FUTURE_TIMEOUT)
        await anotherHandlerFuture2.withTimeout(FUTURE_TIMEOUT)

      let
        (topic7, msg7) = handlerFuture.read()
        (otherTopic7, otherMsg7) = otherHandlerFuture1.read()
        (otherTopic8, otherMsg8) = otherHandlerFuture2.read()
        (anotherTopic7, anotherMsg7) = anotherHandlerFuture1.read()
        (anotherTopic8, anotherMsg8) = anotherHandlerFuture2.read()

      check:
        topic7 == pubsubTopic
        msg7 == fromAnotherNodeWakuMessage4
        otherTopic7 == pubsubTopic
        otherMsg7 == fromAnotherNodeWakuMessage4
        otherTopic8 == pubsubTopicC
        otherMsg8 == fromAnotherNodeWakuMessage6
        anotherTopic7 == pubsubTopicB
        anotherMsg7 == fromAnotherNodeWakuMessage5
        anotherTopic8 == pubsubTopicC
        anotherMsg8 == fromAnotherNodeWakuMessage6

      # Finally stop the other nodes
      await allFutures(
        otherSwitch.stop(), otherNode.stop(), anotherSwitch.stop(), anotherNode.stop()
      )

  suite "Unsubscribe":
    asyncTest "Without Subscription":
      # Given an external topic handler
      let
        otherSwitch = newTestSwitch()
        otherNode = await newTestWakuRelay(otherSwitch)
      await allFutures(otherSwitch.start(), otherNode.start())
      otherNode.subscribe(pubsubTopic, simpleFutureHandler)

      # Given a node without a subscription
      check:
        node.subscribedTopics == []

      node.unsubscribe(pubsubTopic)

      # Then the node is still not subscribed
      check:
        node.subscribedTopics == []

      # Finally stop the other node
      await allFutures(otherSwitch.stop(), otherNode.stop())

    asyncTest "Single Node with Single Pubsub Topic":
      # Given a node subscribed to a pubsub topic
      node.subscribe(pubsubTopic, simpleFutureHandler)
      check node.subscribedTopics == pubsubTopicSeq

      # When unsubscribing from the pubsub topic
      node.unsubscribe(pubsubTopic)

      # Then the node is not subscribed anymore
      check node.subscribedTopics == []

    asyncTest "Single Node with Multiple Pubsub Topics":
      # Given other pubsub topic 
      let pubsubTopicB = "/waku/2/rs/0/1"

      # Given a node subscribed to multiple pubsub topics
      node.subscribe(pubsubTopic, simpleFutureHandler)
      node.subscribe(pubsubTopicB, simpleFutureHandler)

      assert pubsubTopic in node.subscribedTopics,
        fmt"Node is not subscribed to {pubsubTopic}"
      assert pubsubTopicB in node.subscribedTopics,
        fmt"Node is not subscribed to {pubsubTopicB}"

      # When unsubscribing from one of the pubsub topics
      node.unsubscribe(pubsubTopic)

      # Then the node is still subscribed to the other pubsub topic
      check node.subscribedTopics == @[pubsubTopicB]

      # When unsubscribing from the other pubsub topic
      node.unsubscribe(pubsubTopicB)

      # Then the node is not subscribed anymore
      check node.subscribedTopics == []

  suite "Unsubscribe All":
    asyncTest "Without subscriptions":
      # Given a node without subscriptions
      check node.subscribedTopics == []

      # When unsubscribing from all pubsub topics
      node.unsubscribeAll(pubsubTopic)

      # Then the node is still not subscribed
      check node.subscribedTopics == []

    asyncTest "Single Node with Single Pubsub Topic":
      # Given a node subscribed to a pubsub topic
      node.subscribe(pubsubTopic, simpleFutureHandler)
      check node.subscribedTopics == pubsubTopicSeq

      # When unsubscribing from all pubsub topics
      node.unsubscribeAll(pubsubTopic)

      # Then the node is not subscribed anymore
      check node.subscribedTopics == []

    asyncTest "Single Node with Multiple Pubsub Topics":
      # Given other pubsub topic
      let pubsubTopicB = "/waku/2/rs/0/1"

      # Given a node subscribed to multiple pubsub topics
      node.subscribe(pubsubTopic, simpleFutureHandler)
      node.subscribe(pubsubTopic, simpleFutureHandler)
      node.subscribe(pubsubTopicB, simpleFutureHandler)

      assert pubsubTopic in node.subscribedTopics,
        fmt"Node is not subscribed to {pubsubTopic}"
      assert pubsubTopicB in node.subscribedTopics,
        fmt"Node is not subscribed to {pubsubTopicB}"

      # When unsubscribing all handlers from pubsubTopic
      node.unsubscribeAll(pubsubTopic)

      # Then the node doesn't have pubsubTopic handlers
      check node.subscribedTopics == @[pubsubTopicB]

      # When unsubscribing all handlers from pubsubTopicB
      node.unsubscribeAll(pubsubTopicB)

      # Then the node is not subscribed to anything
      check node.subscribedTopics == []

  suite "Send & Retrieve Messages":
    asyncTest "Valid Payload Types":
      # Given a second node connected to the first one
      let
        otherSwitch = newTestSwitch()
        otherNode = await newTestWakuRelay(otherSwitch)

      await allFutures(otherSwitch.start(), otherNode.start())
      let otherRemotePeerInfo = otherSwitch.peerInfo.toRemotePeerInfo()
      check await peerManager.connectPeer(otherRemotePeerInfo)

      # Given both are subscribed to the same pubsub topic
      var otherHandlerFuture = newPushHandlerFuture()
      proc otherSimpleFutureHandler(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        otherHandlerFuture.complete((topic, message))

      otherNode.subscribe(pubsubTopic, otherSimpleFutureHandler)
      node.subscribe(pubsubTopic, simpleFutureHandler)
      check:
        node.subscribedTopics == pubsubTopicSeq
        otherNode.subscribedTopics == pubsubTopicSeq

      await sleepAsync(500.millis)

      # Given some payloads
      let
        JSON_DICTIONARY = getSampleJsonDictionary()
        JSON_LIST = getSampleJsonList()

      # Given some valid messages
      let
        msg1 = fakeWakuMessage(contentTopic = contentTopic, payload = ALPHABETIC)
        msg2 = fakeWakuMessage(contentTopic = contentTopic, payload = ALPHANUMERIC)
        msg3 =
          fakeWakuMessage(contentTopic = contentTopic, payload = ALPHANUMERIC_SPECIAL)
        msg4 = fakeWakuMessage(contentTopic = contentTopic, payload = EMOJI)
        msg5 = fakeWakuMessage(contentTopic = contentTopic, payload = CODE)
        msg6 = fakeWakuMessage(contentTopic = contentTopic, payload = QUERY)
        msg7 =
          fakeWakuMessage(contentTopic = contentTopic, payload = ($JSON_DICTIONARY))
        msg8 = fakeWakuMessage(contentTopic = contentTopic, payload = ($JSON_LIST))
        msg9 = fakeWakuMessage(contentTopic = contentTopic, payload = TEXT_SMALL)
        msg10 = fakeWakuMessage(contentTopic = contentTopic, payload = TEXT_LARGE)

      # When sending the alphabetic message
      discard await node.publish(pubsubTopic, msg1)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg1) == handlerFuture.read()
        (pubsubTopic, msg1) == otherHandlerFuture.read()

      # When sending the alphanumeric message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg2)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg2) == handlerFuture.read()
        (pubsubTopic, msg2) == otherHandlerFuture.read()

      # When sending the alphanumeric special message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg3)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg3) == handlerFuture.read()
        (pubsubTopic, msg3) == otherHandlerFuture.read()

      # When sending the emoji message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg4)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg4) == handlerFuture.read()
        (pubsubTopic, msg4) == otherHandlerFuture.read()

      # When sending the code message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg5)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg5) == handlerFuture.read()
        (pubsubTopic, msg5) == otherHandlerFuture.read()

      # When sending the query message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg6)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg6) == handlerFuture.read()
        (pubsubTopic, msg6) == otherHandlerFuture.read()

      # When sending the JSON dictionary message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg7)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg7) == handlerFuture.read()
        (pubsubTopic, msg7) == otherHandlerFuture.read()

      # When sending the JSON list message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg8)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg8) == handlerFuture.read()
        (pubsubTopic, msg8) == otherHandlerFuture.read()

      # When sending the small text message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg9)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg9) == handlerFuture.read()
        (pubsubTopic, msg9) == otherHandlerFuture.read()

      # When sending the large text message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg10)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg10) == handlerFuture.read()
        (pubsubTopic, msg10) == otherHandlerFuture.read()

      # Finally stop the other node
      await allFutures(otherSwitch.stop(), otherNode.stop())

    asyncTest "Valid Payload Sizes":
      # Given a second node connected to the first one
      let
        otherSwitch = newTestSwitch()
        otherNode = await newTestWakuRelay(otherSwitch)

      await allFutures(otherSwitch.start(), otherNode.start())
      let otherRemotePeerInfo = otherSwitch.peerInfo.toRemotePeerInfo()
      check await peerManager.connectPeer(otherRemotePeerInfo)

      # Given both are subscribed to the same pubsub topic
      var otherHandlerFuture = newPushHandlerFuture()
      proc otherSimpleFutureHandler(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        otherHandlerFuture.complete((topic, message))

      otherNode.subscribe(pubsubTopic, otherSimpleFutureHandler)
      node.subscribe(pubsubTopic, simpleFutureHandler)
      check:
        node.subscribedTopics == pubsubTopicSeq
        otherNode.subscribedTopics == pubsubTopicSeq

      await sleepAsync(500.millis)

      # Given some valid payloads
      let
        msgWithoutPayload =
          fakeWakuMessage(contentTopic = contentTopic, payload = getByteSequence(0))
        sizeEmptyMsg = uint64(msgWithoutPayload.encode().buffer.len)

      let
        msg1 =
          fakeWakuMessage(contentTopic = contentTopic, payload = getByteSequence(1024))
          # 1KiB
        msg2 = fakeWakuMessage(
          contentTopic = contentTopic, payload = getByteSequence(10 * 1024)
        ) # 10KiB 
        msg3 = fakeWakuMessage(
          contentTopic = contentTopic, payload = getByteSequence(100 * 1024)
        ) # 100KiB
        msg4 = fakeWakuMessage(
          contentTopic = contentTopic,
          payload = getByteSequence(DefaultMaxWakuMessageSize - sizeEmptyMsg - 26),
        ) # Max Size (Inclusive Limit)
        msg5 = fakeWakuMessage(
          contentTopic = contentTopic,
          payload = getByteSequence(DefaultMaxWakuMessageSize - sizeEmptyMsg - 25),
        ) # Max Size (Exclusive Limit)
        msg6 = fakeWakuMessage(
          contentTopic = contentTopic,
          payload = getByteSequence(DefaultMaxWakuMessageSize),
        ) # MaxWakuMessageSize -> Out of Max Size

      # Notice that the message is wrapped with more data in https://github.com/status-im/nim-libp2p/blob/3011ba4326fa55220a758838835797ff322619fc/libp2p/protocols/pubsub/gossipsub.nim#L627-L632
      # And therefore, we need to substract a hard-coded values above (for msg4 & msg5), obtained empirically,
      # running the tests with 'TRACE' level: nim c -r -d:chronicles_log_level=DEBUG -d:release -d:postgres  -d:rln --passL:librln_v0.3.4.a --passL:-lm -d:nimDebugDlOpen tests/waku_relay/test_protocol.nim test "Valid Payload Sizes"

      # When sending the 1KiB message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg1)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg1) == handlerFuture.read()
        (pubsubTopic, msg1) == otherHandlerFuture.read()

      # When sending the 10KiB message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg2)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg2) == handlerFuture.read()
        (pubsubTopic, msg2) == otherHandlerFuture.read()

      # When sending the 100KiB message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg3)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg3) == handlerFuture.read()
        (pubsubTopic, msg3) == otherHandlerFuture.read()

      # When sending the 'DefaultMaxWakuMessageSize - sizeEmptyMsg - 38' message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg4)

      # Then the message is received in both nodes
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg4) == handlerFuture.read()
        (pubsubTopic, msg4) == otherHandlerFuture.read()

      # When sending the 'DefaultMaxWakuMessageSize - sizeEmptyMsg - 37' message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg5)

      # Then the message is received in self, because there's no checking, but not in other node
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        not await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg5) == handlerFuture.read()

      # When sending the 'DefaultMaxWakuMessageSize' message
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg6)

      # Then the message is received in self, because there's no checking, but not in other node
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        not await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg6) == handlerFuture.read()

      # Finally stop the other node
      await allFutures(otherSwitch.stop(), otherNode.stop())

    asyncTest "Multiple messages at once":
      # Given a second node connected to the first one
      let
        otherSwitch = newTestSwitch()
        otherNode = await newTestWakuRelay(otherSwitch)

      await allFutures(otherSwitch.start(), otherNode.start())
      let otherRemotePeerInfo = otherSwitch.peerInfo.toRemotePeerInfo()
      check await peerManager.connectPeer(otherRemotePeerInfo)

      # Given both are subscribed to the same pubsub topic
      # Create a different handler than the default to include messages in a seq
      var thisHandlerFuture = newPushHandlerFuture()
      var thisMessageSeq: seq[(PubsubTopic, WakuMessage)] = @[]
      proc thisSimpleFutureHandler(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        thisMessageSeq.add((topic, message))
        thisHandlerFuture.complete((topic, message))

      var otherHandlerFuture = newPushHandlerFuture()
      var otherMessageSeq: seq[(PubsubTopic, WakuMessage)] = @[]
      proc otherSimpleFutureHandler(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        otherMessageSeq.add((topic, message))
        otherHandlerFuture.complete((topic, message))

      node.subscribe(pubsubTopic, thisSimpleFutureHandler)
      otherNode.subscribe(pubsubTopic, otherSimpleFutureHandler)
      check:
        node.subscribedTopics == pubsubTopicSeq
        otherNode.subscribedTopics == pubsubTopicSeq
      await sleepAsync(500.millis)

      # When sending multiple messages from node
      let
        msg1 = fakeWakuMessage("msg1", pubsubTopic)
        msg2 = fakeWakuMessage("msg2", pubsubTopic)
        msg3 = fakeWakuMessage("msg3", pubsubTopic)
        msg4 = fakeWakuMessage("msg4", pubsubTopic)

      discard await node.publish(pubsubTopic, msg1)
      check await thisHandlerFuture.withTimeout(FUTURE_TIMEOUT)
      check await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
      thisHandlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg2)
      check await thisHandlerFuture.withTimeout(FUTURE_TIMEOUT)
      check await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
      thisHandlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg3)
      check await thisHandlerFuture.withTimeout(FUTURE_TIMEOUT)
      check await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
      thisHandlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      discard await node.publish(pubsubTopic, msg4)

      check:
        await thisHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        thisMessageSeq ==
          @[
            (pubsubTopic, msg1),
            (pubsubTopic, msg2),
            (pubsubTopic, msg3),
            (pubsubTopic, msg4),
          ]
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        otherMessageSeq ==
          @[
            (pubsubTopic, msg1),
            (pubsubTopic, msg2),
            (pubsubTopic, msg3),
            (pubsubTopic, msg4),
          ]

      # Finally stop the other node
      await allFutures(otherSwitch.stop(), otherNode.stop())

  suite "Security and Privacy":
    asyncTest "Relay can't receive messages after subscribing and stopping without unsubscribing":
      # Given a second node connected to the first one
      let
        otherSwitch = newTestSwitch()
        otherPeerManager = PeerManager.new(otherSwitch)
        otherNode = await newTestWakuRelay(otherSwitch)

      await allFutures(otherSwitch.start(), otherNode.start())
      let
        otherRemotePeerInfo = otherSwitch.peerInfo.toRemotePeerInfo()
        otherPeerId = otherRemotePeerInfo.peerId

      check await peerManager.connectPeer(otherRemotePeerInfo)

      # Given both are subscribed to the same pubsub topic
      var otherHandlerFuture = newPushHandlerFuture()
      proc otherSimpleFutureHandler(
          topic: PubsubTopic, message: WakuMessage
      ) {.async, gcsafe.} =
        otherHandlerFuture.complete((topic, message))

      otherNode.subscribe(pubsubTopic, otherSimpleFutureHandler)
      node.subscribe(pubsubTopic, simpleFutureHandler)
      check:
        node.subscribedTopics == pubsubTopicSeq
        otherNode.subscribedTopics == pubsubTopicSeq

      await sleepAsync(500.millis)

      # Given other node is stopped without unsubscribing
      await allFutures(otherSwitch.stop(), otherNode.stop())

      # When sending a message from node
      let msg1 = fakeWakuMessage(testMessage, pubsubTopic)
      discard await node.publish(pubsubTopic, msg1)

      # Then the message is not received in any node
      check:
        await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        not await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg1) == handlerFuture.read()

      # When sending a message from other node
      handlerFuture = newPushHandlerFuture()
      otherHandlerFuture = newPushHandlerFuture()
      let msg2 = fakeWakuMessage(testMessage, pubsubTopic)
      discard await otherNode.publish(pubsubTopic, msg2)

      # Then the message is received in both nodes
      check:
        not await handlerFuture.withTimeout(FUTURE_TIMEOUT)
        await otherHandlerFuture.withTimeout(FUTURE_TIMEOUT)
        (pubsubTopic, msg2) == otherHandlerFuture.read()
