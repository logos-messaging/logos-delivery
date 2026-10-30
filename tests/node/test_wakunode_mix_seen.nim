{.used.}

## A mix send whose reply is lost, against the real mix library and relay.

import chronos, chronicles, testutils/unittests, results
import brokers/broker_context
import libp2p/[peerid, peerinfo, switch]
import libp2p_mix/curve25519
import
  logos_delivery/waku/[waku, waku_core, waku_node, waku_mix, waku_lightpush],
  logos_delivery/waku/node/peer_manager,
  logos_delivery/waku/node/subscription_manager,
  logos_delivery/waku/api/publish,
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/api/types,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/[send_service, delivery_task]
import ../testlib/[testasync, wakucore, wakunode, mix_size_network, wakunodeconf]

proc senderConf(): WakuConf =
  var nodeConf = defaultTestWakuNodeConf()
  nodeConf.clusterId = Opt.some(DefaultClusterId)
  return nodeConf.toWakuConf().valueOr:
    raiseAssert error

proc newService(waku: Waku, level: AnonymityLevel): SendService =
  let manager =
    RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
  let chain = setupSendProcessorChain(waku, level).expect("chain")
  let service = SendService
    .new(false, waku, manager, chain, level, retryInterval = chronos.hours(1))
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
          DefaultClusterId, keys.privateKey, net.infos, allowAllAddresses = true
        )
      ).isOkOr:
        raiseAssert "mountMix: " & $error
      (await waku.start()).expect("start")
    defer:
      discard await waku.stop()
    # The sender reads the shard, as an application that receives the topic does.
    waku.node.subscriptionManager.subscribeShard(DefaultPubsubTopic).expect("subscribe")
    for node in net.nodes:
      await waku.node.switch.connect(node.peerInfo.peerId, node.peerInfo.addrs)
    waku.node.peerManager.addServicePeer(
      net.exit.peerInfo.toRemotePeerInfo(), WakuLightPushCodec
    )
    checkUntilTimeout:
      waku.mixReady()
      waku.selectMixLightpushPeer(DefaultPubsubTopic).isSome()
      waku.node.hasMeshPeer(DefaultPubsubTopic, net.nodes[1].peerInfo.peerId)

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
    check service.enqueue(task).isOk()
    check await hook.requested.wait().withTimeout(chronos.seconds(10))
    # `net.nodes[1]` publishes the message, as the exit of an earlier attempt
    # does. So the exit has the message, and relay refuses its publish as a
    # duplicate, as on each retry after a lost reply.
    check (await net.nodes[1].publish(Opt.some(DefaultPubsubTopic), msg)).isOk()
    checkUntilTimeout:
      task.seenOnNetwork
      task.msgHash in hook.arrivals
    hook.reply.fire()

    checkUntilTimeout:
      task.state == DeliveryState.SuccessfullyPropagated
    check:
      task.propagatedAnonymously
      hook.publishResult.isSome()
      Moment.now() - started < chronos.seconds(10)
    if hook.publishResult.isSome():
      check:
        hook.publishResult.get().isErr()
        hook.publishResult.get().error.code == LightPushErrorCode.INVALID_MESSAGE
