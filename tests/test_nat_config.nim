{.used.}

import std/[net, sequtils, strutils]
import testutils/unittests, chronos, results
import libp2p/[multiaddress, switch, wire]
import libp2p/services/natservice
import libp2p/services/wildcardresolverservice
import libp2p/protocols/connectivity/relay/relay
import libp2p/services/nat/[portmapper, upnp_mapper, natpmp_mapper]
import ../logos_delivery/waku/net/nat_config
import ../logos_delivery/waku/node/waku_switch
import ./testlib/[common, wakucore]

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

type StubMapper = ref object of PortMapper
  ## A scripted port mapper. mapRejections fails that many leading map calls.
  ## grantedPort overrides the granted external port.
  ip: Opt[IpAddress]
  hangDiscover: bool
  mapRejections: int
  grantedPort: Opt[Port]
  discoverCalls: int
  mapCalls: int
  unmapCalls: int
  lastUnmapPort: Port
  closeCalls: int
  lastMapProto: MapProto
  lastMapLease: uint32

method discover(
    self: StubMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  inc self.discoverCalls
  if self.hangDiscover:
    await sleepAsync(10.minutes)
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
  # Lease 0 is invalid input, as in libp2p's NAT-PMP mapper.
  # RFC 6886 uses a zero lifetime to delete a mapping.
  if lease == 0:
    return err("stub: lease 0 rejected (RFC 6886 delete semantics)")
  if self.mapRejections > 0:
    dec self.mapRejections
    return err("stub mapping rejection")
  return ok(self.grantedPort.get(externalPort))

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
  asyncTest "every strategy but any passes through unchanged":
    for s in ["upnp", "pmp", "none", "extip:203.0.113.7"]:
      let strategy = parseNatStrategy(s).get()
      check $(await resolveNatStrategy(strategy)) == $strategy

  asyncTest "any resolves to upnp when its discovery answers first":
    var probed: seq[NatStrategyKind]
    let answering = stub("203.0.113.1")
    let silent = PortMapper(stub())
    let resolved = await resolveNatStrategy(
      NatStrategy(kind: NatAny),
      mapperFor = proc(s: NatStrategy): Opt[PortMapper] {.gcsafe, raises: [].} =
        probed.add(s.kind)
        if s.kind == NatUpnp:
          Opt.some(PortMapper(answering))
        else:
          Opt.some(silent),
    )
    check:
      resolved.kind == NatUpnp
      probed == @[NatUpnp]
      answering.closeCalls == 1

  asyncTest "any falls back to pmp when upnp discovery fails":
    let answering = PortMapper(stub("203.0.113.1"))
    let silent = PortMapper(stub())
    let resolved = await resolveNatStrategy(
      NatStrategy(kind: NatAny),
      mapperFor = proc(s: NatStrategy): Opt[PortMapper] {.gcsafe, raises: [].} =
        if s.kind == NatPmp:
          Opt.some(answering)
        else:
          Opt.some(silent),
    )
    check resolved.kind == NatPmp

  asyncTest "any resolves to none when no gateway answers":
    let silent = PortMapper(stub())
    let resolved = await resolveNatStrategy(
      NatStrategy(kind: NatAny),
      mapperFor = proc(s: NatStrategy): Opt[PortMapper] {.gcsafe, raises: [].} =
        Opt.some(silent),
    )
    check resolved.kind == NatNone

  asyncTest "every probe mapper is closed before the probe returns":
    let silent = stub()
    discard await resolveNatStrategy(
      NatStrategy(kind: NatAny),
      discoveryTimeout = 10.millis,
      mapperFor = proc(s: NatStrategy): Opt[PortMapper] {.gcsafe, raises: [].} =
        Opt.some(PortMapper(silent)),
    )
    check silent.closeCalls == 2

  asyncTest "a cancelled probe still closes its mapper":
    let hanging = stub()
    hanging.hangDiscover = true
    let probe = resolveNatStrategy(
      NatStrategy(kind: NatAny),
      discoveryTimeout = 10.millis,
      mapperFor = proc(s: NatStrategy): Opt[PortMapper] {.gcsafe, raises: [].} =
        Opt.some(PortMapper(hanging)),
    )
    await sleepAsync(50.millis)
    await probe.cancelAndWait()
    check hanging.closeCalls == 1

suite "NAT config - natConfig":
  test "upnp and pmp turn port mapping on in their protocol's mode":
    let
      upnp = natConfig(parseNatStrategy("upnp").get())
      pmp = natConfig(parseNatStrategy("pmp").get())
    check:
      upnp.get().portMapping.get().mode == PortMappingMode.Upnp
      pmp.get().portMapping.get().mode == PortMappingMode.NatPmp

  test "any, none and extip get no config":
    for s in ["any", "none", "extip:203.0.113.7"]:
      check natConfig(parseNatStrategy(s).get()).isNone()

suite "NAT config - natPortMapper":
  test "upnp and pmp name their protocol's mapper":
    let
      upnp = natPortMapper(parseNatStrategy("upnp").get())
      pmp = natPortMapper(parseNatStrategy("pmp").get())
    check:
      upnp.get() of UpnpMapper
      pmp.get() of NatPmpMapper
    ## Constructors spawn a worker thread.
    ## Unclosed mappers crashed later suites when the GC reclaimed them.
    waitFor upnp.get().close()
    waitFor pmp.get().close()

  test "any, none and extip have no mapper":
    for s in ["any", "none", "extip:203.0.113.7"]:
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
      inner.discoverCalls >= 1
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
