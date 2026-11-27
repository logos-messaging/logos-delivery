{.used.}

import
  std/[base64, strutils],
  results,
  chronos,
  testutils/unittests,
  libp2p/crypto/crypto as libp2p_keys,
  libp2p/crypto/curve25519,
  libp2p/[peerid, multiaddress, switch, extended_peer_record],
  libp2p/extended_peer_record,
  libp2p/protocols/service_discovery/types as sd_types,
  libp2p_mix/mix_protocol

import
  logos_delivery/waku/discovery/waku_kademlia,
  logos_delivery/waku/discovery/delivery_advert,
  logos_delivery/waku/discovery/peer_discovery_interface,
  logos_delivery/waku/waku_enr/capabilities,
  logos_delivery/waku/discovery/signed_service_record,
  logos_delivery/waku/waku_core/peers,
  logos_delivery/waku/waku_core/codecs,
  logos_delivery/waku/node/peer_manager/waku_peer_store
import ../testlib/[wakucore, futures]
import ./utils as kad_utils

suite "Waku Kademlia service discovery":
  asyncTest "seed node starts with no bootstrap nodes":
    let
      switch = newTestSwitch()
      wk = kad_utils.newTestKademlia(
        switch,
        servicesToAdvertise =
          @[ServiceInfo(id: "/seed/svc/1.0.0", data: Opt.some(newSeq[byte]()))],
      )
    await switch.start()
    await wk.start()

    await sleepAsync(FUTURE_TIMEOUT)

    check:
      not wk.protocol.isNil()

    await wk.stop()
    await switch.stop()

  proc deliveryPayload(caps: CapabilitiesBitfield): seq[byte] =
    ## A `/logos/delivery` payload of cluster 0 with no shards.
    cast[seq[byte]](base64.encode(@[AdvertFormatVersion, 0'u8, 0'u8, byte(caps)]))

  const MixNodeCaps = CapabilitiesBitfield.init(relay = true, mix = true)

  suite "advertisedMixKey":
    proc validKeyBytes(): seq[byte] =
      var b = newSeq[byte](Curve25519KeySize)
      for i in 0 ..< Curve25519KeySize:
        b[i] = byte(i)
      b

    proc services(
        caps: CapabilitiesBitfield, mixId: string, key: seq[byte]
    ): seq[DiscoveredService] =
      @[
        DiscoveredService(id: LogosDeliveryServiceId, data: deliveryPayload(caps)),
        DiscoveredService(id: mixId, data: key),
      ]

    test "a delivery record claiming relay and mix gives its key":
      let bytes = validKeyBytes()
      let res = advertisedMixKey(services(MixNodeCaps, MixProtocolID, bytes))
      require:
        res.isSome()
      check:
        res.get().getBytes() == intoCurve25519Key(bytes).getBytes()

    test "a mix key with no delivery service gives none":
      check advertisedMixKey(
        @[DiscoveredService(id: MixProtocolID, data: validKeyBytes())]
      )
        .isNone()

    test "a delivery record that does not claim mix gives none":
      let caps = CapabilitiesBitfield.init(relay = true)
      check advertisedMixKey(services(caps, MixProtocolID, validKeyBytes())).isNone()

    test "a delivery record that claims mix without relay gives none":
      let caps = CapabilitiesBitfield.init(filter = true, mix = true)
      check advertisedMixKey(services(caps, MixProtocolID, validKeyBytes())).isNone()

    test "a delivery payload of another format version gives none":
      let payload = cast[seq[byte]](base64.encode(
        @[AdvertFormatVersion + 1, 0'u8, 0'u8, byte(MixNodeCaps)]
      ))
      check advertisedMixKey(
        @[
          DiscoveredService(id: LogosDeliveryServiceId, data: payload),
          DiscoveredService(id: MixProtocolID, data: validKeyBytes()),
        ]
      )
        .isNone()

    test "a delivery payload that is not base64 gives none":
      check advertisedMixKey(
        @[
          DiscoveredService(id: LogosDeliveryServiceId, data: @[0xff'u8, 0x00, 0x01]),
          DiscoveredService(id: MixProtocolID, data: validKeyBytes()),
        ]
      )
        .isNone()

    test "a key of the wrong length gives none":
      check advertisedMixKey(services(MixNodeCaps, MixProtocolID, @[0u8, 1u8, 2u8]))
        .isNone()

    test "a key under another service id gives none":
      check advertisedMixKey(services(MixNodeCaps, "/foo/1.0.0", validKeyBytes()))
        .isNone()

  suite "disclaimsMix":
    proc delivery(caps: CapabilitiesBitfield): DiscoveredService =
      DiscoveredService(id: LogosDeliveryServiceId, data: deliveryPayload(caps))

    proc mixKey(): DiscoveredService =
      DiscoveredService(id: MixProtocolID, data: newSeq[byte](Curve25519KeySize))

    test "a delivery record that claims no mix disclaims":
      check disclaimsMix(@[delivery(CapabilitiesBitfield.init(relay = true))])

    test "a delivery record that claims mix without relay disclaims":
      check disclaimsMix(
        @[delivery(CapabilitiesBitfield.init(filter = true, mix = true))]
      )

    test "a delivery record claiming relay and mix with its key does not":
      check not disclaimsMix(@[delivery(MixNodeCaps), mixKey()])

    test "a delivery record claiming relay and mix without a key does not":
      ## libp2p's own record of a mix node, as a random lookup returns it.
      check not disclaimsMix(@[delivery(MixNodeCaps)])

    test "a record with no delivery service does not":
      check:
        not disclaimsMix(@[])
        not disclaimsMix(@[DiscoveredService(id: "/other/1.0.0", data: @[1'u8])])

    test "a delivery payload it cannot read does not":
      check:
        not disclaimsMix(
          @[DiscoveredService(id: LogosDeliveryServiceId, data: @[0xff'u8, 0x00])]
        )
        not disclaimsMix(
          @[
            DiscoveredService(
              id: LogosDeliveryServiceId,
              data: cast[seq[byte]](base64.encode(
                @[AdvertFormatVersion + 1, 0'u8, 0'u8, 0'u8]
              )),
            )
          ]
        )

  suite "remotePeerInfoFrom":
    proc randomPeerId(): PeerId =
      PeerId.init(generateSecp256k1Key()).tryGet()

    proc testAddr(port: uint16): MultiAddress =
      MultiAddress.init("/ip4/127.0.0.1/tcp/" & $port).tryGet()

    proc mixService(data: seq[byte]): ServiceInfo =
      ServiceInfo(id: MixProtocolID, data: Opt.some(data))

    proc deliveryService(): ServiceInfo =
      ## What makes a record's mix key count: the delivery payload of a mix node.
      ServiceInfo(
        id: LogosDeliveryServiceId, data: Opt.some(deliveryPayload(MixNodeCaps))
      )

    proc validMixService(): ServiceInfo =
      var b = newSeq[byte](Curve25519KeySize)
      for i in 0 ..< Curve25519KeySize:
        b[i] = byte(i)
      mixService(b)

    test "empty addresses returns none":
      let record = buildExtendedPeerRecord(randomPeerId(), @[])
      check:
        remotePeerInfoFrom(record, 0).isNone()

    test "origin set to PeerOrigin.Kademlia":
      let
        pid = randomPeerId()
        record = buildExtendedPeerRecord(pid, @[testAddr(61600)])
        res = remotePeerInfoFrom(record, 0)
      require:
        res.isSome()
      let peerInfo = res.get()
      check:
        peerInfo.origin == PeerOrigin.Kademlia
        peerInfo.peerId == pid

    test "mixPubKey extracted from first mix service":
      let
        pid = randomPeerId()
        svc = validMixService()
        record =
          buildExtendedPeerRecord(pid, @[testAddr(61600)], @[deliveryService(), svc])
        res = remotePeerInfoFrom(record, 0)
      require:
        res.isSome()
      let peerInfo = res.get()
      check:
        peerInfo.mixPubKey.isSome()
        peerInfo.mixPubKey.get().getBytes() == svc.data.get(@[])

    test "mixPubKey stays none for a mix service outside a delivery record":
      let
        pid = randomPeerId()
        record = buildExtendedPeerRecord(pid, @[testAddr(61600)], @[validMixService()])
        res = remotePeerInfoFrom(record, 0)
      require:
        res.isSome()
      check:
        res.get().mixPubKey.isNone()

    test "mixPubKey stays none when no mix service present":
      let
        pid = randomPeerId()
        svc = ServiceInfo(id: "/other/1.0.0", data: Opt.some(@[1u8]))
        record = buildExtendedPeerRecord(pid, @[testAddr(61600)], @[svc])
        res = remotePeerInfoFrom(record, 0)
      require:
        res.isSome()
      check:
        res.get().mixPubKey.isNone()

    test "addresses mapped correctly":
      let
        pid = randomPeerId()
        addrs = @[testAddr(61600), testAddr(61601), testAddr(61602)]
        record = buildExtendedPeerRecord(pid, addrs)
        res = remotePeerInfoFrom(record, 0)
      require:
        res.isSome()
      let peerInfo = res.get()
      check:
        peerInfo.addrs.len == 3
        peerInfo.addrs == addrs

    test "multiple mix services, first one wins":
      let
        pid = randomPeerId()
        firstBytes = block:
          var b = newSeq[byte](Curve25519KeySize)
          for i in 0 ..< Curve25519KeySize:
            b[i] = byte(i)
          b
        secondBytes = block:
          var b = newSeq[byte](Curve25519KeySize)
          for i in 0 ..< Curve25519KeySize:
            b[i] = byte(i + 100)
          b
        record = buildExtendedPeerRecord(
          pid,
          @[testAddr(61600)],
          @[deliveryService(), mixService(firstBytes), mixService(secondBytes)],
        )
        res = remotePeerInfoFrom(record, 0)
      require:
        res.isSome()
      check:
        res.get().mixPubKey.get().getBytes() == firstBytes

    test "mix service with bad key length is skipped silently":
      let
        pid = randomPeerId()
        badSvc = mixService(@[0u8, 1u8, 2u8])
        record =
          buildExtendedPeerRecord(pid, @[testAddr(61600)], @[deliveryService(), badSvc])
        res = remotePeerInfoFrom(record, 0)
      require:
        res.isSome()
      let peerInfo = res.get()
      check:
        peerInfo.peerId == pid
        peerInfo.mixPubKey.isNone()

    proc storedMixKey(peerStore: PeerStore, pid: PeerId): Opt[Curve25519Key] =
      if pid in peerStore[MixPubKeyBook]:
        Opt.some(peerStore[MixPubKeyBook][pid])
      else:
        Opt.none(Curve25519Key)

    proc mixNodeRecord(pid: PeerId): ExtendedPeerRecord =
      buildExtendedPeerRecord(
        pid, @[testAddr(61600)], @[deliveryService(), validMixService()]
      )

    proc kademliaWithMixPeer(pid: PeerId): WakuKademlia =
      ## A backend whose peer store holds `pid` as a mix node, learned from
      ## its delivery record.
      let wk = kad_utils.newTestKademlia(newTestSwitch())
      discard wk.processRecords(@[mixNodeRecord(pid)], "test")
      doAssert wk.protocol.switch.peerStore.storedMixKey(pid).isSome()
      wk

    test "a delivery record that claims no mix removes the stored key":
      ## The peer lost its Mix RLN membership and advertises as a delivery node.
      let
        pid = randomPeerId()
        wk = kademliaWithMixPeer(pid)
        plain = ServiceInfo(
          id: LogosDeliveryServiceId,
          data: Opt.some(deliveryPayload(CapabilitiesBitfield.init(relay = true))),
        )
      discard wk.processRecords(
        @[buildExtendedPeerRecord(pid, @[testAddr(61600)], @[plain])], "test"
      )
      check wk.protocol.switch.peerStore.storedMixKey(pid).isNone()

    test "a delivery record that claims mix without a key keeps the stored key":
      ## libp2p's own record of a mix node, which a random lookup returns: it
      ## lists the delivery service but not the `/mix/1.0.0` entry.
      let
        pid = randomPeerId()
        wk = kademliaWithMixPeer(pid)
      discard wk.processRecords(
        @[buildExtendedPeerRecord(pid, @[testAddr(61600)], @[deliveryService()])],
        "test",
      )
      check wk.protocol.switch.peerStore.storedMixKey(pid).isSome()

    test "a record with no delivery service keeps the stored key":
      let
        pid = randomPeerId()
        wk = kademliaWithMixPeer(pid)
      discard
        wk.processRecords(@[buildExtendedPeerRecord(pid, @[testAddr(61600)])], "test")
      check wk.protocol.switch.peerStore.storedMixKey(pid).isSome()

    test "a peer learned another way keeps the stored key":
      let
        peerStore = PeerStore.new(nil, capacity = 50)
        pid = randomPeerId()
      peerStore.addPeer(remotePeerInfoFrom(mixNodeRecord(pid), 0).get())

      peerStore.addPeer(
        RemotePeerInfo.init(
          pid, @[testAddr(61600)], protocols = @[LogosDeliveryServiceId]
        ),
        origin = PeerOrigin.Discv5,
      )
      check peerStore.storedMixKey(pid).isSome()

  suite "lookupServicePeers":
    asyncTest "returns err when protocol is nil":
      let
        switch = newTestSwitch()
        wk = kad_utils.newTestKademlia(switch)
      wk.protocol = nil
      let res = await wk.lookupServicePeers("/some/service/1.0.0")
      check:
        res.isErr()
        res.error.contains("service discovery not mounted")

    asyncTest "returns ok with empty seq when no advertisements":
      let
        switch = newTestSwitch()
        wk = kad_utils.newTestKademlia(switch)
      await switch.start()
      await wk.start()

      let res = await wk.lookupServicePeers("/nonexistent/service/1.0.0")
      check:
        res.isOk()
        res.value.len == 0

      await wk.stop()
      await switch.stop()

suite "Waku Kademlia advertises records this node signs":
  asyncTest "a mix node is found under the delivery service, with its mix key":
    ## The in-process host does not leave the record to libp2p: it signs it,
    ## the same as the plugin host. A mix node registers the delivery service
    ## alone and lists its mix key in that record, so a lookup for the delivery
    ## service returns this node's identity and its key.
    ##
    ## Three nodes: a registrar R, the advertiser A and a looker B. A's advert
    ## has to reach R and B has to ask R. Registrations are scheduled when a
    ## service is added, towards the peers already in that service's table, so
    ## A adds its service only once it knows R.
    let disco = ServiceDiscoveryConfig.new()
    let switchR = newTestSwitch()
    let wkR = kad_utils.newTestKademlia(switchR, discoConfig = disco)
    await switchR.start()
    await wkR.start()
    let bootstrap = @[(switchR.peerInfo.peerId, switchR.peerInfo.addrs)]

    let switchA = newTestSwitch()
    let wkA = kad_utils.newTestKademlia(
      switchA, bootstrapNodes = bootstrap, discoConfig = disco
    )
    await switchA.start()
    await wkA.start()
    let switchB = newTestSwitch()
    let wkB = kad_utils.newTestKademlia(
      switchB, bootstrapNodes = bootstrap, discoConfig = disco
    )
    await switchB.start()
    await wkB.start()
    await sleepAsync(1.seconds) # A's service tables must hold R first

    let infoA = switchA.peerInfo
    var mixKey = newSeq[byte](Curve25519KeySize)
    for i in 0 ..< mixKey.len:
      mixKey[i] = byte(i)
    let payload = cast[seq[byte]](base64.encode(
      @[
        AdvertFormatVersion,
        0'u8,
        0'u8,
        byte(CapabilitiesBitfield.init(relay = true, mix = true)),
      ]
    ))
    wkA
      .addServiceToAdvertise(
        ServiceInfo(id: LogosDeliveryServiceId, data: Opt.some(payload)),
        signedServiceRecord(
          infoA,
          infoA.privateKey,
          LogosDeliveryServiceId,
          payload,
          @[DiscoveredService(id: MixProtocolID, data: mixKey)],
        )
          .expect("signs"),
      )
      .expect("libp2p takes the record")

    var delivery: seq[RemotePeerInfo]
    for _ in 0 ..< 30:
      await sleepAsync(500.milliseconds)
      let res = await wkB.lookupServicePeers(LogosDeliveryServiceId)
      if res.isOk() and res.get().len > 0:
        delivery = res.get()
        break
    require delivery.len == 1
    check:
      delivery[0].peerId == infoA.peerId
      delivery[0].protocols == @[LogosDeliveryServiceId, MixProtocolID, WakuRelayCodec]
      delivery[0].mixPubKey == Opt.some(intoCurve25519Key(mixKey))

    ## Mix is not a service of its own: nothing is filed under it.
    check (await wkB.lookupServicePeers(MixProtocolID)).expect("lookup").len == 0

    await wkB.stop()
    await wkA.stop()
    await wkR.stop()
    await switchB.stop()
    await switchA.stop()
    await switchR.stop()

  asyncTest "a record advertised again takes the place of the old one":
    ## A node that becomes ready to mix after it advertised itself advertises
    ## again, now with its mix key. Same three nodes as above.
    ##
    ## A registrar does not know that a registration replaces the same peer's
    ## ad: it makes it wait as it would a second node at that address. The
    ## address term is off here, so the test checks the replacement and does not
    ## sit out that wait.
    var disco = ServiceDiscoveryConfig.new()
    disco.ipSimCoefficient = 0
    let switchR = newTestSwitch()
    let wkR = kad_utils.newTestKademlia(switchR, discoConfig = disco)
    await switchR.start()
    await wkR.start()
    let bootstrap = @[(switchR.peerInfo.peerId, switchR.peerInfo.addrs)]

    let switchA = newTestSwitch()
    let wkA = kad_utils.newTestKademlia(
      switchA, bootstrapNodes = bootstrap, discoConfig = disco
    )
    await switchA.start()
    await wkA.start()
    let switchB = newTestSwitch()
    let wkB = kad_utils.newTestKademlia(
      switchB, bootstrapNodes = bootstrap, discoConfig = disco
    )
    await switchB.start()
    await wkB.start()
    await sleepAsync(1.seconds) # A's service tables must hold R first

    let infoA = switchA.peerInfo
    var mixKey = newSeq[byte](Curve25519KeySize)
    for i in 0 ..< mixKey.len:
      mixKey[i] = byte(i)

    proc advertise(mix: bool, key = mixKey) {.async.} =
      let payload = cast[seq[byte]](base64.encode(
        @[
          AdvertFormatVersion,
          0'u8,
          0'u8,
          byte(CapabilitiesBitfield.init(relay = true, mix = mix)),
        ]
      ))
      let extraServices =
        if mix:
          @[DiscoveredService(id: MixProtocolID, data: key)]
        else:
          @[]
      wkA
        .addServiceToAdvertise(
          ServiceInfo(id: LogosDeliveryServiceId, data: Opt.some(payload)),
          signedServiceRecord(
            infoA, infoA.privateKey, LogosDeliveryServiceId, payload, extraServices
          )
            .expect("signs"),
        )
        .expect("libp2p takes the record")

    proc foundMixKey(): Future[Opt[Opt[Curve25519Key]]] {.async.} =
      ## The mix key B finds for A; the outer `none` when B does not find A.
      let res = await wkB.lookupServicePeers(LogosDeliveryServiceId)
      if res.isOk() and res.get().len > 0:
        return Opt.some(res.get()[0].mixPubKey)
      return Opt.none(Opt[Curve25519Key])

    await advertise(mix = false)
    var found = Opt.none(Opt[Curve25519Key])
    for _ in 0 ..< 30:
      await sleepAsync(500.milliseconds)
      found = await foundMixKey()
      if found.isSome():
        break
    require found.isSome()
    check found.get().isNone()

    await advertise(mix = true)
    for _ in 0 ..< 60:
      await sleepAsync(500.milliseconds)
      found = await foundMixKey()
      if found.isSome() and found.get().isSome():
        break
    check found == Opt.some(Opt.some(intoCurve25519Key(mixKey)))

    ## A rotated mix key changes the record and leaves the delivery payload as
    ## it is, so the service that libp2p holds is the same one.
    var rotatedKey = mixKey
    rotatedKey[0] = 0xff'u8
    await advertise(mix = true, key = rotatedKey)
    for _ in 0 ..< 60:
      await sleepAsync(500.milliseconds)
      found = await foundMixKey()
      if found == Opt.some(Opt.some(intoCurve25519Key(rotatedKey))):
        break
    check found == Opt.some(Opt.some(intoCurve25519Key(rotatedKey)))

    ## A record libp2p refuses is reported, and the advertised one stays.
    let tooLarge = newSeq[byte](MaxServiceDataSize + 1)
    check wkA
      .addServiceToAdvertise(
        ServiceInfo(id: LogosDeliveryServiceId, data: Opt.some(tooLarge)), @[]
      )
      .isErr()
    await sleepAsync(2.seconds)
    check (await foundMixKey()) == Opt.some(Opt.some(intoCurve25519Key(rotatedKey)))

    await wkB.stop()
    await wkA.stop()
    await wkR.stop()
    await switchB.stop()
    await switchA.stop()
    await switchR.stop()
