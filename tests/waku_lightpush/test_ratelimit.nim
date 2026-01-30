{.used.}

import std/options, testutils/unittests, chronos, libp2p/crypto/crypto

import
  waku/[node/peer_manager, waku_core, waku_lightpush, waku_lightpush/client],
  ../testlib/wakucore,
  ./lightpush_utils

suite "Rate limited push service":
  asyncTest "push message with rate limit not violated":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    var handlerFuture = newFuture[(string, WakuMessage)]()
    let handler: PushMessageHandler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return lightpushSuccessResult(1) # succeed to publish to 1 peer.

    let
      tokenPeriod = 500.millis
      server =
        await newTestWakuLightpushNode(serverSwitch, handler, some((3, tokenPeriod)))
      client = newTestWakuLightpushClient(clientSwitch)

    let serverPeerId = serverSwitch.peerInfo.toRemotePeerInfo()

    let sendMsgProc = proc(): Future[void] {.async.} =
      let message = fakeWakuMessage()

      handlerFuture = newFuture[(string, WakuMessage)]()
      let requestRes =
        await client.publish(some(DefaultPubsubTopic), message, serverPeerId)

      check await handlerFuture.withTimeout(50.millis)

      check:
        requestRes.isOk()
        handlerFuture.finished()

      let (handledMessagePubsubTopic, handledMessage) = handlerFuture.read()

      check:
        handledMessagePubsubTopic == DefaultPubsubTopic
        handledMessage == message

    let waitInBetweenFor = 20.millis

    # Test cannot be too explicit about the time when the TokenBucket resets
    # the internal timer, although in normal use there is no use case to care about it.
    var firstWaitExtend = 300.millis

    for runCnt in 0 ..< 3:
      let startTime = Moment.now()
      for testCnt in 0 ..< 3:
        await sendMsgProc()
        await sleepAsync(20.millis)

      var endTime = Moment.now()
      var elapsed: Duration = (endTime - startTime)
      await sleepAsync(tokenPeriod - elapsed + firstWaitExtend)
      firstWaitExtend = 100.millis

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "push message with rate limit reject":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    # Don't rely on per-request timing assumptions or a single shared Future.
    # CI can be slow enough that sequential requests accidentally refill tokens.
    # Instead we issue a small burst and assert we observe at least one rejection.
    let handler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      return lightpushSuccessResult(1)

    let
      server =
        await newTestWakuLightpushNode(serverSwitch, handler, some((3, 500.millis)))
      client = newTestWakuLightpushClient(clientSwitch)

    let serverPeerId = serverSwitch.peerInfo.toRemotePeerInfo()
    let tokenPeriod = 500.millis

    # Fire a burst of requests; require at least one success and one rejection.
    var publishFutures = newSeq[Future[WakuLightPushResult]]()
    for i in 0 ..< 10:
      let message = fakeWakuMessage()
      publishFutures.add(
        client.publish(some(DefaultPubsubTopic), message, serverPeerId)
      )

    let finished = await allFinished(publishFutures)
    var gotOk = false
    var gotTooMany = false
    for fut in finished:
      check not fut.failed()
      let res = fut.read()
      if res.isOk():
        gotOk = true
      else:
        check res.error.code == LightPushErrorCode.TOO_MANY_REQUESTS
        check res.error.desc == some(TooManyRequestsMessage)
        gotTooMany = true

    check gotOk
    check gotTooMany

    # ensure period of time has passed and the client can again use the service
    await sleepAsync(tokenPeriod + 100.millis)
    let recoveryRes =
      await client.publish(some(DefaultPubsubTopic), fakeWakuMessage(), serverPeerId)
    check recoveryRes.isOk()

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())
