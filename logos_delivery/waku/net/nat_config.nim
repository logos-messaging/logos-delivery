{.push raises: [].}

## Logos Delivery's public NAT strategy.
##
## The `NatStrategy` type deliberately describes user intent, not a particular
## NAT backend, preserving the `--nat` CLI contract. This module also maps a
## strategy onto libp2p's `NATConfig` (`SwitchBuilder.withNAT`), which owns
## UPnP / NAT-PMP gateway discovery, switch port mapping, lease refresh and
## mapped transport addresses on a per-switch basis.

import std/[net, strutils]
import chronos, chronicles, results
import
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

func parseNatStrategy*(value: string): Result[NatStrategy, string] =
  let normalized = value.toLowerAscii()
  case normalized
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
    if not normalized.startsWith(ExtIpPrefix):
      return err("not a valid NAT mechanism: " & value)

    let ipString = normalized[ExtIpPrefix.len ..^ 1]
    let ip =
      try:
        parseIpAddress(ipString)
      except ValueError:
        return err("not a valid IP address: " & ipString)

    ok(NatStrategy(kind: NatExtIp, extIp: ip))

type FallbackPortMapper* = ref object of PortMapper
  ## `--nat any`: try UPnP first, then NAT-PMP. Candidates are probed in
  ## order at discovery time and the first one that finds an external IP
  ## becomes the active mapper; the losers are closed. Once a mapper is
  ## active it is never re-elected.
  candidates: seq[PortMapper]
  active: PortMapper

proc new*(T: typedesc[FallbackPortMapper], candidates: varargs[PortMapper]): T =
  T(candidates: @candidates)

method discover*(
    self: FallbackPortMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if not self.active.isNil():
    return await self.active.discover(timeout)

  var errors: seq[string]
  for candidate in self.candidates:
    let res = await candidate.discover(timeout)
    if res.isOk():
      self.active = candidate
      for other in self.candidates:
        if other != candidate:
          await other.close()
      self.candidates = @[]
      return res
    errors.add(res.error)
  err("all NAT port mappers failed discovery: " & errors.join("; "))

method map*(
    self: FallbackPortMapper,
    internalPort: Port,
    externalPort: Port,
    proto: MapProto,
    lease: uint32,
): Future[Result[Port, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if self.active.isNil():
    return err("no active NAT port mapper; discovery has not succeeded")
  await self.active.map(internalPort, externalPort, proto, lease)

method unmap*(
    self: FallbackPortMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if self.active.isNil():
    return err("no active NAT port mapper; discovery has not succeeded")
  await self.active.unmap(externalPort, proto)

method close*(self: FallbackPortMapper) {.async: (raises: []), gcsafe.} =
  if not self.active.isNil():
    await self.active.close()
    self.active = nil
  for candidate in self.candidates:
    await candidate.close()
  self.candidates = @[]

proc toNatConfig*(strategy: NatStrategy): Opt[NATConfig] =
  ## The libp2p `NATConfig` for a strategy, or none when no NATService is
  ## wanted. `NatExtIp` is deliberately not mapped: the static external IP is
  ## folded into `NetConfig`/the ENR before the switch exists, and libp2p's
  ## explicit-ip address mapper would drop dns4 announced addresses.
  case strategy.kind
  of NatUpnp, NatAny:
    Opt.some(upnpConfig())
  of NatPmp:
    Opt.some(natPmpConfig())
  of NatNone, NatExtIp:
    Opt.none(NATConfig)

proc natPortMapperFactory*(strategy: NatStrategy): PortMapperFactory =
  ## For `NatAny`, overrides libp2p's default port mapper with the UPnP-then-
  ## NAT-PMP fallback; every other strategy uses the library default (nil).
  if strategy.kind != NatAny:
    return nil
  return proc(mode: PortMappingMode): Opt[PortMapper] {.gcsafe, raises: [].} =
    try:
      Opt.some(PortMapper(FallbackPortMapper.new(UpnpMapper.new(), NatPmpMapper.new())))
    except ResourceExhaustedError as e:
      error "Failed to construct fallback NAT port mapper", err = e.msg
      Opt.none(PortMapper)
