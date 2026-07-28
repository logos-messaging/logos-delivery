{.push raises: [].}

## NAT strategy configuration.
##
## Parses the `--nat` CLI value into a `NatStrategy` and maps it onto
## libp2p's `NATConfig` (`SwitchBuilder.withNAT`), which owns UPnP / NAT-PMP
## port mapping, external-IP discovery, lease refresh and announced-address
## rewriting on a per-switch basis.

import
  std/[net, strutils],
  chronos,
  chronicles,
  results,
  libp2p/services/natservice,
  libp2p/services/nat/[portmapper, upnp_mapper, natpmp_mapper]

export natservice

logScope:
  topics = "nat"

type
  NatStrategyKind* = enum
    NatNone
    NatAny
    NatUpnp
    NatPmp
    NatExtIp

  NatStrategy* = object
    case kind*: NatStrategyKind
    of NatExtIp:
      extIp*: IpAddress
    else:
      discard

func `$`*(strategy: NatStrategy): string =
  case strategy.kind
  of NatNone:
    "none"
  of NatAny:
    "any"
  of NatUpnp:
    "upnp"
  of NatPmp:
    "pmp"
  of NatExtIp:
    "extip:" & $strategy.extIp

func parseNatStrategy*(natConf: string): Result[NatStrategy, string] =
  case natConf.toLowerAscii()
  of "any":
    ok(NatStrategy(kind: NatAny))
  of "none":
    ok(NatStrategy(kind: NatNone))
  of "upnp":
    ok(NatStrategy(kind: NatUpnp))
  of "pmp":
    ok(NatStrategy(kind: NatPmp))
  else:
    const ExtIpPrefix = "extip:"
    if not natConf.startsWith(ExtIpPrefix):
      return err("not a valid NAT mechanism: " & natConf)
    let ipStr = natConf[ExtIpPrefix.len ..^ 1]
    let ip =
      try:
        parseIpAddress(ipStr)
      except ValueError:
        return err("not a valid IP address: " & ipStr)
    ok(NatStrategy(kind: NatExtIp, extIp: ip))

type FallbackPortMapper* = ref object of PortMapper
  ## `--nat any`: try UPnP first, then NAT-PMP. Candidates are probed in
  ## order at discovery time and the first one that finds an external IP
  ## becomes the active mapper. All candidates are kept: when the active
  ## mapper later stops finding the gateway (reboot, mechanism change), the
  ## next discovery re-elects among them.
  candidates: seq[PortMapper]
  active: PortMapper

func new*(T: typedesc[FallbackPortMapper], candidates: varargs[PortMapper]): T =
  T(candidates: @candidates)

method discover*(
    self: FallbackPortMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if not self.active.isNil():
    let res = await self.active.discover(timeout)
    if res.isOk():
      return res
    debug "active NAT port mapper lost the gateway; re-electing", err = res.error
    self.active = nil

  var errors: seq[string]
  for candidate in self.candidates:
    let res = await candidate.discover(timeout)
    if res.isOk():
      self.active = candidate
      return res
    errors.add(res.error)
  return err("all NAT port mappers failed discovery: " & errors.join("; "))

method map*(
    self: FallbackPortMapper,
    internalPort: Port,
    externalPort: Port,
    proto: MapProto,
    lease: uint32,
): Future[Result[Port, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if self.active.isNil():
    return err("no active NAT port mapper; discovery has not succeeded")
  return await self.active.map(internalPort, externalPort, proto, lease)

method unmap*(
    self: FallbackPortMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if self.active.isNil():
    return err("no active NAT port mapper; discovery has not succeeded")
  return await self.active.unmap(externalPort, proto)

method close*(self: FallbackPortMapper) {.async: (raises: []), gcsafe.} =
  self.active = nil
  for candidate in self.candidates:
    await candidate.close()
  self.candidates = @[]

type RetryingPortMapper* = ref object of PortMapper
  ## Wraps a port mapper with a delete-then-re-add fallback: when the gateway
  ## rejects a mapping request - typically because a stale entry for the same
  ## external port is holding the slot (left over by a previous run, or by
  ## firmware that refuses to refresh an existing entry in place) - the stale
  ## mapping is removed and the request retried once. This also keeps lease
  ## renewal working on gateways that reject in-place refreshes.
  inner: PortMapper

func new*(T: typedesc[RetryingPortMapper], inner: PortMapper): T =
  T(inner: inner)

method discover*(
    self: RetryingPortMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  return await self.inner.discover(timeout)

method map*(
    self: RetryingPortMapper,
    internalPort: Port,
    externalPort: Port,
    proto: MapProto,
    lease: uint32,
): Future[Result[Port, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let first = await self.inner.map(internalPort, externalPort, proto, lease)
  if first.isOk():
    return first
  debug "NAT mapping rejected; removing stale entry and retrying",
    externalPort, proto, err = first.error
  discard await self.inner.unmap(externalPort, proto)
  let retried = await self.inner.map(internalPort, externalPort, proto, lease)
  if retried.isOk():
    return retried
  ## The slot cannot be reclaimed (e.g. the entry belongs to another host):
  ## fall back to an alternate external port. The gateway reports the port
  ## actually granted and announced addresses follow it.
  let alternate = Port(49152'u16 + uint16(externalPort) mod 16000'u16)
  debug "NAT mapping still rejected; requesting an alternate external port",
    requested = externalPort, alternate, proto
  return await self.inner.map(internalPort, alternate, proto, lease)

method unmap*(
    self: RetryingPortMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  return await self.inner.unmap(externalPort, proto)

method close*(self: RetryingPortMapper) {.async: (raises: []), gcsafe.} =
  await self.inner.close()

const DefaultNatDiscoveryTimeoutMs* = 1000'u32
  ## Default bound for the gateway discovery the NATService performs during
  ## switch start (configurable via the endpoint config). Node start awaits
  ## discovery, and miniupnpc repeats its SSDP probe rounds each waiting the
  ## full timeout, so on networks without a gateway the start stall is
  ## several times this value per mechanism (observed: 44s at libp2p's
  ## 10-second default, 20s at 3 seconds). One second keeps the worst-case
  ## stall in single digits while still giving gateways five times the 200ms
  ## window nim-eth's setupNat allowed them before the libp2p NATService
  ## migration.

const NatDiscoveryTimeout = DefaultNatDiscoveryTimeoutMs.int64.milliseconds

func toNatConfig*(
    strategy: NatStrategy, discoveryTimeout = NatDiscoveryTimeout
): Opt[NATConfig] =
  ## The libp2p `NATConfig` for a strategy, or none when no NATService is
  ## wanted. `NatExtIp` is deliberately not mapped: the static external IP is
  ## folded into `NetConfig`/the ENR before the switch exists, and libp2p's
  ## explicit-ip address mapper would drop dns4 announced addresses.
  case strategy.kind
  of NatUpnp, NatAny:
    Opt.some(upnpConfig(discoveryTimeout = discoveryTimeout))
  of NatPmp:
    Opt.some(natPmpConfig(discoveryTimeout = discoveryTimeout))
  of NatNone, NatExtIp:
    Opt.none(NATConfig)

proc natPortMapperFactory*(strategy: NatStrategy): PortMapperFactory =
  ## The port mapper for a strategy: UPnP-then-NAT-PMP fallback for `NatAny`,
  ## the matching single mapper for `NatUpnp`/`NatPmp`, nil (no NATService)
  ## otherwise. Every mapper is wrapped in the delete-then-re-add retrier so
  ## stale gateway entries cannot wedge mapping or lease renewal.
  if strategy.kind notin {NatAny, NatUpnp, NatPmp}:
    return nil
  let kind = strategy.kind
  return proc(mode: PortMappingMode): Opt[PortMapper] {.gcsafe, raises: [].} =
    try:
      let inner =
        case kind
        of NatAny:
          PortMapper(FallbackPortMapper.new(UpnpMapper.new(), NatPmpMapper.new()))
        of NatUpnp:
          PortMapper(UpnpMapper.new())
        of NatPmp:
          PortMapper(NatPmpMapper.new())
        else:
          return Opt.none(PortMapper)
      Opt.some(PortMapper(RetryingPortMapper.new(inner)))
    except ResourceExhaustedError as e:
      error "Failed to construct NAT port mapper", err = e.msg
      Opt.none(PortMapper)

proc mapPermanentUdpPort*(
    mapper: PortMapper, port: Port, discoveryTimeout = NatDiscoveryTimeout
): Future[Result[tuple[externalIp: IpAddress, externalPort: Port], string]] {.
    async: (raises: [CancelledError])
.} =
  ## Discover the gateway through `mapper` and map a single udp port with a
  ## permanent lease (0), for sockets that live outside the switch and its
  ## NATService (discv5). No renewal loop is run: firmware may cap the
  ## permanent lease (24h observed), after which the mapping lapses until
  ## the next start. A leftover entry from a crashed run is reclaimed by the
  ## retrier's delete-and-re-add.
  let externalIp = (await mapper.discover(discoveryTimeout)).valueOr:
    return err("NAT discovery failed: " & error)
  let externalPort = (await mapper.map(port, port, mpUdp, 0)).valueOr:
    return err("NAT port mapping failed: " & error)
  return ok((externalIp: externalIp, externalPort: externalPort))

proc mapPermanentUdpPort*(
    strategy: NatStrategy, port: Port, discoveryTimeout = NatDiscoveryTimeout
): Future[Result[tuple[externalIp: IpAddress, externalPort: Port], string]] {.
    async: (raises: [CancelledError])
.} =
  ## As above, constructing (and closing when done) the strategy's mapper.
  let factory = natPortMapperFactory(strategy)
  if factory.isNil():
    return err("NAT strategy has no port mapper: " & $strategy)
  # The factory captures the strategy; its mode argument is not consulted.
  let mapper = factory(PortMappingMode.Upnp).valueOr:
    return err("could not construct NAT port mapper")
  try:
    return await mapPermanentUdpPort(mapper, port, discoveryTimeout)
  finally:
    await mapper.close()
