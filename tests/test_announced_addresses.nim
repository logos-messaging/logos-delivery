{.used.}

## libp2p commits the final announced addresses into peerInfo after
## the address mappers run. These tests check that node.announcedAddresses
## and the ENR multiaddrs field copy that committed set.

import results
import std/[net, sequtils, strutils]
import testutils/unittests, chronos
import libp2p/[multiaddress, switch, wire]
import libp2p/crypto/crypto as libp2pcrypto
import libp2p/services/natservice
import libp2p/services/nat/portmapper
import eth/p2p/discoveryv5/protocol as discv5_protocol
import ../logos_delivery/waku/discovery/waku_discv5
import eth/keys, eth/p2p/discoveryv5/enr
import stew/byteutils
import
  ../logos_delivery/waku/node/waku_node,
  ../logos_delivery/waku/waku,
  ../logos_delivery/waku/waku_enr
import ./testlib/[common, wakucore, wakunode]

const CircuitAddr =
  "/ip4/93.184.216.34/tcp/4001/p2p/" &
  "16Uiu2HAm7YEh2wwbYNvayrSQe2bdm1aL4FnhCLkvSNaScMxcgt4n/p2p-circuit"

type RecordingMapper = ref object of PortMapper
  grantIp: IpAddress
  grantPort: Port
  mappedInternal: seq[Port]

method discover(
    self: RecordingMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  return ok(self.grantIp)

method map(
    self: RecordingMapper, internalPort: Port, externalPort: Port, proto: MapProto
): Future[Result[MappedPort, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  self.mappedInternal.add(internalPort)
  return ok(MappedPort(externalIp: self.grantIp, externalPort: self.grantPort))

method unmap(
    self: RecordingMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  return ok()

method close(self: RecordingMapper) {.async: (raises: []), gcsafe.} =
  discard

type EagerUpdate = ref object of Service
  ## Runs a peerInfo update while the switch starts, before the node
  ## resolves its announced addresses. The base mapper must drop port-0
  ## entries during that update, or the NATService maps port 0.

method setup(self: EagerUpdate, switch: Switch) {.raises: [ServiceSetupError].} =
  discard

method start(self: EagerUpdate, switch: Switch) {.async: (raises: [CancelledError]).} =
  await switch.peerInfo.update()

method stop(self: EagerUpdate, switch: Switch) {.async: (raises: [CancelledError]).} =
  discard

suite "Announced addresses":
  asyncTest "the resolved base reaches peerInfo and the API projection":
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
    await node.start()
    check:
      node.announcedAddresses.len > 0
      node.announcedAddresses == node.switch.peerInfo.addrs
      node.announcedAddresses.allIt("/tcp/0" notin $it and "/udp/0/" notin $it)
      node.announcedAddresses.allIt("0.0.0.0" notin $it)
    await node.stop()

  asyncTest "a loopback bind stays loopback in the base":
    ## Rewriting loopback to the LAN IP once crashed the test suite
    ## because it announces endpoints nothing listens on.
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    await node.start()
    check:
      node.announcedAddresses.len > 0
      node.announcedAddresses.allIt("/ip4/127.0.0.1/" in $it)
    await node.stop()

  asyncTest "an operator host containing the wildcard substring survives intact":
    ## The host string contains "0.0.0.0". Text replacement corrupted it.
    ## Matching the parsed IP keeps it unchanged.
    let tricky = MultiAddress.init("/ip4/10.0.0.0/tcp/60123").get()
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(0),
      extMultiAddrs = @[tricky],
    )
    await node.start()
    check:
      tricky in node.announcedAddresses
    await node.stop()

  asyncTest "a circuit route flows through the chain, and removal converges on the next update":
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    await node.start()

    let circuit = MultiAddress.init(CircuitAddr).get()
    var injecting = true
    node.switch.peerInfo.addressMappers.add(
      proc(
          addrs: seq[MultiAddress]
      ): Future[seq[MultiAddress]] {.gcsafe, async: (raises: [CancelledError]).} =
        if injecting:
          return @[circuit] & addrs
        return addrs
    )

    ## The service's own update carries the route.
    await node.switch.peerInfo.update()
    check:
      circuit in node.switch.peerInfo.addrs
      circuit in node.announcedAddresses
      node.announcedAddresses.anyIt(not it.isCircuitRelayMA())

    ## libp2p keeps peerInfo unchanged on removal.
    ## The stale route stays until the next update.
    injecting = false
    check circuit in node.announcedAddresses ## stale until next update
    await node.switch.peerInfo.update() ## any later natural commit
    check:
      circuit notin node.switch.peerInfo.addrs
      circuit notin node.announcedAddresses
    await node.stop()

  asyncTest "NAT restart derives from the configured intent":
    var recorders: seq[RecordingMapper]
    var grantPort = Port(62001)
    let grantIp = parseIpAddress("203.0.113.77")
    let factory = proc(mode: PortMappingMode): Opt[PortMapper] {.gcsafe, raises: [].} =
      let rec = RecordingMapper(grantIp: grantIp, grantPort: grantPort)
      {.gcsafe.}:
        recorders.add(rec)
      Opt.some(PortMapper(rec))

    ## A private configured address for NATService to map.
    ## The test runs the same on every machine.
    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(0),
      extMultiAddrs = @[MultiAddress.init("/ip4/192.168.77.7/tcp/60111").get()],
    )
    let natSvc = NATService.new(upnpConfig(), rng(), portMapperFactory = factory)
    ## The eager service updates before start resolves the announced addresses.
    node.switch.services.add(Service(EagerUpdate()))
    node.switch.services.add(Service(natSvc))

    await node.start()
    let mappersAfterFirstStart = node.switch.peerInfo.addressMappers.len
    check node.announcedAddresses.anyIt("203.0.113.77" in $it and "62001" in $it)
    await node.stop()

    grantPort = Port(62002)
    await node.start()
    check:
      ## The mapper count stays flat across restarts.
      node.switch.peerInfo.addressMappers.len == mappersAfterFirstStart
      ## The new grant is announced. The mapper got the configured address.
      node.announcedAddresses.anyIt("203.0.113.77" in $it and "62002" in $it)
      recorders.allIt(Port(0) notin it.mappedInternal)
    await node.stop()

  asyncTest "an unchanged owned update needs the explicit copy":
    let node =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    await node.start()
    let committed = node.switch.peerInfo.addrs

    node.announcedAddresses = @[]
    await node.switch.peerInfo.update()
    check node.announcedAddresses.len == 0 ## unchanged commit, observer silent

    node.copyCommittedAddresses()
    check node.announcedAddresses == committed
    await node.stop()

  asyncTest "ext-multiaddr-only bypasses the chain from before start":
    let ext = MultiAddress.init("/ip4/203.0.113.44/tcp/60123").get()
    var recorders: seq[RecordingMapper]
    let grantIp = parseIpAddress("203.0.113.77")
    let factory = proc(mode: PortMappingMode): Opt[PortMapper] {.gcsafe, raises: [].} =
      let rec = RecordingMapper(grantIp: grantIp, grantPort: Port(62003))
      {.gcsafe.}:
        recorders.add(rec)
      Opt.some(PortMapper(rec))

    let node = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(0),
      extMultiAddrs = @[ext],
      extMultiAddrsOnly = true,
    )
    ## The override is active from construction, before any start.
    check node.switch.peerInfo.announcedAddrs == @[ext]

    node.switch.services.add(Service(EagerUpdate()))
    node.switch.services.add(
      Service(NATService.new(upnpConfig(), rng(), portMapperFactory = factory))
    )
    await node.start()
    check:
      node.announcedAddresses == @[ext]
      node.switch.peerInfo.addrs == @[ext]
      ## libp2p skipped the chain. The factory ran and every mapper stayed idle.
      recorders.len >= 1
      recorders.allIt(it.mappedInternal.len == 0)
    await node.stop()

  test "the ENR refresh trims to the largest fitting prefix and keeps shards":
    let key = generateSecp256k1Key()
    let node = newTestWakuNode(key, parseIpAddress("127.0.0.1"), Port(0))
    var builder = EnrBuilder.init(key)
    builder
      .withWakuRelaySharding(RelayShards(clusterId: 1, shardIds: @[0'u16, 1, 2, 3]))
      .expect("shards")
    node.enr = builder.build().expect("record")

    var addrs: seq[MultiAddress]
    for i in 0 ..< 6:
      addrs.add(MultiAddress.init(CircuitAddr).get())
      addrs.add(MultiAddress.init("/ip4/203.0.113." & $i & "/tcp/60000").get())
    node.announcedAddresses = addrs

    check refreshEnrAddrs(node, key, nil).isOk()

    let typed = node.enr.toTyped().expect("typed")
    let decoded = typed.multiaddrs.expect("multiaddrs field")
    check:
      decoded.len > 0
      decoded.len < addrs.len ## oversized input was trimmed
      decoded[0].isCircuitRelayMA() ## relay routes sort first and stay
      node.enr.toTyped().expect("typed").relaySharding().isSome()

  test "an empty committed set clears the ENR multiaddrs field":
    let key = generateSecp256k1Key()
    let node = newTestWakuNode(key, parseIpAddress("127.0.0.1"), Port(0))
    node.announcedAddresses = @[MultiAddress.init("/ip4/203.0.113.9/tcp/60000").get()]
    check refreshEnrAddrs(node, key, nil).isOk()
    node.announcedAddresses = @[]
    check refreshEnrAddrs(node, key, nil).isOk()
    let typed = node.enr.toTyped().expect("typed")
    check typed.multiaddrs.expect("field").len == 0

  test "the live discv5 record takes the refresh and copies back":
    let key = generateSecp256k1Key()
    let node = newTestWakuNode(key, parseIpAddress("127.0.0.1"), Port(0))

    var builder = EnrBuilder.init(key)
    builder
      .withWakuRelaySharding(RelayShards(clusterId: 1, shardIds: @[0'u16, 5]))
      .expect("shards")
    let seedRecord = builder.build().expect("record")

    let keyBytes = key.getRawBytes().expect("raw")
    let ethPk = keys.PrivateKey.fromHex(byteutils.toHex(keyBytes)).expect("pk")
    let proto = discv5_protocol.newProtocol(
      ethPk,
      enrIp = Opt.none(IpAddress),
      enrTcpPort = Opt.none(Port),
      enrUdpPort = Opt.none(Port),
      previousRecord = Opt.some(seedRecord),
      bindPort = Port(9909),
      bindIp = Opt.none(IpAddress),
    )
    let wd = WakuDiscoveryV5(protocol: proto)
    let seqBefore = proto.localNode.record.seqNum

    node.announcedAddresses = @[
      MultiAddress.init(CircuitAddr).get(),
      MultiAddress.init("/ip4/203.0.113.9/tcp/60000").get(),
    ]
    check refreshEnrAddrs(node, key, wd).isOk()

    let live = proto.localNode.record
    let typed = live.toTyped().expect("typed")
    check:
      typed.multiaddrs.expect("field").len == 2
      typed.relaySharding().isSome() ## shards stay after the field update
      live.seqNum > seqBefore
      node.enr == live ## copy-back
