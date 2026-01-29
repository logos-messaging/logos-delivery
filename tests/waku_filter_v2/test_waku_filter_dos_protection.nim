{.used.}

import
  std/[options, tables, json],
  testutils/unittests,
  results,
  chronos,
  chronicles,
  libp2p/peerstore

import
  waku/[node/peer_manager, waku_core],
  waku/waku_filter_v2/[common, client, subscriptions, protocol],
  ../testlib/[wakucore, testasync, futures],
  ./waku_filter_utils

type AFilterClient = ref object of RootObj
  clientSwitch*: Switch
  wakuFilterClient*: WakuFilterClient
  clientPeerId*: PeerId
  messagePushHandler*: FilterPushHandler
  msgSeq*: seq[(PubsubTopic, WakuMessage)]
  pushHandlerFuture*: Future[(PubsubTopic, WakuMessage)]

proc init(T: type[AFilterClient]): T =
  var r = T(
    clientSwitch: newStandardSwitch(),
    msgSeq: @[],
    pushHandlerFuture: newPushHandlerFuture(),
  )
  r.wakuFilterClient = waitFor newTestWakuFilterClient(r.clientSwitch)
  r.messagePushHandler = proc(
      pubsubTopic: PubsubTopic, message: WakuMessage
  ): Future[void] {.async, closure, gcsafe.} =
    r.msgSeq.add((pubsubTopic, message))
    r.pushHandlerFuture.complete((pubsubTopic, message))

  r.clientPeerId = r.clientSwitch.peerInfo.toRemotePeerInfo().peerId
  r.wakuFilterClient.registerPushHandler(r.messagePushHandler)
  return r

proc subscribe(
    client: AFilterClient,
    serverRemotePeerInfo: RemotePeerInfo,
    pubsubTopic: PubsubTopic,
    contentTopicSeq: seq[ContentTopic],
): Option[FilterSubscribeErrorKind] =
  let subscribeResponse = waitFor client.wakuFilterClient.subscribe(
    serverRemotePeerInfo, pubsubTopic, contentTopicSeq
  )
  if subscribeResponse.isOk():
    return none[FilterSubscribeErrorKind]()

  return some(subscribeResponse.error().kind)

proc unsubscribe(
    client: AFilterClient,
    serverRemotePeerInfo: RemotePeerInfo,
    pubsubTopic: PubsubTopic,
    contentTopicSeq: seq[ContentTopic],
): Option[FilterSubscribeErrorKind] =
  let unsubscribeResponse = waitFor client.wakuFilterClient.unsubscribe(
    serverRemotePeerInfo, pubsubTopic, contentTopicSeq
  )
  if unsubscribeResponse.isOk():
    return none[FilterSubscribeErrorKind]()

  return some(unsubscribeResponse.error().kind)

proc ping(
    client: AFilterClient, serverRemotePeerInfo: RemotePeerInfo
): Option[FilterSubscribeErrorKind] =
  let pingResponse = waitFor client.wakuFilterClient.ping(serverRemotePeerInfo)
  if pingResponse.isOk():
    return none[FilterSubscribeErrorKind]()

  return some(pingResponse.error().kind)

suite "Waku Filter - DOS protection":
  var serverSwitch {.threadvar.}: Switch
  var client1 {.threadvar.}: AFilterClient
  var client2 {.threadvar.}: AFilterClient
  var wakuFilter {.threadvar.}: WakuFilter
  var serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
  var pubsubTopic {.threadvar.}: PubsubTopic
  var contentTopic {.threadvar.}: ContentTopic
  var contentTopicSeq {.threadvar.}: seq[ContentTopic]

  asyncSetup:
    client1 = AFilterClient.init()
    client2 = AFilterClient.init()

    pubsubTopic = DefaultPubsubTopic
    contentTopic = DefaultContentTopic
    contentTopicSeq = @[contentTopic]
    serverSwitch = newStandardSwitch()
    wakuFilter = await newTestWakuFilter(
      serverSwitch, rateLimitSetting = some((3, 1000.milliseconds))
    )

    await allFutures(
      serverSwitch.start(), client1.clientSwitch.start(), client2.clientSwitch.start()
    )
    serverRemotePeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    client1.clientPeerId = client1.clientSwitch.peerInfo.toRemotePeerInfo().peerId
    client2.clientPeerId = client2.clientSwitch.peerInfo.toRemotePeerInfo().peerId

  asyncTeardown:
    await allFutures(
      wakuFilter.stop(),
      client1.wakuFilterClient.stop(),
      client2.wakuFilterClient.stop(),
      serverSwitch.stop(),
      client1.clientSwitch.stop(),
      client2.clientSwitch.stop(),
    )

  asyncTest "Limit number of subscriptions requests":
    # Given
    check client1.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check client2.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)

    # Avoid using tiny sleeps to control refill behavior: CI scheduling can
    # oversleep and mint additional tokens. Instead, issue a small burst of
    # subscribe requests and require at least one TOO_MANY_REQUESTS.
    var c1SubscribeFutures = newSeq[Future[FilterSubscribeResult]]()
    for i in 0 ..< 6:
      c1SubscribeFutures.add(
        client1.wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
      )

    let c1Finished = await allFinished(c1SubscribeFutures)
    var c1GotTooMany = false
    for fut in c1Finished:
      check not fut.failed()
      let res = fut.read()
      if res.isErr() and res.error().kind == FilterSubscribeErrorKind.TOO_MANY_REQUESTS:
        c1GotTooMany = true
        break
    check c1GotTooMany

    # Ensure the other client is not affected by client1's rate limit.
    check client2.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)

    var c2SubscribeFutures = newSeq[Future[FilterSubscribeResult]]()
    for i in 0 ..< 6:
      c2SubscribeFutures.add(
        client2.wakuFilterClient.subscribe(
          serverRemotePeerInfo, pubsubTopic, contentTopicSeq
        )
      )

    let c2Finished = await allFinished(c2SubscribeFutures)
    var c2GotTooMany = false
    for fut in c2Finished:
      check not fut.failed()
      let res = fut.read()
      if res.isErr() and res.error().kind == FilterSubscribeErrorKind.TOO_MANY_REQUESTS:
        c2GotTooMany = true
        break
    check c2GotTooMany

    # ensure period of time has passed and clients can again use the service
    await sleepAsync(1100.milliseconds)
    check client1.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check client2.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)

  asyncTest "Ensure normal usage allowed":
    # Given
    # Rate limit setting is (3 requests / 1000ms) per peer.
    # In a token-bucket model this means:
    # - capacity = 3 tokens
    # - refill rate = 3 tokens / second => ~1 token every ~333ms
    # - each request consumes 1 token (including UNSUBSCRIBE)
    check client1.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check wakuFilter.subscriptions.isSubscribed(client1.clientPeerId)

    # Expected remaining tokens (approx): 2

    await sleepAsync(500.milliseconds)
    check client1.ping(serverRemotePeerInfo) == none(FilterSubscribeErrorKind)
    check wakuFilter.subscriptions.isSubscribed(client1.clientPeerId)

    # After ~500ms, ~1 token refilled; PING consumes 1 => expected remaining: 2

    await sleepAsync(500.milliseconds)
    check client1.ping(serverRemotePeerInfo) == none(FilterSubscribeErrorKind)
    check wakuFilter.subscriptions.isSubscribed(client1.clientPeerId)

    # After another ~500ms, ~1 token refilled; PING consumes 1 => expected remaining: 2

    check client1.unsubscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check wakuFilter.subscriptions.isSubscribed(client1.clientPeerId) == false

    check client1.ping(serverRemotePeerInfo) == some(FilterSubscribeErrorKind.NOT_FOUND)
    # After unsubscribing, PING is expected to return NOT_FOUND while still
    # counting towards the rate limit.

    # CI can oversleep / schedule slowly, which can mint extra tokens between
    # requests. To make the test robust, issue a small burst of pings and
    # require at least one TOO_MANY_REQUESTS response.
    var pingFutures = newSeq[Future[FilterSubscribeResult]]()
    for i in 0 ..< 9:
      pingFutures.add(client1.wakuFilterClient.ping(serverRemotePeerInfo))

    let finished = await allFinished(pingFutures)
    var gotTooMany = false
    for fut in finished:
      check not fut.failed()
      let pingRes = fut.read()
      if pingRes.isErr() and
          pingRes.error().kind == FilterSubscribeErrorKind.TOO_MANY_REQUESTS:
        gotTooMany = true
        break

    check gotTooMany

    check client2.subscribe(serverRemotePeerInfo, pubsubTopic, contentTopicSeq) ==
      none(FilterSubscribeErrorKind)
    check wakuFilter.subscriptions.isSubscribed(client2.clientPeerId) == true
