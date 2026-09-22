{.used.}

## The ENR carries the bound ports, and a host only when one is known from
## outside the node.

import results
import std/[net, sequtils, strutils]
import testutils/unittests, chronos
import libp2p/[multiaddress, wire]
import libp2p/crypto/crypto as libp2pcrypto
import eth/keys, eth/p2p/discoveryv5/enr
import eth/p2p/discoveryv5/node as discv5_node
import eth/p2p/discoveryv5/protocol as discv5_protocol
import stew/byteutils
import
  ../logos_delivery/waku/discovery/waku_discv5,
  ../logos_delivery/waku/net/net_config,
  ../logos_delivery/waku/node/enr_addresses,
  ../logos_delivery/waku/node/waku_node,
  ../logos_delivery/waku/waku,
  ../logos_delivery/waku/waku_enr,
  ../logos_delivery/waku/waku_core/peers
import ./testlib/[common, wakucore, wakunode]

proc tcpOf(record: enr.Record): Opt[uint16] =
  record.toTyped().expect("typed").tcp()

proc udpOf(record: enr.Record): Opt[uint16] =
  record.toTyped().expect("typed").udp()

proc ipOf(record: enr.Record): Opt[array[4, byte]] =
  record.toTyped().expect("typed").ip()

proc multiaddrsOf(record: enr.Record): seq[MultiAddress] =
  record.toTyped().expect("typed").multiaddrs().expect("multiaddrs field")

suite "ENR endpoints":
  test "a wildcard bind host and port 0 are left out before start":
    let node = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0), quicEnabled = false
    )
    check:
      node.enr.ipOf().isNone()
      node.enr.tcpOf().isNone()

  asyncTest "start fills the bound port and still carries no host":
    let node = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0), quicEnabled = false
    )
    await node.start()

    let bound = getPorts(node.switch.peerInfo.listenAddrs).expect("bound ports")
    check:
      node.enr.ipOf().isNone()
      node.enr.tcpOf().get() == uint16(bound.tcpPort.get())
      node.enr.multiaddrsOf().len == 0
      node.announcedAddresses.allIt("0.0.0.0" notin $it)
    await node.stop()

  asyncTest "a concrete bind host is a chosen host and is carried":
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    await node.start()

    let bound = getPorts(node.switch.peerInfo.listenAddrs).expect("bound ports")
    check:
      node.enr.ipOf().get() == [127'u8, 0, 0, 1]
      node.enr.tcpOf().get() == uint16(bound.tcpPort.get())
      node.enr.multiaddrsOf().len > 0
    await node.stop()

  asyncTest "a mapper addition is carried, the wildcard stand-in is not":
    let node = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0), quicEnabled = false
    )
    await node.start()
    check node.enrAddresses().len == 0

    let granted = MultiAddress.init("/ip4/203.0.113.55/tcp/60555").get()
    node.switch.peerInfo.addressMappers.add(
      proc(
          addrs: seq[MultiAddress]
      ): Future[seq[MultiAddress]] {.gcsafe, async: (raises: [CancelledError]).} =
        return addrs & @[granted]
    )
    await node.switch.peerInfo.update()

    check:
      node.enrAddresses() == @[granted]
      node.enr.ipOf().get() == [203'u8, 0, 113, 55]
      node.enr.tcpOf().get() == 60555'u16
      node.enr.multiaddrsOf() == @[granted]
    await node.stop()

  asyncTest "a configured external port stays beside its configured host":
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("0.0.0.0"),
      Port(0),
      extIp = Opt.some(parseIpAddress("203.0.113.9")),
      extPort = Opt.some(Port(1234)),
      quicEnabled = false,
    )
    check:
      node.enrBaseline().ip.get() == parseIpAddress("203.0.113.9")
      node.enrBaseline().tcp.get() == Port(1234)

    await node.start()
    check:
      node.enr.ipOf().get() == [203'u8, 0, 113, 9]
      node.enr.tcpOf().get() == 1234'u16
    await node.stop()

  test "a rebuild keeps every field that is not an address":
    let key = generateSecp256k1Key()
    var builder = EnrBuilder.init(key)
    builder
      .withWakuRelaySharding(RelayShards(clusterId: 1, shardIds: @[0'u16, 5]))
      .expect("shards")
    builder.withWakuCapabilities(Capabilities.Relay)
    var record = builder.build().expect("record")
    let seqBefore = record.seqNum

    let announced = @[MultiAddress.init("/ip4/203.0.113.9/tcp/60000").get()]
    check record
      .updateEnrAddresses(
        key, announced, (ip: Opt.none(IpAddress), tcp: Opt.none(Port))
      )
      .isOk()

    check:
      record.seqNum > seqBefore
      record.ipOf().get() == [203'u8, 0, 113, 9]
      record.tcpOf().get() == 60000'u16
      record.toTyped().expect("typed").relaySharding().isSome()
      record.getCapabilities() == @[Capabilities.Relay]

  test "a host that went away goes away with its endpoint":
    let key = generateSecp256k1Key()
    var record = EnrBuilder.init(key).build().expect("record")

    let granted = @[MultiAddress.init("/ip4/203.0.113.9/tcp/60000").get()]
    let none = (ip: Opt.none(IpAddress), tcp: Opt.none(Port))
    check record.updateEnrAddresses(key, granted, none).isOk()
    check record.ipOf().isSome()

    check record.updateEnrAddresses(key, @[], none).isOk()
    check:
      record.ipOf().isNone()
      record.tcpOf().isNone()
      record.multiaddrsOf().len == 0

  test "the host discv5 learned decides the scalars":
    let key = generateSecp256k1Key()
    var record = EnrBuilder.init(key).build().expect("record")
    let learned = Opt.some((ip: parseIpAddress("198.51.100.4"), udp: Port(30303)))

    ## No announced endpoint on the learned host and no baseline: no tcp.
    check record
      .updateEnrAddresses(
        key,
        @[MultiAddress.init("/ip4/203.0.113.9/tcp/60000").get()],
        (ip: Opt.none(IpAddress), tcp: Opt.none(Port)),
        learned,
      )
      .isOk()
    check:
      record.ipOf().get() == [198'u8, 51, 100, 4]
      record.udpOf().get() == 30303'u16
      record.tcpOf().isNone()

    ## An announced endpoint on the learned host: its port goes beside it.
    check record
      .updateEnrAddresses(
        key,
        @[MultiAddress.init("/ip4/198.51.100.4/tcp/60123").get()],
        (ip: Opt.none(IpAddress), tcp: Opt.none(Port)),
        learned,
      )
      .isOk()
    check:
      record.ipOf().get() == [198'u8, 51, 100, 4]
      record.tcpOf().get() == 60123'u16

  test "a learned host keeps the baseline port when nothing announced matches":
    ## Discovery is on by default, so this is the common server: bound to the
    ## wildcard with no --ext-ip, it announces no host of its own, and discv5
    ## learns one. Dropping tcp here left it undialable over TCP.
    let key = generateSecp256k1Key()
    let learned = Opt.some((ip: parseIpAddress("198.51.100.4"), udp: Port(30303)))
    let baseline = (ip: Opt.none(IpAddress), tcp: Opt.some(Port(60000)))

    ## Nothing announced at all: the bound port stays beside the learned host.
    var wildcardBound = EnrBuilder.init(key).build().expect("record")
    check wildcardBound.updateEnrAddresses(key, @[], baseline, learned).isOk()
    check:
      wildcardBound.ipOf().get() == [198'u8, 51, 100, 4]
      wildcardBound.tcpOf().get() == 60000'u16

    ## A dns4 name carries no IP, so it never matches the learned host.
    var named = EnrBuilder.init(key).build().expect("record")
    check named
      .updateEnrAddresses(
        key,
        @[MultiAddress.init("/dns4/node.example/tcp/60000").get()],
        baseline,
        learned,
      )
      .isOk()
    check:
      named.ipOf().get() == [198'u8, 51, 100, 4]
      named.tcpOf().get() == 60000'u16

    ## An --ext-ip the peers do not see: the configured port stays.
    var mismatched = EnrBuilder.init(key).build().expect("record")
    check mismatched
      .updateEnrAddresses(
        key,
        @[MultiAddress.init("/ip4/203.0.113.9/tcp/60000").get()],
        (ip: Opt.some(parseIpAddress("203.0.113.9")), tcp: Opt.some(Port(1234))),
        learned,
      )
      .isOk()
    check:
      mismatched.ipOf().get() == [198'u8, 51, 100, 4]
      mismatched.tcpOf().get() == 1234'u16

  asyncTest "a wildcard-bound node stays dialable once discv5 learns its host":
    ## End to end over the production refresh, not the writer alone.
    let key = generateSecp256k1Key()
    let node =
      newTestWakuNode(key, parseIpAddress("0.0.0.0"), Port(0), quicEnabled = false)
    await node.start()

    let keyBytes = key.getRawBytes().expect("raw")
    let ethPk = keys.PrivateKey.fromHex(byteutils.toHex(keyBytes)).expect("pk")
    let proto = discv5_protocol.newProtocol(
      ethPk,
      enrIp = Opt.none(IpAddress),
      enrTcpPort = Opt.none(Port),
      enrUdpPort = Opt.none(Port),
      previousRecord = Opt.some(node.enr),
      bindPort = Port(9913),
      bindIp = Opt.none(IpAddress),
    )
    let wd = WakuDiscoveryV5(protocol: proto)
    proto.localNode.record = node.enr

    let bound = getPorts(node.switch.peerInfo.listenAddrs).expect("bound ports")
    check proto.localNode
      .update(
        ethPk,
        ip = Opt.some(parseIpAddress("198.51.100.4")),
        udpPort = Opt.some(Port(30303)),
      )
      .isOk()
    check refreshEnrAddrs(node, key, wd).isOk()

    check:
      node.enr.ipOf().get() == [198'u8, 51, 100, 4]
      node.enr.tcpOf().get() == uint16(bound.tcpPort.get())
      node.enr.toRemotePeerInfo().isOk()
    await node.stop()

  test "a record is dialable through its multiaddrs field alone":
    ## The scalars hold one IPv4 host, so a dns4 name or a relay route lives
    ## only in the multiaddrs field. A record carrying one is still dialable.
    let key = generateSecp256k1Key()
    let baseline = (ip: Opt.none(IpAddress), tcp: Opt.none(Port))

    var bare = EnrBuilder.init(key).build().expect("record")
    check bare.updateEnrAddresses(key, @[], baseline).isOk()
    check not bare.hasDialableAddress()

    var named = EnrBuilder.init(key).build().expect("record")
    check named
      .updateEnrAddresses(
        key, @[MultiAddress.init("/dns4/node.example/tcp/60000").get()], baseline
      )
      .isOk()
    check named.hasDialableAddress()

    var relayed = EnrBuilder.init(key).build().expect("record")
    let circuit = MultiAddress
      .init(
        "/ip4/198.51.100.7/tcp/60000/p2p/" &
          "16Uiu2HAmPLe6a5Cu1kHUwKmVXQBQNjhZnToF9Y2AcYiFAAvbZBMc/p2p-circuit"
      )
      .get()
    check relayed.updateEnrAddresses(key, @[circuit], baseline).isOk()
    check relayed.hasDialableAddress()

    ## The scalars alone are enough, with nothing in the field.
    var hosted = EnrBuilder.init(key).build().expect("record")
    check hosted
      .updateEnrAddresses(
        key,
        @[],
        (ip: Opt.some(parseIpAddress("203.0.113.9")), tcp: Opt.some(Port(60000))),
      )
      .isOk()
    check hosted.hasDialableAddress()

  test "the reconcile loop follows a discv5 record write":
    let key = generateSecp256k1Key()
    let node =
      newTestWakuNode(key, parseIpAddress("127.0.0.1"), Port(0), quicEnabled = false)

    let keyBytes = key.getRawBytes().expect("raw")
    let ethPk = keys.PrivateKey.fromHex(byteutils.toHex(keyBytes)).expect("pk")
    let proto = discv5_protocol.newProtocol(
      ethPk,
      enrIp = Opt.none(IpAddress),
      enrTcpPort = Opt.none(Port),
      enrUdpPort = Opt.none(Port),
      previousRecord = Opt.some(node.enr),
      bindPort = Port(9911),
      bindIp = Opt.none(IpAddress),
    )
    let wd = WakuDiscoveryV5(protocol: proto)
    node.announcedAddresses = @[MultiAddress.init("/ip4/198.51.100.4/tcp/60123").get()]

    ## `updateWaku` seeds the live record from the node's copy.
    proto.localNode.record = node.enr

    ## Nothing moved yet, so nothing to write.
    check reconcileEnrAddrs(node, key, wd).expect("reconcile") == false

    ## discv5 learns its host and writes its own record, telling nobody.
    check proto.localNode
      .update(
        ethPk,
        ip = Opt.some(parseIpAddress("198.51.100.4")),
        udpPort = Opt.some(Port(30303)),
      )
      .isOk()

    check reconcileEnrAddrs(node, key, wd).expect("reconcile") == true
    check:
      node.enr == proto.localNode.record
      node.enr.ipOf().get() == [198'u8, 51, 100, 4]
      node.enr.tcpOf().get() == 60123'u16
      node.enr.udpOf().get() == 30303'u16

  test "the discv5 address follows the endpoint the record advertises":
    ## discv5 compares the host its peers vote for with this address. Left
    ## unset, it never matches, and a node with auto-update off warns at
    ## every vote interval.
    let key = generateSecp256k1Key()
    let node =
      newTestWakuNode(key, parseIpAddress("127.0.0.1"), Port(0), quicEnabled = false)
    node.announcedAddresses = @[MultiAddress.init("/ip4/198.51.100.4/tcp/60123").get()]

    let keyBytes = key.getRawBytes().expect("raw")
    let ethPk = keys.PrivateKey.fromHex(byteutils.toHex(keyBytes)).expect("pk")
    let proto = discv5_protocol.newProtocol(
      ethPk,
      enrIp = Opt.none(IpAddress),
      enrTcpPort = Opt.none(Port),
      enrUdpPort = Opt.some(Port(9000)),
      previousRecord = Opt.some(node.enr),
      bindPort = Port(9000),
      bindIp = Opt.none(IpAddress),
    )
    let wd = WakuDiscoveryV5(protocol: proto)

    ## `updateWaku` drops the address the seed handed discv5.
    proto.localNode.address = Opt.none(discv5_node.Address)

    check refreshEnrAddrs(node, key, wd).isOk()
    check:
      node.enr.ipOf().get() == [198'u8, 51, 100, 4]
      node.enr.udpOf().get() == 9000'u16
      proto.localNode.address ==
        Opt.some(
          discv5_node.Address(ip: parseIpAddress("198.51.100.4"), port: Port(9000))
        )
