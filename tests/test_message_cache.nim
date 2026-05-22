{.used.}

import std/[sets, random], results, stew/byteutils, testutils/unittests
import waku/waku_core, waku/rest_api/message_cache, ./testlib/wakucore

randomize()

suite "MessageCache":
  setup:
    ## Given
    let capacity = 3
    let testPubsubTopic = DefaultPubsubTopic
    let testContentTopic = DefaultContentTopic
    let cache = MessageCache.init(capacity)

  test "subscribe to topic":
    ## When
    cache.pubsubSubscribe(testPubsubTopic)
    cache.pubsubSubscribe(testPubsubTopic)

    # idempotence of subscribe is also tested
    cache.contentSubscribe(testContentTopic)
    cache.contentSubscribe(testContentTopic)

    ## Then
    check:
      cache.isPubsubSubscribed(testPubsubTopic)
      cache.isContentSubscribed(testContentTopic)
      cache.pubsubTopicCount() == 1
      cache.contentTopicCount() == 1

  test "unsubscribe from topic":
    # Init cache content
    cache.pubsubSubscribe(testPubsubTopic)
    cache.contentSubscribe(testContentTopic)

    cache.pubsubSubscribe("AnotherPubsubTopic")
    cache.contentSubscribe("AnotherContentTopic")

    ## When
    cache.pubsubUnsubscribe(testPubsubTopic)
    cache.contentUnsubscribe(testContentTopic)

    ## Then
    check:
      not cache.isPubsubSubscribed(testPubsubTopic)
      not cache.isContentSubscribed(testContentTopic)
      cache.pubsubTopicCount() == 1
      cache.contentTopicCount() == 1

  test "get messages of a subscribed topic":
    ## Given
    let testMessage = fakeWakuMessage()

    # Init cache content
    cache.pubsubSubscribe(testPubsubTopic)
    cache.addMessage(testPubsubTopic, testMessage)

    ## When
    let res = cache.getMessages(testPubsubTopic)

    ## Then
    check:
      res.isOk()
      res.get() == @[testMessage]

  test "get messages with clean flag shoud clear the messages cache":
    ## Given
    let testMessage = fakeWakuMessage()

    # Init cache content
    cache.pubsubSubscribe(testPubsubTopic)
    cache.addMessage(testPubsubTopic, testMessage)

    ## When
    var res = cache.getMessages(testPubsubTopic, clear = true)
    require(res.isOk())

    res = cache.getMessages(testPubsubTopic)

    ## Then
    check:
      res.isOk()
      res.get().len == 0

  test "get messages of a non-subscribed topic":
    ## When
    cache.pubsubSubscribe(PubsubTopic("dummyPubsub"))
    let res = cache.getMessages(testPubsubTopic)

    ## Then
    check:
      res.isErr()
      res.error() == "not subscribed to this pubsub topic"

  test "add messages to subscribed topic":
    ## Given
    let testMessage = fakeWakuMessage()

    cache.pubsubSubscribe(testPubsubTopic)

    ## When
    cache.addMessage(testPubsubTopic, testMessage)

    ## Then
    let messages = cache.getMessages(testPubsubTopic).tryGet()
    check:
      messages == @[testMessage]

  test "add messages to non-subscribed topic":
    ## Given
    let testMessage = fakeWakuMessage()

    ## When
    cache.addMessage(testPubsubTopic, testMessage)

    ## Then
    let res = cache.getMessages(testPubsubTopic)
    check:
      res.isErr()
      res.error() == "not subscribed to any pubsub topics"

  test "add messages beyond the capacity":
    ## Given
    var testMessages = @[fakeWakuMessage(toBytes("MSG-1"))]

    # Prevent duplicate messages timestamp
    for i in 0 ..< 5:
      var msg = fakeWakuMessage(toBytes("MSG-1"))

      while msg.timestamp <= testMessages[i].timestamp:
        msg = fakeWakuMessage(toBytes("MSG-1"))

      testMessages.add(msg)

    cache.pubsubSubscribe(testPubsubTopic)

    ## When
    for msg in testMessages:
      cache.addMessage(testPubsubTopic, msg)

    ## Then
    let messages = cache.getMessages(testPubsubTopic).tryGet()
    let messageSet = toHashSet(messages)

    let testSet = toHashSet(testMessages)

    check:
      messageSet.len == capacity
      messageSet < testSet
      testMessages[0] notin messages

  test "get messages on pubsub via content topics":
    cache.pubsubSubscribe(testPubsubTopic)

    let fakeMessage = fakeWakuMessage()

    cache.addMessage(testPubsubTopic, fakeMessage)

    let getRes = cache.getAutoMessages(DefaultContentTopic)

    check:
      getRes.isOk
      getRes.get() == @[fakeMessage]

  test "add same message twice":
    cache.pubsubSubscribe(testPubsubTopic)

    let fakeMessage = fakeWakuMessage()

    cache.addMessage(testPubsubTopic, fakeMessage)
    cache.addMessage(testPubsubTopic, fakeMessage)

    check:
      cache.messagesCount() == 1

  test "unsubscribing remove messages":
    let topic0 = "PubsubTopic0"
    let topic1 = "PubsubTopic1"
    let topic2 = "PubsubTopic2"

    let fakeMessage0 = fakeWakuMessage(toBytes("MSG-0"))
    let fakeMessage1 = fakeWakuMessage(toBytes("MSG-1"))
    let fakeMessage2 = fakeWakuMessage(toBytes("MSG-2"))

    cache.pubsubSubscribe(topic0)
    cache.pubsubSubscribe(topic1)
    cache.pubsubSubscribe(topic2)
    cache.contentSubscribe("ContentTopic0")

    cache.addMessage(topic0, fakeMessage0)
    cache.addMessage(topic1, fakeMessage1)
    cache.addMessage(topic2, fakeMessage2)

    cache.pubsubUnsubscribe(topic0)

    # at this point, fakeMessage0 is only ref by DefaultContentTopic

    let res = cache.getAutoMessages(DefaultContentTopic)

    check:
      res.isOk()
      res.get().len == 3
      cache.isPubsubSubscribed(topic0) == false
      cache.isPubsubSubscribed(topic1) == true
      cache.isPubsubSubscribed(topic2) == true

    cache.contentUnsubscribe(DefaultContentTopic)

    # msg0 was delete because no refs

    check:
      cache.messagesCount() == 2

  test "fuzzing":
    let testContentTopic1 = "contentTopic1"
    let testContentTopic2 = "contentTopic2"

    let cache = MessageCache.init(50)

    cache.contentSubscribe(testContentTopic1)
    cache.contentSubscribe(testContentTopic2)

    for _ in 0 .. 10000:
      let numb = rand(1.0)

      if numb > 0.4:
        let topic = if rand(1.0) > 0.5: testContentTopic1 else: testContentTopic2

        let testMessage = fakeWakuMessage(contentTopic = topic)

        cache.addMessage(DefaultPubsubTopic, testMessage)
      elif numb > 0.1:
        let topic = if rand(1.0) > 0.5: testContentTopic1 else: testContentTopic2

        let clear = rand(1.0) > 0.5
        discard cache.getAutoMessages(topic, clear)
      elif numb > 0.05:
        if rand(1.0) > 0.5:
          cache.pubsubUnsubscribe(DefaultPubsubTopic)
        else:
          cache.pubsubSubscribe(DefaultPubsubTopic)
      else:
        let topic = if rand(1.0) > 0.5: testContentTopic1 else: testContentTopic2

        if rand(1.0) > 0.5:
          cache.contentUnsubscribe(topic)
        else:
          cache.contentSubscribe(topic)
