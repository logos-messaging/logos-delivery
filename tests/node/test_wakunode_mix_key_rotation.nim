{.used.}

import
  testutils/unittests,
  chronos,
  results,
  libp2p/[crypto/crypto, peerid],
  libp2p_mix/[curve25519, key_rotation]
import
  logos_delivery/waku/
    [waku_core, node/waku_node, waku_mix, discovery/peer_discovery_interface],
  ../testlib/[wakucore, wakunode, testasync, fake_discovery]

suite "Waku Mix - key rotation":
  ## With key rotation, mix generates this node's mix keys, and the keys of other
  ## mix nodes come from discovery only.

  proc mixNode(
      bootnodes: seq[MixNodePubInfo] = @[],
      keyRotation = true,
      mixPrivKey = generateKeyPair().expect("mix key pair").privateKey,
  ): Future[WakuNode] {.async.} =
    let node = newTestWakuNode(generateSecp256k1Key())
    (
      await node.mountMix(
        DefaultClusterId,
        mixPrivKey,
        bootnodes,
        allowAllAddresses = true,
        keyRotation = keyRotation,
      )
    ).isOkOr:
      raiseAssert "Failed to mount mix: " & $error
    return node

  proc advertisingNode(
      pauseFirstAdvert: Future[void].Raising([CancelledError]) = nil
  ): Future[(WakuNode, FakeBackend)] {.async.} =
    ## A started rotating node that advertises its mix key on a recording backend.
    let node = await mixNode()
    let backend = FakeBackend.create("service", @["service"])
    backend.pauseNextAdvert = pauseFirstAdvert
    node.attachDiscovery(IPeerDiscovery(backend))
    await node.start()
    await node.startMixAdvertising()
    return (node, backend)

  proc rotate(node: WakuNode, intervals = 1) =
    ## Runs the ring's update as if `intervals` rotation intervals had passed.
    let ring = node.wakuMix.keyRing().get()
    ring.update(Moment.now() + ring.config.rotationInterval * intervals)

  asyncTest "the node holds no mix key before start, and a key of its own after":
    let mixKeys = generateKeyPair().expect("mix key pair")
    let node = await mixNode(mixPrivKey = mixKeys.privateKey)
    check node.wakuMix.currentMixPubKey().isNone()

    await node.start()
    defer:
      await node.stop()
    let key = node.wakuMix.currentMixPubKey()
    check:
      key.isSome()
      key.get() != mixKeys.publicKey

  asyncTest "after a rotation the node reports its new mix key":
    let node = await mixNode()
    await node.start()
    defer:
      await node.stop()
    let first = node.wakuMix.currentMixPubKey().expect("first mix key")

    node.rotate()
    let second = node.wakuMix.currentMixPubKey().expect("second mix key")
    check:
      second != first
      node.mixPubKeyHex() == Opt.some(second.to0xHex())
      node.info().mixPubKey == Opt.some(second.to0xHex())

  asyncTest "configured mix nodes stay out of the pool":
    var bootnodes: seq[MixNodePubInfo]
    for port in [60701, 60702]:
      let peerId = PeerId.init(generateSecp256k1Key()).tryGet()
      bootnodes.add(
        MixNodePubInfo(
          multiAddr: "/ip4/127.0.0.1/tcp/" & $port & "/p2p/" & $peerId,
          pubKey: generateKeyPair().expect("mix key pair").publicKey,
        )
      )
    let plain = await mixNode(bootnodes, keyRotation = false)
    let rotating = await mixNode(bootnodes)
    check:
      plain.getMixNodePoolSize() == 2
      rotating.getMixNodePoolSize() == 0

  asyncTest "each new mix key is advertised after the previous one":
    let (node, backend) = await advertisingNode()
    defer:
      await node.stop()
    let first = node.wakuMix.currentMixPubKey().expect("first mix key")
    checkUntilTimeout:
      backend.advertisedData == @[@first]

    node.rotate()
    let second = node.wakuMix.currentMixPubKey().expect("second mix key")
    checkUntilTimeout:
      backend.advertisedData == @[@first, @second]
    check second != first

  asyncTest "a stopped node advertises no new mix key":
    let (node, backend) = await advertisingNode()
    checkUntilTimeout:
      backend.advertisedData.len == 1

    await node.stop()
    node.rotate()
    # Nothing signals an advertisement that does not happen; one would start
    # within the update and finish in a few event-loop turns.
    await sleepAsync(chronos.milliseconds(100))
    check backend.advertisedData.len == 1

  asyncTest "a key replaced during a stuck advert is never published":
    ## The first advert waits inside `startAdvertising`. Two rotations replace its
    ## key twice: the middle key is never published, and the newest is last.
    let (node, backend) =
      await advertisingNode(Future[void].Raising([CancelledError]).init("first advert"))
    defer:
      await node.stop()
    let first = node.wakuMix.currentMixPubKey().expect("first mix key")
    checkUntilTimeout:
      backend.advertisedData == @[@first]

    node.rotate()
    node.rotate(intervals = 2)
    let newest = node.wakuMix.currentMixPubKey().expect("newest mix key")
    checkUntilTimeout:
      backend.advertisedData == @[@first, @newest]
    # Nothing signals an advertisement that does not happen; one would start
    # within a few event-loop turns.
    await sleepAsync(chronos.milliseconds(100))
    check backend.advertisedData == @[@first, @newest]

  asyncTest "stopping the node ends a stuck advert":
    let pause = Future[void].Raising([CancelledError]).init("stuck advert")
    let (node, backend) = await advertisingNode(pause)
    checkUntilTimeout:
      backend.advertisedData.len == 1

    check await node.stop().withTimeout(chronos.seconds(5))
    check:
      pause.cancelled()
      backend.advertisedData.len == 1
