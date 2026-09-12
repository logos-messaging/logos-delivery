{.used.}

import std/[net, sequtils, sets, strutils, tables]
import testutils/unittests, chronos, results
import libp2p/extended_peer_record
import libp2p/protocols/service_discovery/types as sd_types
import libp2p/protocols/kademlia/types
import
  logos_delivery/waku/node/waku_node,
  logos_delivery/waku/discovery/waku_kademlia,
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
