{.used.}

import std/[net, sequtils, strutils]
import testutils/unittests, chronos, results
import libp2p/[multiaddress, switch, wire]
import libp2p/services/natservice
import libp2p/services/wildcardresolverservice
import libp2p/protocols/connectivity/relay/relay
import libp2p/services/nat/[portmapper, plum_mapper]
import ../logos_delivery/waku/net/nat_config
import ../logos_delivery/waku/node/waku_switch
import ./testlib/[common, wakucore]

suite "NAT config - strategy parsing":
  test "valid strategies parse":
    check:
      parseNatStrategy("any").get().kind == NatStrategyKind.NatAny
      parseNatStrategy("none").get().kind == NatStrategyKind.NatNone
      parseNatStrategy("upnp").get().kind == NatStrategyKind.NatUpnp
      parseNatStrategy("pmp").get().kind == NatStrategyKind.NatPmp

  test "parsing is case-insensitive":
    check:
      parseNatStrategy("UPnP").get().kind == NatStrategyKind.NatUpnp
      parseNatStrategy("NONE").get().kind == NatStrategyKind.NatNone

  test "extip carries the address":
    let strategy = parseNatStrategy("extip:203.0.113.7").get()
    check:
      strategy.kind == NatStrategyKind.NatExtIp
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

type StubMapper = ref object of PortMapper
  ## A scripted port mapper. grantedPort overrides the requested external port.
  ip: Opt[IpAddress]
  grantedPort: Opt[Port]
  mapCalls: int
  unmapCalls: int
  lastUnmapPort: Port
  closeCalls: int
  lastMapProto: MapProto

method map(
    self: StubMapper, internalPort: Port, externalPort: Port, proto: MapProto
): Future[Result[MappedPort, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  discard internalPort
  inc self.mapCalls
  self.lastMapProto = proto
  let externalIp = self.ip.valueOr:
    return err("stub mapping failure")
  return ok(
    MappedPort(externalIp: externalIp, externalPort: self.grantedPort.get(externalPort))
  )

method unmap(
    self: StubMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  inc self.unmapCalls
  self.lastUnmapPort = externalPort
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

suite "NAT config - resolveNatStrategy":
  asyncTest "strategy selection is deferred to libplum":
    for s in ["any", "upnp", "pmp", "none", "extip:203.0.113.7"]:
      let strategy = parseNatStrategy(s).get()
      check $(await resolveNatStrategy(strategy)) == $strategy

suite "NAT config - natConfig":
  test "mapping strategies select their libplum protocol mode":
    let
      any = natConfig(parseNatStrategy("any").get())
      upnp = natConfig(parseNatStrategy("upnp").get())
      pmp = natConfig(parseNatStrategy("pmp").get())
    check:
      any.get().portMapping.get().mode == PortMappingMode.Auto
      upnp.get().portMapping.get().mode == PortMappingMode.Upnp
      pmp.get().portMapping.get().mode == PortMappingMode.NatPmp

  test "none and extip get no config":
    for s in ["none", "extip:203.0.113.7"]:
      check natConfig(parseNatStrategy(s).get()).isNone()

suite "NAT config - natPortMapper":
  test "mapping strategies use libplum":
    for s in ["any", "upnp", "pmp"]:
      let mapper = natPortMapper(parseNatStrategy(s).get())
      check mapper.get() of PlumMapper
      waitFor mapper.get().close()

  test "none and extip have no mapper":
    for s in ["none", "extip:203.0.113.7"]:
      check natPortMapper(parseNatStrategy(s).get()).isNone()

suite "NAT config - NATService pipeline":
  asyncTest "the real NATService maps and announces over a resolved private base":
    ## The default deployment binds 0.0.0.0. This test runs the real
    ## NATService and its setupMappings against that bind, with a mapper
    ## that answers resolved private addresses and a scripted gateway.
    let privateBase = @[MultiAddress.init("/ip4/192.168.9.9/tcp/60117").get()]
    let inner = stub("203.0.113.9")
    inner.grantedPort = Opt.some(Port(61000))
    let switch =
      newTestSwitch(address = Opt.some(MultiAddress.init("/ip4/0.0.0.0/tcp/0").get()))
    switch.services.keepItIf(it of NATService)
    ## The same shape as the production base mapper. It answers with
    ## the resolved private addresses.
    switch.peerInfo.addressMappers.insert(
      proc(
          addrs: seq[MultiAddress]
      ): Future[seq[MultiAddress]] {.gcsafe, async: (raises: [CancelledError]).} =
        return privateBase,
      0,
    )
    let svc = NATService.new(
      natConfig(parseNatStrategy("pmp").get()).get(),
      rng(),
      portMapperFactory = proc(
          mode: PortMappingMode
      ): Opt[PortMapper] {.gcsafe, raises: [].} =
        Opt.some(PortMapper(inner)),
    )
    switch.services.add(Service(svc))
    svc.setup(switch)
    await switch.start()

    check:
      inner.mapCalls >= 1
      switch.peerInfo.addrs.anyIt(($it).contains("203.0.113.9"))
      not switch.peerInfo.addrs.anyIt(($it).contains("0.0.0.0"))

    await switch.stop()

suite "NAT config - switch composition":
  test "the switch has no wildcard service and no build-time mappers":
    let switch = newWakuSwitch(rng = rng(), circuitRelay = Relay.new())
    check:
      not switch.services.anyIt(it of WildcardAddressResolverService)
      switch.peerInfo.addressMappers.len == 0
