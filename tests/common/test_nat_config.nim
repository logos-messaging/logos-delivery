{.used.}

import std/[net, strutils]
import testutils/unittests, chronos, results
import libp2p/services/nat/portmapper
import ../../logos_delivery/waku/common/nat_config

suite "NAT config - strategy parsing":
  test "valid strategies parse":
    check:
      parseNatStrategy("any").get().kind == NatAny
      parseNatStrategy("none").get().kind == NatNone
      parseNatStrategy("upnp").get().kind == NatUpnp
      parseNatStrategy("pmp").get().kind == NatPmp

  test "parsing is case-insensitive":
    check:
      parseNatStrategy("UPnP").get().kind == NatUpnp
      parseNatStrategy("NONE").get().kind == NatNone

  test "extip carries the address":
    let strategy = parseNatStrategy("extip:203.0.113.7").get()
    check:
      strategy.kind == NatExtIp
      $strategy.extIp == "203.0.113.7"

  test "invalid mechanism is rejected":
    check:
      parseNatStrategy("bogus").isErr()
      parseNatStrategy("").isErr()

  test "invalid extip address is rejected":
    check:
      parseNatStrategy("extip:notanip").isErr()

  test "strategies render back to their config strings":
    check:
      $parseNatStrategy("any").get() == "any"
      $parseNatStrategy("extip:203.0.113.7").get() == "extip:203.0.113.7"

suite "NAT config - NATConfig mapping":
  test "upnp, any and pmp produce a NATConfig":
    check:
      toNatConfig(NatStrategy(kind: NatUpnp)).isSome()
      toNatConfig(NatStrategy(kind: NatAny)).isSome()
      toNatConfig(NatStrategy(kind: NatPmp)).isSome()

  test "none and extip produce no NATConfig":
    check:
      toNatConfig(NatStrategy(kind: NatNone)).isNone()
      toNatConfig(NatStrategy(kind: NatExtIp, extIp: parseIpAddress("203.0.113.7")))
        .isNone()

  test "every NAT strategy gets a port mapper factory, the rest none":
    check:
      not natPortMapperFactory(NatStrategy(kind: NatAny)).isNil()
      not natPortMapperFactory(NatStrategy(kind: NatUpnp)).isNil()
      not natPortMapperFactory(NatStrategy(kind: NatPmp)).isNil()
      natPortMapperFactory(NatStrategy(kind: NatNone)).isNil()
      natPortMapperFactory(
        NatStrategy(kind: NatExtIp, extIp: parseIpAddress("203.0.113.7"))
      )
        .isNil()

type StubMapper = ref object of PortMapper
  ## Scripted port mapper: discovery yields `ip` when set, an error otherwise.
  ## `mapRejections` makes that many leading map() calls fail, mimicking a
  ## gateway whose requested slot is occupied until the entry is removed.
  ip: Opt[IpAddress]
  mapRejections: int
  occupiedPort: Opt[Port]
  unmapDenied: bool
  discoverCalls: int
  mapCalls: int
  unmapCalls: int
  closeCalls: int
  lastMapProto: MapProto
  lastMapLease: uint32

method discover(
    self: StubMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  inc self.discoverCalls
  let ip = self.ip.valueOr:
    return err("stub discovery failure")
  return ok(ip)

method map(
    self: StubMapper,
    internalPort: Port,
    externalPort: Port,
    proto: MapProto,
    lease: uint32,
): Future[Result[Port, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  inc self.mapCalls
  self.lastMapProto = proto
  self.lastMapLease = lease
  if self.mapRejections > 0:
    dec self.mapRejections
    return err("stub mapping rejection")
  if self.occupiedPort == Opt.some(externalPort):
    return err("stub port occupied")
  return ok(externalPort)

method unmap(
    self: StubMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  inc self.unmapCalls
  if self.unmapDenied:
    return err("stub unmap denied")
  return ok()

method close(self: StubMapper) {.async: (raises: []), gcsafe.} =
  inc self.closeCalls

proc stub(ip = ""): StubMapper =
  let address =
    if ip.len > 0:
      Opt.some(parseIpAddress(ip))
    else:
      Opt.none(IpAddress)
  StubMapper(ip: address)

suite "NAT config - fallback port mapper":
  asyncTest "first successful candidate is elected, the rest are kept":
    let
      first = stub("203.0.113.1")
      second = stub("203.0.113.2")
      mapper = FallbackPortMapper.new(first, second)

    let res = await mapper.discover(1.seconds)
    check:
      $res.get() == "203.0.113.1"
      second.discoverCalls == 0 # never probed, first already won
      second.closeCalls == 0 # kept for possible re-election
      first.closeCalls == 0

  asyncTest "discovery falls back to the next candidate":
    let
      first = stub()
      second = stub("203.0.113.2")
      mapper = FallbackPortMapper.new(first, second)

    let res = await mapper.discover(1.seconds)
    check:
      $res.get() == "203.0.113.2"
      first.discoverCalls == 1
      first.closeCalls == 0 # kept for possible re-election

  asyncTest "a healthy active mapper is not re-elected":
    let
      first = stub("203.0.113.1")
      second = stub("203.0.113.2")
      mapper = FallbackPortMapper.new(first, second)

    discard await mapper.discover(1.seconds)
    discard await mapper.discover(1.seconds)
    check:
      first.discoverCalls == 2 # re-discovery delegates to the active mapper
      second.discoverCalls == 0

  asyncTest "a failing active mapper triggers re-election":
    let
      first = stub("203.0.113.1")
      second = stub("203.0.113.2")
      mapper = FallbackPortMapper.new(first, second)

    discard await mapper.discover(1.seconds)
    # the elected mapper stops finding the gateway (reboot, mechanism gone)
    first.ip = Opt.none(IpAddress)

    let res = await mapper.discover(1.seconds)
    check:
      res.isOk()
      $res.get() == "203.0.113.2" # the other candidate takes over

  asyncTest "discovery reports every candidate failure":
    let mapper = FallbackPortMapper.new(stub(), stub())

    let res = await mapper.discover(1.seconds)
    check:
      res.isErr()
      "all NAT port mappers failed discovery" in res.error
      res.error.count("stub discovery failure") == 2

  asyncTest "map and unmap require a successful discovery":
    let mapper = FallbackPortMapper.new(stub("203.0.113.1"))

    check:
      (await mapper.map(Port(1), Port(1), mpTcp, 60)).isErr()
      (await mapper.unmap(Port(1), mpTcp)).isErr()

  asyncTest "map and unmap delegate to the active mapper":
    let
      active = stub("203.0.113.1")
      mapper = FallbackPortMapper.new(active)

    discard await mapper.discover(1.seconds)
    check:
      (await mapper.map(Port(7), Port(9), mpTcp, 60)).get() == Port(9)
      (await mapper.unmap(Port(9), mpTcp)).isOk()
      active.mapCalls == 1
      active.unmapCalls == 1

  asyncTest "close closes the active mapper once":
    let
      active = stub("203.0.113.1")
      loser = stub("203.0.113.2")
      mapper = FallbackPortMapper.new(active, loser)

    discard await mapper.discover(1.seconds)
    await mapper.close()
    await mapper.close()
    check:
      active.closeCalls == 1
      loser.closeCalls == 1

  asyncTest "close before discovery closes every candidate":
    let
      first = stub("203.0.113.1")
      second = stub("203.0.113.2")
      mapper = FallbackPortMapper.new(first, second)

    await mapper.close()
    check:
      first.closeCalls == 1
      second.closeCalls == 1

suite "NAT config - permanent udp port mapping":
  asyncTest "maps the port permanently through the mapper":
    let inner = stub("203.0.113.1")

    let res = await mapPermanentUdpPort(PortMapper(inner), Port(9000))
    check:
      res.get().externalIp == parseIpAddress("203.0.113.1")
      res.get().externalPort == Port(9000)
      inner.discoverCalls == 1
      inner.mapCalls == 1
      inner.lastMapProto == mpUdp
      inner.lastMapLease == 0 # permanent lease

  asyncTest "reports discovery failure":
    let res = await mapPermanentUdpPort(PortMapper(stub()), Port(9000))
    check:
      res.isErr()

suite "NAT config - retrying port mapper":
  asyncTest "a clean mapping needs no retry":
    let
      inner = stub("203.0.113.1")
      mapper = RetryingPortMapper.new(inner)

    check:
      (await mapper.map(Port(7), Port(7), mpTcp, 60)).get() == Port(7)
      inner.mapCalls == 1
      inner.unmapCalls == 0

  asyncTest "a rejected mapping is retried after removing the stale entry":
    let inner = stub("203.0.113.1")
    inner.mapRejections = 1
    let mapper = RetryingPortMapper.new(inner)

    check:
      (await mapper.map(Port(7), Port(7), mpTcp, 60)).get() == Port(7)
      inner.mapCalls == 2
      inner.unmapCalls == 1 # the stale entry was removed between attempts

  asyncTest "a mapping that keeps being rejected everywhere fails":
    let inner = stub("203.0.113.1")
    inner.mapRejections = 3
    let mapper = RetryingPortMapper.new(inner)

    check:
      (await mapper.map(Port(7), Port(7), mpTcp, 60)).isErr()
      inner.mapCalls == 3 # requested, delete-and-readd, alternate; no loop

  asyncTest "a persistently occupied port falls back to an alternate external port":
    let inner = stub("203.0.113.1")
    inner.occupiedPort = Opt.some(Port(7))
    let mapper = RetryingPortMapper.new(inner)

    let res = await mapper.map(Port(7), Port(7), mpTcp, 60)
    check:
      res.isOk()
      res.get() != Port(7) # mapped, on some other external port

  asyncTest "a denied unmap still ends in a working mapping":
    let inner = stub("203.0.113.1")
    inner.occupiedPort = Opt.some(Port(7))
    inner.unmapDenied = true
    let mapper = RetryingPortMapper.new(inner)

    let res = await mapper.map(Port(7), Port(7), mpTcp, 60)
    check:
      res.isOk()
      res.get() != Port(7)

  asyncTest "discover, unmap and close delegate to the wrapped mapper":
    let
      inner = stub("203.0.113.1")
      mapper = RetryingPortMapper.new(inner)

    check:
      $(await mapper.discover(1.seconds)).get() == "203.0.113.1"
      (await mapper.unmap(Port(7), mpTcp)).isOk()
    await mapper.close()
    check:
      inner.discoverCalls == 1
      inner.unmapCalls == 1
      inner.closeCalls == 1
