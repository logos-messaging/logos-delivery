{.used.}

import std/options, testutils/unittests, chronos, libp2p/crypto/crypto

import
  waku/[
    node/peer_manager,
    waku_core,
    waku_lightpush_legacy,
    waku_lightpush_legacy/client,
    waku_lightpush_legacy/common,
  ],
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
    ): Future[WakuLightPushResult[void]] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return ok()

    let
      tokenPeriod = 500.millis
      server = await newTestWakuLegacyLightpushNode(
        serverSwitch, handler, some((3, tokenPeriod))
      )
      client = newTestWakuLegacyLightpushClient(clientSwitch)

    let serverPeerId = serverSwitch.peerInfo.toRemotePeerInfo()

    let sendMsgProc = proc(): Future[void] {.async.} =
      let message = fakeWakuMessage()

      handlerFuture = newFuture[(string, WakuMessage)]()
      let requestRes =
        await client.publish(DefaultPubsubTopic, message, peer = serverPeerId)

      check await handlerFuture.withTimeout(50.millis)

      assert requestRes.isOk(), requestRes.error
      check handlerFuture.finished()

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
      firstWaitEXtend = 100.millis

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "push message with rate limit reject":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    let handler = proc(
        pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult[void]] {.async.} =
      return ok()

    let
      tokenPeriod = 500.millis
      server = await newTestWakuLegacyLightpushNode(
        serverSwitch, handler, some((3, tokenPeriod))
      )
      client = newTestWakuLegacyLightpushClient(clientSwitch)

    let serverPeerId = serverSwitch.peerInfo.toRemotePeerInfo()

    # Avoid assuming the exact Nth request will be rejected. With Chronos TokenBucket
    # minting semantics and real network latency, CI timing can allow refills.
    # Instead, send a short burst and require that we observe at least one rejection.
    let burstSize = 10
    var publishFutures: seq[Future[WakuLightPushResult[string]]] = @[]
    for _ in 0 ..< burstSize:
      publishFutures.add(
        client.publish(DefaultPubsubTopic, fakeWakuMessage(), peer = serverPeerId)
      )

    let finished = await allFinished(publishFutures)
    var gotOk = false
    var gotTooMany = false
    for fut in finished:
      check not fut.failed()
      let res = fut.read()
      if res.isOk():
        gotOk = true
      elif res.error == "TOO_MANY_REQUESTS":
        gotTooMany = true

    check:
      gotOk
      gotTooMany

    await sleepAsync(tokenPeriod + 100.millis)

    ## next one shall succeed due to the rate limit time window has passed
    let afterCooldownRes =
      await client.publish(DefaultPubsubTopic, fakeWakuMessage(), peer = serverPeerId)
    check:
      afterCooldownRes.isOk()

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())
