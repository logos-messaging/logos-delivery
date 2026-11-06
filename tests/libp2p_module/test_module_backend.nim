{.used.}

## The module backends end to end: the relay and a request/response protocol run
## on `ModulePubSub`/`ModuleHost`, talking to a reference module (the module side
## of the contract, served by nim-libp2p) through CBOR requests and events.

import
  std/[sequtils, tables], results, testutils/unittests, chronos, chronicles, metrics
import libp2p/[switch, peerid, multiaddress]

import
  logos_delivery/waku/waku_core,
  logos_delivery/waku/waku_metadata,
  logos_delivery/waku/waku_relay/[protocol, pubsub_params],
  logos_delivery/waku/libp2p_iface/pubsub,
  logos_delivery/waku/libp2p_backend/[module_pubsub, module_host, module_transport],
  ../testlib/[wakucore, testasync],
  ./reference_module

type ModuleRelay = WakuRelayOf[ModulePubSub]

proc waitFor(
    cond: proc(): bool {.gcsafe, raises: [].}, timeout = 10.seconds
): Future[bool] {.async.} =
  let deadline = Moment.now() + timeout
  while Moment.now() < deadline:
    if cond():
      return true
    await sleepAsync(100.milliseconds)
  return false

suite "libp2p module backend":
  var
    switchA {.threadvar.}: Switch
    switchB {.threadvar.}: Switch
    moduleA {.threadvar.}: ReferenceModule
    moduleB {.threadvar.}: ReferenceModule

  asyncSetup:
    switchA = newTestSwitch()
    switchB = newTestSwitch()
    moduleA = ReferenceModule.new(switchA)
    moduleB = ReferenceModule.new(switchB)
    await allFutures(switchA.start(), switchB.start())

  asyncTeardown:
    await allFutures(switchA.stop(), switchB.stop())

  proc connectSwitches() {.async.} =
    # gossipsub only learns the peers that connect after it is mounted
    await switchA.connect(switchB.peerInfo.peerId, switchB.peerInfo.addrs)

  proc newRelay(m: ReferenceModule): ModuleRelay =
    let pubsub = ModulePubSub.new(
      m.transport, WakuRelayCodec, WakuPubSubParams, int(DefaultMaxWakuMessageSize)
    )
    return ModuleRelay.new(pubsub).tryGet()

  asyncTest "a relay on module pubsub delivers a published message to the peer":
    let relayA = newRelay(moduleA)
    let relayB = newRelay(moduleB)
    await allFutures(relayA.start(), relayB.start())
    await connectSwitches()

    var received: seq[WakuMessage]
    proc onMessage(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      received.add(msg)

    proc ignoreMessage(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      discard

    relayA.subscribe(DefaultPubsubTopic, ignoreMessage)
    relayB.subscribe(DefaultPubsubTopic, onMessage)

    check await waitFor(
      proc(): bool {.gcsafe, raises: [].} =
        relayA.getNumPeersInMesh(DefaultPubsubTopic).get(0) > 0
    )

    let msg = fakeWakuMessage(contentTopic = "/module/1/chat/proto")
    let published = await relayA.publish(DefaultPubsubTopic, msg)
    check:
      published.isOk()
      await waitFor(
        proc(): bool {.gcsafe, raises: [].} =
          received.len == 1
      )
      received[0].contentTopic == msg.contentTopic
      relayA.pubsub.selfPeerId() == $switchA.peerInfo.peerId

    await allFutures(relayA.stop(), relayB.stop())

  asyncTest "a waku validator on the receiving relay rejects through the verdict round trip":
    let relayA = newRelay(moduleA)
    let relayB = newRelay(moduleB)
    await allFutures(relayA.start(), relayB.start())
    await connectSwitches()

    var received = 0
    var validated = 0
    proc onMessage(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      inc received

    relayB.addValidator(
      proc(
          topic: PubsubTopic, msg: WakuMessage
      ): Future[pubsub.ValidationResult] {.async.} =
        inc validated
        return pubsub.ValidationResult.Reject,
      "always reject",
    )

    relayA.subscribe(DefaultPubsubTopic, onMessage)
    relayB.subscribe(DefaultPubsubTopic, onMessage)

    check await waitFor(
      proc(): bool {.gcsafe, raises: [].} =
        relayA.getNumPeersInMesh(DefaultPubsubTopic).get(0) > 0
    )

    discard await relayA.publish(DefaultPubsubTopic, fakeWakuMessage())

    check await waitFor(
      proc(): bool {.gcsafe, raises: [].} =
        validated > 0
    )
    await sleepAsync(500.milliseconds)
    # only A's own subscription (triggerSelf) got the message
    check received == 1

    await allFutures(relayA.stop(), relayB.stop())

  asyncTest "a protocol served on a module host answers a request over a module stream":
    let hostA = ModuleHost.new(moduleA.transport)
    let hostB = ModuleHost.new(moduleB.transport)
    await hostA.start()
    await hostB.start()
    await connectSwitches()

    let
      server = WakuMetadata.new(
        9,
        proc(): seq[uint16] {.gcsafe, raises: [].} =
          @[3'u16, 4'u16],
      )
      client = WakuMetadata.new(
        9,
        proc(): seq[uint16] {.gcsafe, raises: [].} =
          @[],
      )

    hostB.mountHandler(WakuMetadataCodec, server)
    await sleepAsync(200.milliseconds)

    let stream =
      await hostA.dial(hostB.peerId(), hostB.listenAddrs(), WakuMetadataCodec)
    let response = (await client.request(stream)).tryGet()

    check:
      hostA.peerId() == switchA.peerInfo.peerId
      stream.peerId == switchB.peerInfo.peerId
      response.clusterId == Opt.some(9'u32)
      response.shards == @[3'u32, 4'u32]
      await waitFor(
        proc(): bool {.gcsafe, raises: [].} =
          hostA.isConnected(switchB.peerInfo.peerId)
      )
