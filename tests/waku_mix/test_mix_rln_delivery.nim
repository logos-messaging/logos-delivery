{.used.}

import
  chronos,
  results,
  stew/byteutils,
  testutils/unittests,
  libp2p_mix/[curve25519, spam_protection],
  mix_rln_spam_protection/spam_protection as mix_rln

import
  logos_delivery/api/events/kernel_events,
  logos_delivery/waku/[waku_core, waku_node],
  ../testlib/[wakucore, wakunode]

const
  TestShardCount = 8'u32
  PropagationTimeout = 10.seconds

proc newMixRlnNode(): Future[Result[WakuNode, string]] {.async.} =
  let node = newTestWakuNode(generateSecp256k1Key(), quicEnabled = false)
  await node.start()

  node.mountAutoSharding(DefaultClusterId, TestShardCount).isOkOr:
    await node.stop()
    return err("failed to mount autosharding: " & error)

  (await node.mountRelay()).isOkOr:
    await node.stop()
    return err("failed to mount relay: " & error)

  let mixRln = mix_rln.MixRlnSpamProtection.new(mix_rln.defaultConfig()).valueOr:
    await node.stop()
    return err("failed to create Mix-RLN: " & error)

  (await mixRln.init()).isOkOr:
    await node.stop()
    return err("failed to initialize Mix-RLN: " & error)

  let (mixPrivateKey, _) = generateKeyPair().valueOr:
    await node.stop()
    return err("failed to generate Mix key: " & error)

  node.wakuMixRln = mixRln
  (
    await node.mountMix(
      DefaultClusterId,
      mixPrivateKey,
      @[],
      spamProtection = Opt.some(SpamProtection(mixRln)),
    )
  ).isOkOr:
    await node.stop()
    return err("failed to mount Mix: " & error)

  await node.wakuMix.start()

  node.mountMixRlnCoordination().isOkOr:
    await node.stop()
    return err("failed to mount Mix-RLN coordination: " & error)

  (await mixRln.start()).isOkOr:
    await node.stop()
    return err("failed to start Mix-RLN: " & error)

  return ok(node)

proc waitForMemberCount(
    spamProtection: mix_rln.MixRlnSpamProtection, expected: int
): Future[bool] {.async.} =
  let deadline = Moment.now() + PropagationTimeout
  while Moment.now() < deadline:
    if spamProtection.getMemberCount() == expected:
      return true
    await sleepAsync(50.milliseconds)
  return false

suite "WakuNode - Mix-RLN Delivery integration":
  asyncTest "coordination and proofs use Delivery's existing switch":
    let node1Result = await newMixRlnNode()
    require node1Result.isOk()
    let node1 = node1Result.get()

    let node2Result = await newMixRlnNode()
    if node2Result.isErr():
      await node1.stop()
    require node2Result.isOk()
    let node2 = node2Result.get()

    var metadataListener = Opt.none(MessageSeenEventListener)
    try:
      check:
        node1.wakuMix.switch == node1.switch
        node2.wakuMix.switch == node2.switch

      await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
      await sleepAsync(2.seconds)

      let node1Registration = await node1.wakuMixRln.registerSelf()
      require node1Registration.isOk()
      check node1Registration.get() == 0
      require await waitForMemberCount(node2.wakuMixRln, 1)

      let node2Registration = await node2.wakuMixRln.registerSelf()
      require node2Registration.isOk()
      check node2Registration.get() == 1
      require await waitForMemberCount(node1.wakuMixRln, 2)
      check node2.wakuMixRln.getMemberCount() == 2

      let proofMetadataSeen = newFuture[void]("Mix-RLN proof metadata seen")
      let proofMetadataTopic = node1.wakuMixRln.getProofMetadataContentTopic()
      let handler = proc(
          event: MessageSeenEvent
      ): Future[void] {.async: (raises: []).} =
        if event.message.contentTopic == proofMetadataTopic and
            not proofMetadataSeen.finished():
          proofMetadataSeen.complete()

      metadataListener = Opt.some(
        MessageSeenEvent.listen(node1.brokerCtx, handler).expect(
          "proof metadata listener should register"
        )
      )

      let bindingData = "delivery-mix-rln-e2e".toBytes()
      let proofResult = node1.wakuMixRln.generateProof(bindingData)
      require proofResult.isOk()
      let proof = proofResult.get().proof

      let invalidResult =
        node2.wakuMixRln.verifyProof(proof, "different-binding".toBytes())
      require invalidResult.isOk()
      check invalidResult.get() == false

      let validResult = node2.wakuMixRln.verifyProof(proof, bindingData)
      require validResult.isOk()
      check validResult.get() == true

      require await proofMetadataSeen.withTimeout(PropagationTimeout)
      await sleepAsync(100.milliseconds)

      let duplicateResult = node1.wakuMixRln.verifyProof(proof, bindingData)
      require duplicateResult.isOk()
      check duplicateResult.get() == false
    finally:
      metadataListener.withValue(listener):
        await MessageSeenEvent.dropListener(node1.brokerCtx, listener)
      await allFutures(node1.stop(), node2.stop())
