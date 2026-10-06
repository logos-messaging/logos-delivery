{.used.}

## A mix send whose reply is lost, through the send service.

import
  testutils/unittests,
  chronos,
  chronicles,
  results,
  brokers/broker_context,
  libp2p/[peerid, peerinfo, switch],
  libp2p_mix/curve25519
import
  logos_delivery/waku/[waku, waku_core, waku_node, waku_mix],
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/waku_node/lightpush,
  logos_delivery/waku/waku_lightpush/common,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/api/subscriptions,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/api/types,
  logos_delivery/api/events/kernel_events,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/[send_service, delivery_task],
  ../testlib/[futures, testasync, wakucore, wakumix, wakunodeconf]

proc senderConf(): WakuConf =
  var nodeConf = defaultTestWakuNodeConf()
  nodeConf.clusterId = Opt.some(DefaultClusterId)
  return nodeConf.toWakuConf().valueOr:
    raiseAssert error

proc newService(waku: Waku, level: AnonymityLevel): SendService =
  ## The loop runs one pass at start, then the tests drive the passes.
  let manager =
    RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
  let chain = setupSendProcessorChain(waku, level).expect("chain")
  let service = SendService
    .new(false, waku, manager, chain, level, serviceLoopInterval = chronos.hours(1))
    .expect("SendService.new")
  service.startSendService()
  return service

suite "Waku Mix - a send whose reply is lost":
  asyncTest "an exit that has the message refuses it, and the send completes":
    let hook = ExitHook.new()
    let net = await startMixNodes(hook)
    defer:
      await net.stop(@[])
    # The mix nodes also receive the message. Their events must not reach the
    # send service of the sender.
    var waku: Waku
    lockNewGlobalBrokerContext:
      waku = (await Waku.new(senderConf())).expect("Waku.new")
      let keys = generateKeyPair().expect("mix key pair")
      (
        await waku.node.mountMix(
          DefaultClusterId, keys.privateKey, net.infos, defaultAddressPolicy
        )
      ).isOkOr:
        raiseAssert "mountMix: " & $error
      (await waku.start()).expect("start")
    defer:
      discard await waku.stop()
    for node in net.nodes:
      await waku.node.switch.connect(node.peerInfo.peerId, node.peerInfo.addrs)
    waku.node.peerManager.addServicePeer(
      net.exit.peerInfo.toRemotePeerInfo(), WakuLightPushCodec
    )
    checkUntilTimeout:
      waku.mixReady()
      waku.selectMixLightpushPeer(DefaultPubsubTopic).isSome()

    let service = newService(waku, AnonymityLevel.Required)
    defer:
      await service.stopSendService()
    let msg =
      fakeWakuMessage(payload = "lost-reply", contentTopic = "/mix-seen/1/probe/proto")
    let task = DeliveryTask(
      requestId: RequestId("lost-reply"),
      pubsubTopic: DefaultPubsubTopic,
      msg: msg,
      msgHash: computeMessageHash(DefaultPubsubTopic, msg),
      state: DeliveryState.Entry,
      firstAdmittedTime: Opt.some(Moment.now()), # no budget and no proof
    )

    let started = Moment.now()
    let sending = service.send(task)
    check await hook.requested.wait().withTimeout(FUTURE_TIMEOUT)
    # An earlier exit published the message, so the exit has it. Its own
    # publish then fails, as on each retry after a lost reply.
    check (await net.nodes[1].publish(Opt.some(DefaultPubsubTopic), msg)).isOk()
    checkUntilTimeout:
      task.seenOnNetwork
    hook.reply.fire()
    check await sending.withTimeout(FUTURE_TIMEOUT)

    check:
      hook.publishResult.isSome()
      hook.publishResult.get().isErr()
      Moment.now() - started < MixReplyTimeout
      task.state == DeliveryState.SuccessfullyPropagated
      task.propagatedAnonymously
      not waku.isSubscribed(msg.contentTopic).valueOr(true) # the send placed no interest
    if hook.publishResult.isSome() and hook.publishResult.get().isErr():
      check hook.publishResult.get().error.code == LightPushErrorCode.NO_PEERS_TO_RELAY

  asyncTest "the own relay publish of a task in the FallbackRetry state does not count":
    ## A `Preferred` task after its mix attempts goes to the relay processor in
    ## the `FallbackRetry` state. Relay gives this node its own publish.
    var waku: Waku
    lockNewGlobalBrokerContext:
      waku = (await Waku.new(senderConf())).expect("Waku.new")
      (await waku.start()).expect("start")
    defer:
      discard await waku.stop()
    var ownEvents = 0
    let listener = MessageSeenEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessageSeenEvent) {.async: (raises: []).} =
          ownEvents.inc(),
      )
      .expect("listen")
    defer:
      await MessageSeenEvent.dropListener(waku.brokerCtx, listener)
    let service = newService(waku, AnonymityLevel.Preferred)
    defer:
      await service.stopSendService()
    let task = DeliveryTask
      .new(
        RequestId("plain-phase"),
        MessageEnvelope.init("/mix-seen/1/plain/proto", "plain-phase"),
        waku.brokerCtx,
      )
      .expect("DeliveryTask.new")
    task.anonymized = true # an earlier mix attempt
    task.firstAdmittedTime = Opt.some(Moment.now()) # no budget and no proof

    check await service.send(task).withTimeout(FUTURE_TIMEOUT)

    check:
      ownEvents == 1
      not task.seenOnNetwork
      task.state == DeliveryState.NextRoundRetry
