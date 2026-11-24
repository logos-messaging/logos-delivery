{.used.}

import
  testutils/unittests,
  chronos,
  results,
  libp2p/[crypto/crypto, peerid],
  libp2p_mix/[curve25519, key_rotation, mix_protocol],
  mix_rln_spam_protection/module_api
import
  logos_delivery/waku/[
    waku_core,
    node/waku_node,
    node/waku_node/relay,
    waku_mix,
    waku_enr/capabilities,
    factory/waku_conf,
    discovery/peer_discovery_interface,
    discovery/self_advertisement,
  ],
  tools/confutils/cli_args,
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
    ## A started rotating node that advertises its record, with its mix key, on a
    ## recording backend.
    let node = await mixNode()
    let backend = FakeBackend.create("service", @["service"])
    backend.pauseNextAdvert = pauseFirstAdvert
    node.attachDiscovery(IPeerDiscovery(backend))
    let conf = defaultKernelConf().expect("kernel conf").toWakuConf().expect("conf")
    conf.wakuFlags = CapabilitiesBitfield.init(relay = true, mix = true)
    conf.mixConf = Opt.some(MixConf())
    let provided = GetSelfAdvert.provideIt(node.advertCtx):
      return ok(deliveryAdvertPart(conf, @[0'u16]))
    node.keepAdvertProvider(provided.expect("provides the delivery part"))
    # A node provides its mix key only when it relays for others.
    (await node.mountRelay()).isOkOr:
      raiseAssert "Failed to mount relay: " & $error
    await node.start()
    await node.startRecordAdvertising()
    return (node, backend)

  proc mixKeys(backend: FakeBackend): seq[seq[byte]] =
    ## The mix key of each record the backend was asked to advertise.
    var keys: seq[seq[byte]]
    for extraServices in backend.advertisedExtraServices:
      if extraServices.len == 1 and extraServices[0].id == MixProtocolID:
        keys.add(extraServices[0].data)
    return keys

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
      backend.mixKeys() == @[@first]

    node.rotate()
    let second = node.wakuMix.currentMixPubKey().expect("second mix key")
    checkUntilTimeout:
      backend.mixKeys() == @[@first, @second]
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

  asyncTest "a stopped node withdraws its record":
    ## Stopping destroys the mix key the record carries.
    let (node, backend) = await advertisingNode()
    checkUntilTimeout:
      backend.advertisedData.len == 1
    check backend.withdrawn.len == 0

    await node.stop()
    check backend.withdrawn == @[ServiceKeyPrefix & LogosDeliveryServiceId]

  asyncTest "a node that cannot act as a mix node advertises without its mix key":
    ## With Mix RLN, a node without a usable Mix membership cannot prove a hop.
    ## The mix part leaves the record, and comes back with the membership.
    let (node, backend) = await advertisingNode()
    defer:
      node.wakuMixRln = nil
      await node.stop()
    let key = node.wakuMix.currentMixPubKey().expect("mix key")
    checkUntilTimeout:
      backend.mixKeys() == @[@key]

    node.wakuMixRln = ModuleRlnProtection()
    node.mixAdvertChanged("test: the Mix membership ended")
    checkUntilTimeout:
      backend.advertisedExtraServices.len == 2
    check:
      backend.advertisedExtraServices[1].len == 0
      not advertisedCapabilities(backend.advertisedData[1])
        .expect("a delivery payload")
        .supportsCapability(Capabilities.Mix)

    node.mixMembershipUsable = true
    node.mixAdvertChanged("test: the Mix membership is usable")
    checkUntilTimeout:
      backend.mixKeys() == @[@key, @key]
    check backend.advertisedData[2] == backend.advertisedData[0]

  asyncTest "a record with a part that fails is not advertised":
    ## The advertised record stays; the node does not advertise half a record.
    let (node, backend) = await advertisingNode()
    defer:
      await node.stop()
    checkUntilTimeout:
      backend.advertisedData.len == 1

    let provided = GetSelfAdvert.provideIt(node.advertCtx):
      return err("this part cannot be read")
    node.keepAdvertProvider(provided.expect("provides the failing part"))
    node.rotate()
    # Nothing signals an advertisement that does not happen; one would start
    # within a few event-loop turns.
    await sleepAsync(chronos.milliseconds(100))
    check:
      backend.advertisedData.len == 1
      backend.withdrawn.len == 0

  asyncTest "a key replaced during a stuck advert is never published":
    ## The first advert waits inside `startAdvertising`. Two rotations replace its
    ## key twice: the middle key is never published, and the newest is last.
    let (node, backend) =
      await advertisingNode(Future[void].Raising([CancelledError]).init("first advert"))
    defer:
      await node.stop()
    let first = node.wakuMix.currentMixPubKey().expect("first mix key")
    checkUntilTimeout:
      backend.mixKeys() == @[@first]

    node.rotate()
    node.rotate(intervals = 2)
    let newest = node.wakuMix.currentMixPubKey().expect("newest mix key")
    checkUntilTimeout:
      backend.mixKeys() == @[@first, @newest]
    # Nothing signals an advertisement that does not happen; one would start
    # within a few event-loop turns.
    await sleepAsync(chronos.milliseconds(100))
    check backend.mixKeys() == @[@first, @newest]

  asyncTest "stopping the node ends a stuck advert":
    let pause = Future[void].Raising([CancelledError]).init("stuck advert")
    let (node, backend) = await advertisingNode(pause)
    checkUntilTimeout:
      backend.advertisedData.len == 1

    check await node.stop().withTimeout(chronos.seconds(5))
    check:
      pause.cancelled()
      backend.advertisedData.len == 1
