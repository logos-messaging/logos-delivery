{.used.}

## The size limit of a mix send, against the real mix library.

import
  std/strutils,
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
  logos_delivery/waku/factory/waku_conf,
  logos_delivery/api/types,
  logos_delivery/api/events/messaging_client_events,
  logos_delivery/messaging/rate_limit_manager/rate_limit_manager,
  logos_delivery/messaging/delivery_service/send_service/
    [send_service, delivery_task, mix_processor],
  ../testlib/[futures, testasync, wakucore, wakumix, wakunodeconf]

proc senderConf(): WakuConf =
  var nodeConf = defaultTestWakuNodeConf()
  nodeConf.clusterId = Opt.some(DefaultClusterId)
  return nodeConf.toWakuConf().valueOr:
    raiseAssert error

proc newService(waku: Waku, level: AnonymityLevel): SendService =
  ## The loop runs one pass at start, then the tests drive the sends.
  let manager =
    RateLimitManager.new(DefaultRateLimitConfig).expect("RateLimitManager.new")
  let chain = setupSendProcessorChain(waku, level).expect("chain")
  let service = SendService
    .new(false, waku, manager, chain, level, serviceLoopInterval = chronos.hours(1))
    .expect("SendService.new")
  service.startSendService()
  return service

proc sizedTask(id: string, size: int): DeliveryTask =
  ## An admitted task whose lightpush request over mix has `size` bytes.
  const contentTopic = "/mix-size/1/probe/proto"
  for n in 0 .. size:
    let msg = fakeWakuMessage(payload = newSeq[byte](n), contentTopic = contentTopic)
    if mixLightpushSize(DefaultPubsubTopic, msg).size == size:
      return DeliveryTask(
        requestId: RequestId(id),
        pubsubTopic: DefaultPubsubTopic,
        msg: msg,
        msgHash: computeMessageHash(DefaultPubsubTopic, msg),
        state: DeliveryState.Entry,
        firstAdmittedTime: Opt.some(Moment.now()), # no budget and no proof
      )
  raiseAssert "no payload gives a request of " & $size & " bytes"

suite "Waku Mix - the size of a mix send":
  asyncTest "the largest message that fits goes over mix, and one more byte fails at once":
    let net = await startMixNodes()
    defer:
      await net.stop(@[])
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

    var errors: seq[string]
    let listener = MessageErrorEvent
      .listen(
        waku.brokerCtx,
        proc(event: MessageErrorEvent) {.async: (raises: []).} =
          errors.add(event.error),
      )
      .expect("listen")
    defer:
      await MessageErrorEvent.dropListener(waku.brokerCtx, listener)
    let service = newService(waku, AnonymityLevel.Required)
    defer:
      await service.stopSendService()
    let limit = mixLightpushSize(DefaultPubsubTopic, fakeWakuMessage()).limit

    let tooLarge = sizedTask("one-byte-too-many", limit + 1)
    check await service.send(tooLarge).withTimeout(FUTURE_TIMEOUT)
    check:
      tooLarge.state == DeliveryState.FailedToDeliver
      tooLarge.errorDesc.startsWith(MixTooLargeReason)
      tooLarge.tryCount == 0
    checkUntilTimeout:
      errors.len == 1
    check errors == @[tooLarge.errorDesc]

    let fits = sizedTask("largest-that-fits", limit)
    check await service.send(fits).withTimeout(FUTURE_TIMEOUT_LONG)
    check:
      fits.state == DeliveryState.SuccessfullyPropagated
      fits.propagatedAnonymously
      errors.len == 1
