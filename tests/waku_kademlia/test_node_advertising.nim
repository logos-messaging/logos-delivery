{.used.}

import std/[json, net, sequtils, sets, strutils, tables]
import testutils/unittests, chronos, results
import mix_rln_spam_protection/module_api
import libp2p/extended_peer_record
import libp2p/protocols/service_discovery/types as sd_types
import libp2p/protocols/kademlia/types
import libp2p_mix, libp2p_mix/curve25519
import
  logos_delivery/waku/waku_core,
  logos_delivery/waku/node/[waku_node, waku_node/relay],
  logos_delivery/waku/discovery/[
    waku_kademlia, service_discovery, self_advertisement, delivery_advert,
    peer_discovery_interface,
  ],
  logos_delivery/waku/[factory/waku_conf, waku_enr/capabilities],
  tools/confutils/cli_args,
  ../testlib/[wakucore, wakunode, testasync]

## The default deployment binds 0.0.0.0. switch.start resolves peerInfo.addrs
## before it starts ServiceDiscovery. The node advertises its services after.

proc isAdvertised(node: WakuNode, service: ServiceInfo): bool =
  let disco = node.wakuKademlia.protocol
  service in disco.services and
    disco.advertiser.providedAdverts.hasKey(service.id.hashServiceId())

proc publishedRecord(node: WakuNode): Opt[ExtendedPeerRecord] =
  ## The self record the protocol stored in its own table.
  let disco = node.wakuKademlia.protocol
  let entry = disco.dataTable.get(node.switch.peerInfo.peerId.toKey()).valueOr:
    return Opt.none(ExtendedPeerRecord)
  let record = SignedExtendedPeerRecord.decode(entry.value.toBytes()).valueOr:
    return Opt.none(ExtendedPeerRecord)
  Opt.some(record.data)

proc publishedServices(node: WakuNode): seq[ServiceInfo] =
  let record = node.publishedRecord().valueOr:
    return @[]
  record.services

proc publishedAddresses(node: WakuNode): seq[MultiAddress] =
  let record = node.publishedRecord().valueOr:
    return @[]
  record.addresses.mapIt(it.address)

proc advertisedAddresses(node: WakuNode, serviceId: string): seq[MultiAddress] =
  ## The addresses in the record this node signed and handed to libp2p for
  ## `serviceId`.
  let disco = node.wakuKademlia.protocol
  let advert = disco.advertiser.providedAdverts.getOrDefault(serviceId.hashServiceId())
  let record = SignedExtendedPeerRecord.decode(advert.bytes).valueOr:
    return @[]
  record.data.addresses.mapIt(it.address)

proc newAdvertisingNode(
    bindIp: IpAddress, service: ServiceInfo, extMultiAddrs: seq[MultiAddress] = @[]
): WakuNode =
  ## The helper rewrites 0.0.0.0 to loopback when quic is on, so quic is off.
  let node = newTestWakuNode(
    generateSecp256k1Key(),
    bindIp,
    Port(0),
    extMultiAddrs = extMultiAddrs,
    quicEnabled = false,
  )
  node.mountKademlia(
    KademliaDiscoveryConf(
      servicesToAdvertise: toHashSet([service]),
      randomLookupInterval: 10.seconds,
      serviceLookupInterval: 10.seconds,
      kadDhtConfig: KadDHTConfig.new(),
      discoConfig: sd_types.ServiceDiscoveryConfig.new(),
      xprPublishing: true,
    )
  ).isOkOr:
    raiseAssert error
  ## node.start and node.stop reach WakuKademlia through the attached backend.
  node.attachDiscovery(ServicePeerDiscovery.create(node.wakuKademlia))
  node

suite "Waku Kademlia node advertising":
  asyncTest "a configured service is advertised on a wildcard bind, and after a restart":
    let service = ServiceInfo(id: "/test/service/1.0.0", data: Opt.none(seq[byte]))
    let node = newAdvertisingNode(parseIpAddress("0.0.0.0"), service)

    await node.start()
    check node.isAdvertised(service)
    ## The record published before the service was added listed no services.
    checkUntilTimeout:
      service in node.publishedServices()
    ## peerInfo.addrs was resolved before the protocol started, so the record is dialable.
    check:
      node.publishedAddresses().len > 0
      node.publishedAddresses().allIt("0.0.0.0" notin $it and "/tcp/0" notin $it)
      node.publishedAddresses() == node.announcedAddresses
    await node.stop()
    check not node.isAdvertised(service)
    ## The stored record survives the stop. Delete it so the restart must publish anew.
    node.wakuKademlia.protocol.dataTable.del(node.switch.peerInfo.peerId.toKey())

    await node.start()
    check node.isAdvertised(service)
    checkUntilTimeout:
      service in node.publishedServices()
    await node.stop()

  asyncTest "a record the protocol cannot build leaves the node running and the service configured":
    ## 200 addresses push the record past its size cap. Through the constructor this
    ## trips an upstream assertion at start. Here it is a warning, on every start.
    let service = ServiceInfo(id: "/test/service/1.0.0", data: Opt.none(seq[byte]))
    let ext = (0 ..< 200).mapIt(
      MultiAddress
        .init("/ip4/10.0." & $(it div 250) & "." & $(it mod 250) & "/tcp/60000")
        .get()
    )
    let node = newAdvertisingNode(parseIpAddress("127.0.0.1"), service, ext)

    await node.start()
    check:
      node.started
      node.wakuKademlia.protocol.record().isErr()
      not node.isAdvertised(service)
    await node.stop()

    await node.start()
    check not node.isAdvertised(service)
    await node.stop()

  asyncTest "a concrete bind republishes the record once the service is added":
    ## The first record precedes the service, and a concrete bind changes no address.
    let service = ServiceInfo(id: "/test/service/1.0.0", data: Opt.none(seq[byte]))
    let node = newAdvertisingNode(parseIpAddress("127.0.0.1"), service)

    await node.start()
    check node.isAdvertised(service)
    checkUntilTimeout:
      service in node.publishedServices()
    await node.stop()

  asyncTest "an advert that cannot be signed still stops the one with other data":
    ## The record carries the node's addresses, so without any it cannot be signed.
    let service = ServiceInfo(id: "/test/service/1.0.0", data: Opt.none(seq[byte]))
    let node = newAdvertisingNode(parseIpAddress("127.0.0.1"), service)
    await node.start()
    let backend = node.discoveries[0]
    let key = ServiceKeyPrefix & "/test/other/1.0.0"
    let first = ServiceInfo(id: "/test/other/1.0.0", data: Opt.some(@[1'u8]))
    check:
      (await backend.startAdvertising(key, @[1'u8], @[])).isOk()
      node.isAdvertised(first)

    let addrs = node.switch.peerInfo.addrs
    node.switch.peerInfo.addrs = @[]
    let res = await backend.startAdvertising(key, @[2'u8], @[])
    node.switch.peerInfo.addrs = addrs
    check:
      res.isErr()
      not node.isAdvertised(first)
    await node.stop()

  asyncTest "a restarted node with mix key rotation does not advertise a destroyed key":
    ## Stopping destroys the mix key, and kademlia republishes its stored adverts
    ## at start, so the stop withdraws the record that carries the key.
    let service = ServiceInfo(id: "/test/service/1.0.0", data: Opt.none(seq[byte]))
    let node = newAdvertisingNode(parseIpAddress("127.0.0.1"), service)
    let mixKeys = generateKeyPair().expect("mix key pair")
    (
      await node.mountMix(
        DefaultClusterId,
        mixKeys.privateKey,
        @[],
        allowAllAddresses = true,
        keyRotation = true,
      )
    ).isOkOr:
      raiseAssert "Failed to mount mix: " & $error
    let conf = defaultKernelConf().expect("kernel conf").toWakuConf().expect("conf")
    conf.wakuFlags = CapabilitiesBitfield.init(relay = true, mix = true)
    conf.mixConf = Opt.some(MixConf())
    let shards = @[0'u16]
    let provided = GetSelfAdvert.provideIt(node.advertCtx):
      return ok(deliveryAdvertPart(conf, shards))
    node.keepAdvertProvider(provided.expect("provides the delivery part"))
    (await node.mountRelay()).isOkOr:
      raiseAssert "Failed to mount relay: " & $error
    await node.start()
    await node.startRecordAdvertising()
    let delivery = ServiceInfo(
      id: LogosDeliveryServiceId, data: Opt.some(selfAdvertisementData(conf, shards))
    )
    checkUntilTimeout:
      node.isAdvertised(delivery)

    await node.stop()
    await node.start()
    check not node.isAdvertised(delivery)
    await node.stop()

  asyncTest "the self record of a mix node claims mix but lists no mix key":
    ## The record libp2p publishes under the node's peer id, which a random
    ## lookup returns, lists the registered delivery service with its payload,
    ## not the `/mix/1.0.0` entry of the record the node signs for its advert.
    let service = ServiceInfo(id: "/test/service/1.0.0", data: Opt.none(seq[byte]))
    let node = newAdvertisingNode(parseIpAddress("127.0.0.1"), service)
    let mixKeys = generateKeyPair().expect("mix key pair")
    (
      await node.mountMix(
        DefaultClusterId,
        mixKeys.privateKey,
        @[],
        allowAllAddresses = true,
        keyRotation = true,
      )
    ).isOkOr:
      raiseAssert "Failed to mount mix: " & $error
    let conf = defaultKernelConf().expect("kernel conf").toWakuConf().expect("conf")
    conf.wakuFlags = CapabilitiesBitfield.init(relay = true, mix = true)
    conf.mixConf = Opt.some(MixConf())
    let shards = @[0'u16]
    let provided = GetSelfAdvert.provideIt(node.advertCtx):
      return ok(deliveryAdvertPart(conf, shards))
    node.keepAdvertProvider(provided.expect("provides the delivery part"))
    (await node.mountRelay()).isOkOr:
      raiseAssert "Failed to mount relay: " & $error
    await node.start()
    defer:
      await node.stop()
    await node.startRecordAdvertising()
    let delivery = ServiceInfo(
      id: LogosDeliveryServiceId, data: Opt.some(selfAdvertisementData(conf, shards))
    )
    checkUntilTimeout:
      node.isAdvertised(delivery)
    ## The advert the node signed lists its mix key.
    let advert = node.wakuKademlia.protocol.advertiser.providedAdverts.getOrDefault(
      LogosDeliveryServiceId.hashServiceId()
    )
    let signed = SignedExtendedPeerRecord.decode(advert.bytes).expect("signed advert")
    check signed.data.services.anyIt(it.id == MixProtocolID)

    ## An address change makes libp2p publish its self record again.
    node.switch.peerInfo.notifyObservers()
    checkUntilTimeout:
      delivery in node.publishedServices()
    check:
      advertisedMixKey(
        node.publishedServices().mapIt(
          DiscoveredService(id: it.id, data: it.data.get(@[]))
        )
      )
        .isNone()
      node.publishedServices().allIt(it.id != MixProtocolID)

  proc newHeldMixNode(): Future[WakuNode] {.async.} =
    ## A started mix node with Mix RLN and no usable membership yet.
    let service = ServiceInfo(id: "/test/service/1.0.0", data: Opt.none(seq[byte]))
    let node = newAdvertisingNode(parseIpAddress("127.0.0.1"), service)
    let mixKeys = generateKeyPair().expect("mix key pair")
    (
      await node.mountMix(
        DefaultClusterId, mixKeys.privateKey, @[], allowAllAddresses = true
      )
    ).isOkOr:
      raiseAssert "Failed to mount mix: " & $error
    node.wakuMixRln = ModuleRlnProtection
      .new(
        ModuleRlnConfig(
          registryId: "logos:local:mix",
          rlnIdentifierHex:
            "6d69782d726c6e2d7370616d2d70726f74656374696f6e2f7631000000000000",
          epochSeconds: 10,
          maxEpochGap: 3,
          metadataTopic: "/test/1/mix-rln-metadata/proto",
        ),
        proc(
            methodName: string, args: JsonNode
        ): Future[Result[JsonNode, string]] {.async: (raises: [CancelledError]).} =
          return err("no backend in this test"),
      )
      .expect("a valid Mix RLN config")
    let conf = defaultKernelConf().expect("kernel conf").toWakuConf().expect("conf")
    conf.wakuFlags = CapabilitiesBitfield.init(relay = true, mix = true)
    conf.mixConf = Opt.some(MixConf())
    let shards = @[0'u16]
    let provided = GetSelfAdvert.provideIt(node.advertCtx):
      return ok(deliveryAdvertPart(conf, shards))
    node.keepAdvertProvider(provided.expect("provides the delivery part"))
    (await node.mountRelay()).isOkOr:
      raiseAssert "Failed to mount relay: " & $error
    await node.start()
    return node

  proc advertListsMixKey(node: WakuNode): bool =
    let advert = node.wakuKademlia.protocol.advertiser.providedAdverts.getOrDefault(
      LogosDeliveryServiceId.hashServiceId()
    )
    let signed = SignedExtendedPeerRecord.decode(advert.bytes).valueOr:
      return false
    signed.data.services.anyIt(it.id == MixProtocolID)

  asyncTest "a mix node holds its first advert until its Mix RLN membership is usable":
    ## A registrar makes a second advert from the same address wait for up to
    ## the advert expiry, so the first one has to carry the mix key.
    let node = await newHeldMixNode()
    defer:
      await node.stop()
    await node.startRecordAdvertising()
    await sleepAsync(500.milliseconds)
    check not node.wakuKademlia.protocol.advertiser.providedAdverts.hasKey(
      LogosDeliveryServiceId.hashServiceId()
    )

    ## A change of another part of the record does not end the hold.
    node.switch.peerInfo.notifyObservers()
    await sleepAsync(500.milliseconds)
    check not node.wakuKademlia.protocol.advertiser.providedAdverts.hasKey(
      LogosDeliveryServiceId.hashServiceId()
    )

    node.mixMembershipUsable = true
    node.mixAdvertChanged("mix membership")
    checkUntilTimeout:
      node.advertListsMixKey()

  asyncTest "a mix node advertises without mix when no membership comes in time":
    let node = await newHeldMixNode()
    defer:
      await node.stop()
    await node.startRecordAdvertising(mixMembershipHold = 300.milliseconds)
    checkUntilTimeout:
      node.wakuKademlia.protocol.advertiser.providedAdverts.hasKey(
        LogosDeliveryServiceId.hashServiceId()
      )
    check not node.advertListsMixKey()

    ## The membership still makes it a mix node later.
    node.mixMembershipUsable = true
    node.mixAdvertChanged("mix membership")
    checkUntilTimeout:
      node.advertListsMixKey()

  asyncTest "a node advertises its record again when its addresses change":
    ## libp2p refreshes no record the node signed itself, so the node signs
    ## one with the new addresses.
    let service = ServiceInfo(id: "/test/service/1.0.0", data: Opt.none(seq[byte]))
    let node = newAdvertisingNode(parseIpAddress("127.0.0.1"), service)
    let conf = defaultKernelConf().expect("kernel conf").toWakuConf().expect("conf")
    let provided = GetSelfAdvert.provideIt(node.advertCtx):
      return ok(deliveryAdvertPart(conf, @[0'u16]))
    node.keepAdvertProvider(provided.expect("provides the delivery part"))
    await node.start()
    defer:
      await node.stop()
    await node.startRecordAdvertising()
    check:
      node.advertisedAddresses(LogosDeliveryServiceId).len > 0
      node.advertisedAddresses(LogosDeliveryServiceId) == node.announcedAddresses

    ## What PeerInfo.update does once the address mappers give other addresses.
    let moved = @[MultiAddress.init("/ip4/10.1.2.3/tcp/60123").get()]
    node.switch.peerInfo.addrs = moved
    node.switch.peerInfo.notifyObservers()
    check node.announcedAddresses == moved
    checkUntilTimeout:
      node.advertisedAddresses(LogosDeliveryServiceId) == moved

  asyncTest "a node collects only the parts of its own record":
    ## Every node of a thread shares `brokerCtx` unless a host sets another, so
    ## a part provided there, as by another node, must not reach this node's
    ## record. A record with two delivery parts is not advertised at all.
    let service = ServiceInfo(id: "/test/service/1.0.0", data: Opt.none(seq[byte]))
    let node = newAdvertisingNode(parseIpAddress("127.0.0.1"), service)
    let conf = defaultKernelConf().expect("kernel conf").toWakuConf().expect("conf")
    let foreign = GetSelfAdvert.provideIt(node.brokerCtx):
      return ok(deliveryAdvertPart(conf, @[7'u16]))
    defer:
      GetSelfAdvert.removeProvider(node.brokerCtx, foreign.expect("provides"))
    let provided = GetSelfAdvert.provideIt(node.advertCtx):
      return ok(deliveryAdvertPart(conf, @[0'u16]))
    node.keepAdvertProvider(provided.expect("provides the delivery part"))
    await node.start()
    defer:
      await node.stop()
    await node.startRecordAdvertising()
    check node.isAdvertised(
      ServiceInfo(
        id: LogosDeliveryServiceId,
        data: Opt.some(selfAdvertisementData(conf, @[0'u16])),
      )
    )
